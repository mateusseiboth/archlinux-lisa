# Fingerprint (FPC1540) on lisa: how the stock HAL drives the TrustZone app

Static reverse engineering of the stock MIUI/HyperOS vendor blobs (OS2.0.8.0.UKOMIXM, Android 14) to
find out what a Linux client for the FPC TrustZone app (TA) has to do. Nothing here was run on the
phone; every fact comes from disassembly, strings or the stock device tree.

Sources (all read-only):

| File | What it is |
| --- | --- |
| `vendor/lib64/hw/fingerprint.fpc.so` | FPC HAL (aarch64). Addresses below are virtual addresses in this file. |
| `vendor/lib64/libQSEEComAPI.so` | Qualcomm QSEECom client library (`/dev/qseecom` ioctls) |
| `vendor/lib/modules/fpc1540.ko` | Kernel glue (power, reset, IRQ, sysfs). Offsets are `.text` offsets. |
| `vendor/etc/init/init.mfp-daemon.rc` | Service and sysfs permissions |
| `nonhlos/image/fpclisa.{mdt,b00..b07}` | The TA (ELF64 AArch64, signed, split image) |
| `images/dtbo.img` entry with `model = "lisa based ..."` | Stock DT overlay, node `fingerprint_fpc` |

Tools: capstone + lief for annotated disassembly (scripts kept in the session scratchpad, not in
the repo), `llvm-objdump -dr` for the `.ko`, `dtc` for the DT.

Confidence levels: **high** means it is read directly from code or data, **medium** means it is
inferred from several consistent code paths, **guess** means it is a guess and is labelled that way.

---

## 0. Big picture

```
mfp-daemon (android.hardware.biometrics.fingerprint@2.1 service)
  └─ dlopen fingerprint.fpc.so  (picked by vendor/property, see 0.1)
       ├─ sysfs  /sys/bus/platform/devices/soc:fingerprint_fpc/{power_cfg,request_vreg,device_prepare,irq,...}
       │         → fpc1540.ko: L3C regulator, reset GPIO 43 (pinctrl), IRQ GPIO 34 (sysfs_notify)
       ├─ libQSEEComAPI → /dev/qseecom → TZ app "fpclisa"   (all sensor SPI traffic happens inside TZ)
       └─ libQSEEComAPI → TZ app "keymaster64" (only to fetch the wrapped HAT HMAC key once)
```

The application processor never talks SPI to the sensor. Linux only provides power, reset, the IRQ line,
and a way to call the TA. The TA owns the SPI bus, the sensor configuration, OTP, calibration, the
matcher and the encryption of the template database.

### 0.1 Who loads the HAL (medium)

`init.mfp-daemon.rc` starts `/vendor/bin/hw/mfp-daemon` (user `system`, groups `system drmrpc diag
input uhid`). Its strings contain `persist.vendor.sys.fp.vendor`, `%s/%s.%s.so`, `fpc`, `fpc_fod`,
`goodix`, `goodix_fod`. So it builds `fingerprint.<vendor>.so` from that property, and on this unit the
vendor is `fpc`. The same rc file sets the owner of every `soc:fingerprint_fpc/*` attribute to
`system`. Nothing in the rc file passes parameters to the HAL.

---

## 1. TA loading

### 1.1 `fpc_tac_open` @ `0x376b0` (high)

```
376d0  add  x20, x20, #0x10           ; path = hw_resource->sysfs_dir
376e4  bl   __open_2(path, O_RDONLY)   ; dir fd kept in tac->fd (+0xc), only closed later
376fc  mov  w8, #0x80
37700  x1 = "/vendor/firmware_mnt/image"
37704  x2 = "fpclisa"
37708  w3 = 0x80
37714  bl   QSEECom_start_app(&tac->handle, path, "fpclisa", 0x80)
```

* App name: **`fpclisa`, a string constant** at `0x1d9ce`. No property or HWID chooses it.
* Path: `/vendor/firmware_mnt/image` (the modem/NON-HLOS FAT partition). The library builds
  `%s/%s.mdt` and `%s/%s.b%02d` (strings in libQSEEComAPI).
