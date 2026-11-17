# Hardware status on Arch Linux ARM

Measured on the phone (kernel 7.2.9 from the pmOS port, U-Boot `linux-only`).
"pmOS" says how the same kernel did under postmarketOS.

| Part | Status | pmOS | Notes |
| --- | --- | --- | --- |
| Display, GPU (Adreno 642L) | works | works | GPU firmware in the initramfs, so the GPU no longer misses it at probe |
| Touch (Goodix Berlin) | works | works | |
| Wi-Fi (WCN6750) | works | works | stable address from `lisa-bootmac` instead of the generic 00:03:7F:12:22:22 |
| Bluetooth | works | works | needed `lisa-bootmac`: without an address hci0 stays unconfigured and BlueZ ignores it |
| Speakers, earpiece | works | works | ALSA UCM from the device package (was installed in the wrong place) |
| Battery, charging | works | works | |
| Accelerometer | works | no | ADSP sensor core through `hexagonrpcd` + libssc, udev rule for iio-sensor-proxy |
| Ambient light, compass | works | no | same path |
| Proximity | not possible | no | a virtual ultrasound sensor (Elliptic Labs), Android only |
| Cameras (4) | stream, image dark | works | all four stream with libcamera 0.7.2 and 0.8.0 (packaged with the pmOS patches, `arch/pkgs/libcamera`; installing it needs pipewire-libcamera and plasma-camera rebuilt against it); frames still come out dark, under investigation |
| Flash LED | present | ? | `white:flash` |
| Kernel features | Landlock on | | own kernel build (`tools/build-kernel.sh`, Alpine clang like pmOS); pacman's download sandbox works again |
| Modem data | in progress | no | IPA fixed in the device tree (`rmnet_ipa0` comes up), ModemManager creates the modem, `msm-modem` selects the SIM; both slots report no card (no-atr-received) |
| Calls, SMS | not yet | no | after modem data; voice audio needs q6voiced and UCM work |
| Vibration (Awinic AW8624) | in progress | no | no mainline driver; the stock DT puts it on SE4 with GPIO 20/21, which the mainline pinctrl does not offer for SE4 |
| Microphones, headset | not yet | no | WCD9370 codec (mainline driver wcd937x) on SoundWire with the LPASS TX/RX macros: device tree work, no new driver |
| Fingerprint (FPC1020, side key) | not possible for now | no | read through a TrustZone app on Android; no Linux path |
| Focus motor (DW9800) | not yet | no | |

## How a change reaches the phone

- Userspace packages: `arch/build-packages.sh <pkg>` then `arch/deploy.sh`.
- Device tree: `tools/flash-dtb.sh <dtb>` (the ABL hands the DTB of vendor_boot_a to U-Boot and Linux).
- Kernel and modules: `tools/build-kernel.sh`, `common/extract-bsp.sh --kernel-root out/kernel-root`, then
  `arch/build-packages.sh linux-lisa` and `arch/deploy.sh`.