* Shared buffer (`sb_length`): **0x80 bytes**. It is only the 0x40-byte request plus the 0x40-byte
  response of the transport (section 2). The real payloads travel in separate ION buffers.
* The HAL imports only `QSEECom_start_app`, `QSEECom_send_cmd`, `QSEECom_send_modified_cmd` and
  `QSEECom_shutdown_app`. It never calls `app_load_query`, `set_bandwidth`,
  `scale_bus_bandwidth` or `register_listener` directly.

### 1.2 What `QSEECom_start_app` does inside libQSEEComAPI (high for the ioctl numbers, medium for the order)

The internal routine (`0x5900..0x6700`) issues, in this order:

| ioctl | Value | Meaning (downstream `qseecom.h`) |
| --- | --- | --- |
| GET_QSEOS_VERSION | `0xc004970a` | version check |
| APP_LOADED_QUERY | `0xc048970f` | "App is already loaded QSEE and app id = %u" path, used when it is loaded already |
| LOAD_APP | `0xc0549707` | mdt and all `.bNN` concatenated in one ION buffer ("app_arch = %d, total_files = %d") |
| SET_MEM_PARAM | `0xc0189708` | registers the `sb_length` shared buffer (rounded to 4 KiB, ION) |
| UNLOAD_APP | `0x9709` | `QSEECom_shutdown_app` |

The library also wraps commands in `DMA_BUF_IOCTL_SYNC` (`0x40086200`). This is the stock Qualcomm
QSEECom API with nothing Xiaomi-specific.

### 1.3 Keymaster app (high)

`fpc_tee_init_hw_auth` @ `0x3801c` (called once from `fpc_hal_open`):

```
3804c  QSEECom_start_app(&km, "/vendor/firmware_mnt/image", "keymaster64", 0x400)
38094  req  = sb[0x00..0x40]: { u32 cmd = 0x205 /*KEYMASTER_GET_AUTH_TOKEN_KEY*/, u32 auth_type = 2 /*HW_AUTH_FINGERPRINT*/ }
380b0  QSEECom_send_cmd(km, sb, 0x40, sb+0x40, 0x3c0)
       rsp  = sb[0x40..]: { s32 status; u32 key_offset; u32 key_len; ... key at rsp+key_offset }
380f4  QSEECom_shutdown_app(km)
       then fpclisa cmd {3,5} with the key blob (section 3.4)
```

The constant `{0x205, 2}` is at `0x18e70`. `keymaster64` **is not in NON-HLOS** (no `keymaster64.mdt`
in `nonhlos/image`), so the start_app call works only because the app is already resident (loaded by
the boot chain, guess: by UEFI/ABL, which needs it for root-of-trust). The returned key is
*encapsulated* (wrapped) for the fpc app: the TA has `fpc_ta_hw_auth_unwrap_key`,
`qsee_decapsulate_inter_app_message`, `IKMHal_getAuthTokenKey256 failed: %d`. The HAL never sees the
plaintext HMAC key.

---

## 2. Command transport

### 2.1 Shared buffers: `fpc_tac_alloc_shared` @ `0x37d58` (high)

```
size = (len + 0xfff) & ~0xfff
ion_fd   = ion_open()
ion_alloc_fd(ion_fd, size, align=0x1000, heap_mask=0x80, flags=0, &buf_fd)   ; heap bit 7 = ION_QSECOM_HEAP_ID
addr     = mmap(NULL, size, PROT_READ|PROT_WRITE, MAP_SHARED, buf_fd, 0)
struct fpc_tac_shared_mem { void *addr; u32 size; s32 ion_fd; s32 buf_fd; }   ; 0x18 bytes
```

In the stock DT, the QSECOM heap is CMA from `qseecom_ta_region`/`qseecom_region` with
`alloc-ranges = <0 0 0 0xffffffff>`, so it is **physically contiguous and below 4 GiB**. That matters
because the transport passes a 32-bit physical address (2.2).

### 2.2 `fpc_tac_transfer(tac, shm)` @ `0x37f1c` (high)

```
sb = tac->handle->ion_sbuffer                 ; the 0x80-byte app shared buffer
*(u32*)(sb + 0) = shm->size                   ; 37f58
ifd = { .data[0] = { fd = shm->buf_fd, cmd_buf_offset = 4 }, .data[1..3] = 0 }   ; 37f5c..37f6c
QSEECom_send_modified_cmd(handle, sb, 0x40, sb + 0x40, 0x40, &ifd)              ; 37f80
ret = *(s32*)(sb + 0x40)                      ; TA status; < 0 is logged as "TA returned error"
```

So every fpclisa command is:

* **Request (0x40 bytes in the app sb):** `u32 shm_size` at +0, and at +4 the kernel writes the
  **32-bit physical address** of the ION buffer (non-64 `send_modified_cmd`, ioctl `0xc0409704`).
  The rest is zero.
* **Response (0x40 bytes):** `s32 status` at +0 and nothing else is read.
* **Payload:** in the ION buffer. Every payload starts with an 8-byte header
  `{ u32 target; u32 command; }`, followed by command fields at +8. The TA writes outputs back into
  the same ION buffer.

No command uses plain `QSEECom_send_cmd`, and every one passes exactly one ION buffer. The default
buffer is a 0x70-byte (one 4 KiB page) buffer allocated in `fpc_tee_init` @ `0x31394` and kept in
`tee->shm` (+8). Commands with large or variable payloads allocate a temporary one: build info, HAT,
DB transfer, auth result, FIDO, TA log.

Return value convention (`fpc_error_str` @ `0x3766c`, table @ `0x562c0`): `0` OK, small positive
values are `FPC_STATUS_*`, negative values are `FPC_ERROR_*`. A value can also be "packed": if bits
26..30 are neither 0 nor 0x1f, the code is `-(bits 20..25)`. The table (high):

```
-29 ALREADY_ENROLLED  -28 TOO_MANY_FAILED_ATTEMPTS -27 SENSOR_FINGER_NOT_STABLE -26 SENSOR_LOW_QUALITY
-25 SENSOR_LOW_COVERAGE -24 MINIMUM_NOT_REACHED -23 MAXIMUM_REACHED -22 STORAGE -21 CRC
-20 TEMPLATE_CORRUPTED -19 DEAD_PIXELS -18 PN -17 STATE -16 OTP -15 NOT_SUPPORTED -14 SPI
-13 SENSOR -12 TIMEDOUT -11 TEST_FAILED -10 PARAMETER -9 MEMORY -8 UNKNOWN -7 CANCELLED -6 IO
-5 PAL -1 NOT_FOUND
 1 WAIT_TIME 2 FINGER_PRESENT 3 FINGER_LOST 4 BAD_QUALITY 5 FINGER_ALREADY_ENROLLED
 6 ENROLL_PROGRESS 7 ENROLL_LOW_COVERAGE 8 ENROLL_TOO_SIMILAR 9 ENROLL_LOW_QUALITY 10 ENROLL_LOW_MOBILITY
```

---

## 3. Command set

Targets match the TA's module names (`fpc_ta_route_command`, `fpc_ta_{common,bio,sensor,hw_auth,
db_blob,kpi,navigation,sensortest}_module`). Offsets are into the ION payload. "out" means the TA
writes the field. Constants were read from `.rodata` (`0x18dxx..0x18fxx`) and correlated with the
store sites.

### 3.1 Target 12: common (high)

| Cmd | HAL function | Payload |
| --- | --- | --- |
| {12,0} | `fpc_tee_write_ta_log` @ `0x31454` | +8 `u32 len` (in: buffer size, out: bytes), +0xc log text |
| {12,1} | `fpc_tee_get_build_info` @ `0x31724` | 0x418 buffer. +0x14 `u32 bufsize = 0x400` (in). Out: +8 `supported_features`, +0xc `log_to_file_buf_sz`, +0x10 `max_number_of_templates`, +0x18 JSON build string |

The callback at `0x31810` copies `supported_features` into `tee->features` (+0x10) and
`max_number_of_templates` into tee+0x1c. Feature bits (`0x319b8..`): bit0 engineering, bit1
sensortest, bit2 navigation, bit3 log-to-file, bit4 force sensor, bit5 nav force-sw, bit6
authenticator (FIDO), bits4|5 sense-touch. Embedded TA build string (from `fpclisa.b0x`):
`"FPC_BUILD_TYPE":"release"`, built `2021-01-21`, Xiaomi project path `customer/xiaomi/j18`.

### 3.2 Target 10: sensor (high for IDs, medium for meanings)

All of these go through `sensor_command(sensor, sub)` @ `0x359d8`. It writes `{10, sub}` into
`tee->shm` and calls the transfer. If the result is `-17/-14/-13` (STATE/SPI/SENSOR), it waits 10 ms
and retries once; if the retry fails again it waits 20 ms and returns -13.

| Sub | Used by | Meaning (from callers and log strings) |
| --- | --- | --- |
| 0 | `fpc_tee_sensor_init` @ `0x36d98` (before `fpc_irq_init`) | sensor init/probe (SPI, HWID, OTP, calibration happen in TA) |
| 1 | `fpc_tee_check_finger_lost` | check finger lost; nonzero means lost |
| 2 | `fpc_tee_wait_finger_lost` | arm finger-lost detection, then wait for IRQ |
| 3 | `fpc_tee_wait_finger_down*` | arm finger-down detection ("wake up setup") |
| 4 | `fpc_tee_capture_image` (internal @ `0x36000`) | capture. +8 `u8 wait_finger_down`, +0xc `0`, +0x14 `u32 check_finger_lost`; out +0x10 `cac_result`. Returns 0 image ok, 1 retry qualification (max 4 or 1 tries), other `FPC_STATUS_*` |
| 5 | end of `sensor_init`, end of every capture, `sensor_release` | put sensor in low-power / idle (guess on the meaning, high on the call sites) |
| 6 | `fpc_tee_get_sensor_otp_info` @ `0x36bf0` | 0x68-byte OTP struct at +8 (in/out); first `u16` = **HWID** |
| 7 | `fpc_tee_early_stop_ctrl` | +8 `u8` in/out |
| 8 | `get_sensor_force_value`, `wait_for_button_{down,up}_force` | force sensor (not used on lisa) |
| 9 | `is_sensor_force_supported` | |
| 0xa | `fpc_tee_get_mqt_limits` | 0x18 bytes at +8 |
| 0xb | wait-down/lost loops | "check int": read/clear the sensor IRQ cause. `<0` error, `0` false alarm (re-arm), `>0` real event |
| 0xf | `get_finger_zones`, `wait_finger_lost_wet` | out +8 `u32 zones` |

Finger-down wait (`fpc_tee_wait_finger_down` @ `0x35d5c` → `0x35d64`):

```
loop:
  sensor_command(3)                       ; arm detect
  sysfs fingerdown_wait = "enable"
  fpc_irq_wait(expect = 1)                ; see section 4
  sysfs fingerdown_wait = "disable"
  sensor_command(0xb) → <0 error, 0 → loop, >0 → finger down
```

Capture: when the caller asks for it, wait for the finger to go up first, then the wait above, then
`sensor_command(4)` (repeated on result 1), then `sensor_command(5)`.

### 3.3 Target 11: bio (high)

| Cmd | HAL function | Payload |
| --- | --- | --- |
| {11,0} | `fpc_tee_bio_init` @ `0x37608` | none |
| {11,1} | `fpc_tee_begin_enrol` @ `0x3707c` | none |
| {11,2} | `fpc_tee_enrol` @ `0x370d0` | returns `FPC_STATUS_*` (6 progress, 7..10 rejects); out +8 `u32 remaining` |
| {11,3} | `fpc_tee_end_enrol` @ `0x37178` | out +8 `u32 finger_id` |
| {11,4} | `fpc_tee_identify` @ `0x371e8` | out +8 `u32 finger_id` (0 = no match), +0xc coverage, +0x10 quality, +0x1c score |
| {11,5} | `fpc_tee_update_template` @ `0x37320` | out +8 `u32 updated`; if nonzero the HAL stores the DB |
| {11,7} | `fpc_tee_load_empty_db` @ `0x37560` | none |
| {11,8} | `fpc_tee_get_finger_ids` @ `0x37390` | +8 `u32 count` (in: capacity ≤ 25, out: n), +0xc `u32 ids[]` |
| {11,9} | `fpc_tee_delete_template` @ `0x37490` | +8 `u32 finger_id` |
| {11,10} | `fpc_tee_set_gid` @ `0x37014` | +8 `u32 gid` (Android user id) |
| {11,11} | `fpc_tee_get_template_db_id` @ `0x374f4` | out +0x10 `u64` (= authenticator_id) |
| {11,18} | `fpc_tee_get_identify_statistics` | out +0xc..+0x1c |
| {11,19} | `fpc_tee_load_instance_data` @ `0x375b4` | none (called after every DB load) |

### 3.4 Target 3: hw_auth (high)

| Cmd | HAL function | Payload |
| --- | --- | --- |
| {3,1} | `fpc_tee_set_auth_challenge` @ `0x32b4c` | +8 `u64 operation_id` (before identify) |
| {3,2} | `fpc_tee_get_enrol_challenge` @ `0x32ba8` | out +8 `u64 challenge` (pre_enroll / post_enroll) |
| {3,3} | `fpc_tee_authorize_enrol` @ `0x32c18` | own buffer: +8 `u32 len` (= **69**), +0xc `hw_auth_token_t` from gatekeeper |
| {3,4} | `fpc_tee_get_auth_result` @ `0x32cbc` | own buffer: +8 `u32 len` (69), out +0xc the signed HAT |
| {3,5} | `fpc_tee_init_hw_auth` @ `0x3801c` | own buffer: +8 `u32 len`, +0xc wrapped key from keymaster64 |
| {3,6} | `fpc_tee_set_token_validation_enable` @ `0x32d70` | +8 `u8 enable` |

`fpc_enroll` (`0x29560`) rejects a HAT whose size is not 0x45 ("hat size mismatch"). The enrol task
(`0x297f4`) always sends {3,3} before {11,1}. {3,6} is only called from the engineering module
(`0x2cb94` with 1, `0x2cca0` with 0, around the engineering "test db" enrol): the TA has a switch to
**disable HAT validation**, gated by engineering support (TA string
`fpc_common_is_engineering_supported`). Whether a `release` TA accepts {3,6}=0 is **unknown**.

### 3.5 Target 4: template DB transfer (high)

`fpc_tee_store_template_db_host` @ `0x331bc` and `fpc_tee_load_template_db_host` @ `0x33654`.
`fpc_tee_{store,load}_template_db` are just tail-calls to them.

```
{4,6}  get size        out +8 u32 db_size                       (store only)
{4,14} open            +0xc u32 mode (0 = read from TA / store, 1 = write to TA / load), +0x10 u32 size
{4,16} read chunk      own buf (chunk+0x70): +8 u32 chunk_len (≤ 0xfff90), out data at +0xc;
                       returns the bytes still remaining (the HAL checks remaining == prev - chunk)
{4,17} write chunk     same layout, data in at +0xc; returns remaining
{4,15} close           always sent, also after errors
```

The blob is opaque and encrypted by the TA (TA symbols `fpc_wrap_crypto`/`fpc_unwrap_crypto`,
`qsee_fts_*`, `qsee_cipher_*`). It is bound to the device key, so it cannot be moved to another phone
and can only be decrypted by this TA on this SoC (medium). The host side:

* Path is `<storePath>/user.db`, where `storePath` comes from `setActiveGroup` (guess: the usual
  Android `/data/vendor_de/<uid>/fpdata`; the HAL only appends `/user.db`). Legacy `/data/vendor/fpc/user.db` is moved there once
  (`fpc_set_active_group` @ `0x28b04`).
* Store: write to `<path>.bak` (`0x335b4` formats `%s.bak`), `rename()` over `user.db`, then copy to
  `/data/vendor/fpc/user_backup.db`.
* Load: if the file is missing or empty, {11,7} load_empty_db. If the result is `-6`/`-20`
  (IO/TEMPLATE_CORRUPTED), the HAL truncates the file and loads an empty DB.

### 3.6 Other targets (high for IDs, not needed for a Linux client)

* 5 sensortest: {5,0} run, {5,1}, {5,2}, {5,3} is_test_supported, {5,4}, {5,6} capture
  uncalibrated, {5,7} get log.
* 6 debug/engineering: {6,1} retrieve, {6,2} sensor info, {6,3}/{6,4} inject, {6,5} retrieve size,
  {6,6} disable check pixels.
* 7 FIDO authenticator: {7,1} set nonce (0x1490 buffer), {7,2} get result, {7,3} is user valid.
* 8 navigation: {8,1} init … {8,7} debug buffer.
* 9 KPI: header `{9, sub}` built by hand in `fpc_tee_kpi_stop` @ `0x34064`.

### 3.7 HAL flows (medium-high)

```
open (fpc_hal_open @ 0x2a544), pwr = 3V3 first, then 1V8, 5 tries each:
  fpc_hw_resource_init(pwr)        sysfs power_cfg="3V3"|"1V8", request_vreg="enable", device_prepare="enable"
  fpc_tee_init                     start_app fpclisa, alloc 0x70 shm
  {12,1} build info
  {10,0} sensor init ; irq init ; {10,5}
  {11,0} bio init
  keymaster64 0x205 → {3,5}
  hwid = {10,6}.otp[0]; accept (3V3: hwid&0xff00 ∈ {0x1f00, 0x1c00}) (1V8: 0x1800), else close + retry
  property persist.vendor.sys.fp.info = build/hwid string
setActiveGroup(gid, path):   load DB {4,14/17/15} or {11,7} → {11,19} → {11,10 gid} → {11,11} authenticator_id
preEnroll:                   {3,2} → challenge
enroll(hat):                 {3,3 hat} → {11,1} → loop{ capture → {11,2} } → {11,3} id → store DB → {11,11}
postEnroll:                  {3,2}
authenticate(op_id):         {3,1 op_id} → loop{ capture → {11,4} → if match {3,4} HAT(69) → {11,5} → store if updated }
remove(fid):                 {11,9}... → store DB → {11,8} enumerate (reloads DB on failure)
enumerate:                   {11,8}
cancel:                      no TA command: sets cancel flag + writes 1 byte to the IRQ wait pipe
close:                       device_prepare/request_vreg = "disable" first, then {10,5}, shutdown_app
```

---

## 4. Kernel glue: `fpc1540.ko`

DT (stock dtbo, lisa entry, high):

```
fingerprint_fpc {
    compatible = "fpc,fpc1020";
    interrupt-parent = <&tlmm>; interrupts = <34 0>;
    fpc,gpio_rst = <&tlmm 43 0>;      /* not read by the driver: reset is done with pinctrl states */
    fpc,gpio_irq = <&tlmm 34 0>;
    fp_vdd_vreg-supply = <&L3C>;      /* L3C fixed at 3.3 V (fragment@81) */
    pinctrl-names = "fpc1020_reset_reset", "fpc1020_reset_active", "fpc1020_irq_active";
    pinctrl-0 = gpio43 output-low; pinctrl-1 = gpio43 output-high; pinctrl-2 = gpio34 input pull-down;
};
```

There is no `fpc,gpio_vdd1v8` on lisa, so only the 3V3 (L3C) power path exists. The HAL's 1V8
fallback cannot work here.

Attributes under `/sys/bus/platform/devices/soc:fingerprint_fpc/` and what they really do (high):

| Attribute | Driver function | Behaviour |
| --- | --- | --- |
| `power_cfg` (w) | `power_cfg_set` `0xed8` | "3V3" → use regulator `fp_vdd_vreg`; "1V8" → use GPIO `fpc,gpio_vdd1v8` |
| `request_vreg` (w) | `request_vreg_gpio` `0x8b0` | "enable": get GPIO `fpc,gpio_irq`, `devm_request_threaded_irq(thread = fpc1020_irq_handler, flags = 0x2001 = IRQF_TRIGGER_RISING \| IRQF_ONESHOT)`. "disable": free IRQ and GPIOs |
| `device_prepare` (w) | `device_prepare` `0x5c0` | "enable": `irq_set_irq_wake(1)`; pinctrl reset_reset (low); regulator_enable(L3C); sleep 100..1000 µs; pinctrl reset_active (high); `hw_reset()`. "disable": wake off, reset low, sleep 100..1000 µs, regulator_disable |
| `hw_reset` (w "reset") | `hw_reset` `0x1280` | high, 100..200 µs, **low, 5..5.1 ms, high, 5..5.1 ms**, logs IRQ level |
| `irq` (r) | `irq_get` `0x1530` | `"%i\n"` raw level of GPIO 34. Writes are ignored (`irq_ack` is a no-op) |
| `irq_enable` (w "1"/"0") | `0x146c` | enable_irq / disable_irq |
| `wakeup_enable` (w) | `0x132c` | no-op (lock/unlock only) |
| `fingerdown_wait` (w) | `0x1590` | sets a flag; with the panel blanked, a finger IRQ schedules `dsi_bridge_interface_enable(1500)` (Xiaomi "touch to wake", needs `mi_disp`) |
| `clk_enable`, `vendor` | | no-ops |
| `regulator_enable` | `0xfb8` | `"name,e"` → `vreg_setup` (only "vdd_ana") |

IRQ handler (`0xc40`): takes a 2000 ms wakeup source (`fpc_ttw_wl`) because the probe sets
`wakeup_enabled = 1`, then calls `sysfs_notify(dev, NULL, "irq")`.

What the HAL expects (`fpc_irq_*` @ `0x34f38..0x35620`, high):

```
dirfd = open("/sys/bus/platform/devices/<node with modalias containing fingerprint_fpc>", O_RDONLY)
fpc_irq_wait(expected):
  loop:
    fd = openat(dirfd, "irq", O_RDONLY|O_NONBLOCK); read 1 byte
    if byte - '0' == expected: return 0                 ; level already there
    poll({fd, POLLPRI|POLLERR}, {cancel_pipe_rd, POLLIN},
         timeout = enroll_state==1 ? fpc_enroll_timeout_sec*1000 : -1)
    write "1" to irq (ignored by the driver)
    poll == 0 → -12 (TIMEDOUT); pipe readable → -7 (CANCELLED); else close fd and loop
```

On mainline this needs no special driver: either a tiny platform driver with the same `irq`
attribute plus `sysfs_notify`, or plain libgpiod rising-edge events on GPIO 34 from userspace.
Power and reset also map onto standard regulator and GPIO consumers (L3C, GPIO 43).

---

## 5. Blockers and risks for running the TA from mainline Linux

Ordered by how likely each one is to stop the project.

1. **No TA loader in mainline (certain).** The mainline `qcom_scm` qseecom code
   (`drivers/firmware/qcom/qcom_scm.c` in `linux-lisa`) has only `APP_LOOKUP` (cmd 3) and
   `APP_SEND` (cmd 1 of owner TZ_APPS). It has no app *start*. fpclisa is not preloaded, so a
   loader is needed: the downstream `QSEOS_APP_START` SCM call (owner QSEE_OS 50, svc APP_MGR 1,
   cmd 1, args `mdt_len, img_len, pa` of one contiguous buffer with mdt plus all segments). The DT says
   `qcom,commonlib64-loaded-by-uefi`, so cmnlib does not have to be loaded first (high). The other
   route is the new `qcomtee` driver (smcinvoke, IAppLoader). Whether this firmware supports
   smcinvoke well enough, and whether a legacy QSEE app loaded that way can still receive legacy
   `APP_SEND` commands, is **unknown (guess)**.
2. **Mainline qseecom has no listeners/reentrancy (likely problem).** `qcom_scm_qseecom_call` only
   WARNs on `INCOMPLETE`/`BLOCKED_ON_LISTENER`. The TA links `qsee_sfs_*`, `qsee_fts_*`, `fpc_fs_*` and a
   "QIS Listener" serializer. The normal HAL flow keeps the DB on the host, so plain
   enroll/identify *may* never touch a listener, but calibration or AFD data might (unknown). If a
   command blocks on a listener, the client has to implement qseecomd's file listener.
3. **HAT / keymaster dependency (likely blocker for enrolment).** Enrolment requires {3,3} with a
   69-byte HAT signed with the auth-token HMAC key, and the challenge from {3,2}. On Android,
   gatekeeper makes that HAT. Linux has no gatekeeper. Options: (a) call keymaster64 `0x205` the same
   way (it is already resident; `APP_LOOKUP`+`APP_SEND` exist in mainline) and give the wrapped key to
   {3,5}, but we still cannot *sign* a HAT ourselves because the key stays in TZ; (b) {3,6}=0 to turn off
   token validation, which only the engineering path uses and which a `release` TA may refuse;
   (c) drive the gatekeeper TA too (unknown name/protocol, depends on KM HMAC sharing). Identify alone
   probably does not need a valid HAT, only the challenge (medium). **Test {3,6} first.**
4. **32-bit physical address in the payload, and memory TZ is allowed to see.** The request carries a
   `u32` PA of the payload buffer at +4. The buffer must be contiguous and below 4 GiB. The stock 5.4
   kernel on this SoC used SHM bridge (guess: `qtee_shmbridge` is standard on yupik), so the payload
   buffer probably has to be a registered SHM bridge region (`qcom_tzmem` in SHMBRIDGE mode, or an
   explicit `qcom_tzmem_shm_bridge_create`). Otherwise TZ refuses or faults on the access.
5. **SPI bus ownership and clocks (medium risk).** The sensor SPI is a TZ-owned QUP SE. The mainline
   lisa DT already reserves TLMM GPIO 48-51 (QUP SE12) and 56-59 (QUP SE14). One of these is the FP bus
   (guess: the other is the eSE/NFC SPI), and Linux must keep these SEs disabled. The driver's
   `clk_enable` is a stub, so TZ appears to handle the SE clocks itself. But if `clk_disable_unused` or
   missing interconnect votes switch off the QUP wrapper (wrap1), the TA's SPI could hang (guess, test
   with `clk_ignore_unused`).
6. **Allowlist and SCM plumbing.** The mainline qseecom device is gated by a machine allowlist; the
   exported `qcom_scm_qseecom_app_*` functions are not. A small out-of-tree module (load, lookup,
   send with a tzmem buffer, `/dev` node) is the minimum client. No ION on mainline: replace it with
   `qcom_tzmem` or `dma_alloc_coherent` with a DMA mask below 4 GiB.
7. **Version / anti-rollback (low risk).** The TA is loaded unmodified from the device's own
   firmware with its own signature, so the same rollback version the stock OS uses applies. The TA is
   ELF64 AArch64, so `app_arch` = ELFCLASS64. No HLOS-side SCM "lock SPI" call appears anywhere in
   the HAL or the `.ko`.
8. **Android-only niceties that are not needed:** perf locks (`libqti-perfd-client`), mi_disp
   touch-to-wake, FOD/sense-touch, navigation, KPI, the
   `persist.vendor.sys.fp.info` property, and the HIDL extension services.

### Suggested first experiments (no phone code was written for this document)

1. Kernel module: `qcom_scm_qseecom_app_get_id("keymaster64")`, to prove the SCM qseecom path works on
   this firmware with U-Boot in the chain.
2. Add `APP_START` and load `fpclisa` from the NON-HLOS partition; then `get_id("fpclisa")`.
3. Power the sensor (L3C on, GPIO 43 reset sequence above), send {12,1} build info, then {10,0}
   and {10,6}: an HWID of 0x1fxx/0x1cxx proves the TA reaches the sensor over SPI.
4. {11,0}, {11,7}, {11,10}, then capture ({10,3}, IRQ on GPIO 34, {10,0xb}, {10,4}) and {11,4}
   against the empty DB.
5. Only then attack enrolment: {3,6}=0, or keymaster/gatekeeper.
