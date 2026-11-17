#!/usr/bin/env bash
# The stock Xiaomi ABL only boots the exact layout pmOS uses on lisa:
# boot.img v3 with kernel+appended DTB and an empty ramdisk, vendor_boot.img v3
# with the ramdisk, the DTB, the cmdline and the stock load addresses.
set -u
. "$(dirname "$0")/lib.sh"

SCRIPT="$REPO_ROOT/common/mkbootimg-lisa.sh"
work=$(make_tmpdir)
trap 'rm -rf "$work"' EXIT

build_fixtures() {
	head -c 65536 /dev/urandom | gzip -n >"$work/Image.gz"
	head -c 4096 /dev/urandom >"$work/initramfs"
	printf '/dts-v1/;\n/ { compatible = "xiaomi,lisa"; };\n' >"$work/lisa.dts"
	dtc -q -I dts -O dtb -o "$work/lisa.dtb" "$work/lisa.dts"
}

build_fixtures

bash "$SCRIPT" --kernel "$work/Image.gz" --dtb "$work/lisa.dtb" \
	--ramdisk "$work/initramfs" --cmdline "root=PARTLABEL=userdata rw" \
	--out "$work/out" >/dev/null
assert_eq 0 $? "builds the images"

assert_file "$work/out/boot.img" "writes boot.img"
assert_file "$work/out/vendor_boot.img" "writes vendor_boot.img"

boot_args=$(unpack_bootimg --boot_img "$work/out/boot.img" --out "$work/b" --format mkbootimg)
vendor_args=$(unpack_bootimg --boot_img "$work/out/vendor_boot.img" --out "$work/vb" --format mkbootimg)

assert_contains "$boot_args" "--header_version 3" "boot.img is header v3"
assert_contains "$vendor_args" "--header_version 3" "vendor_boot.img is header v3"
assert_contains "$vendor_args" "--pagesize 0x00001000" "page size 4096"
assert_contains "$vendor_args" "--base 0x00000000" "stock base"
assert_contains "$vendor_args" "--kernel_offset 0x00008000" "stock kernel offset"
assert_contains "$vendor_args" "--ramdisk_offset 0x01000000" "stock ramdisk offset"
assert_contains "$vendor_args" "--tags_offset 0x00000100" "stock tags offset"
assert_contains "$vendor_args" "--dtb_offset 0x0000000001f00000" "stock dtb offset"
assert_contains "$vendor_args" "--vendor_cmdline 'console=tty0 cma=256M root=PARTLABEL=userdata rw'" \
	"base cmdline followed by the distro cmdline"

cat "$work/Image.gz" "$work/lisa.dtb" >"$work/expected-kernel"
assert_same_file "$work/expected-kernel" "$work/b/kernel" "kernel carries the appended DTB"
assert_eq 0 "$(stat -c %s "$work/b/ramdisk")" "generic ramdisk stays empty"
assert_same_file "$work/initramfs" "$work/vb/vendor_ramdisk" "ramdisk goes into vendor_boot"
assert_same_file "$work/lisa.dtb" "$work/vb/dtb" "DTB goes into vendor_boot"

assert_fails "refuses a missing kernel" bash "$SCRIPT" --dtb "$work/lisa.dtb" \
	--ramdisk "$work/initramfs" --out "$work/fail1"
assert_fails "refuses a kernel that does not exist" bash "$SCRIPT" --kernel "$work/nope" \
	--dtb "$work/lisa.dtb" --ramdisk "$work/initramfs" --out "$work/fail2"
assert_fails "refuses an unknown option" bash "$SCRIPT" --bogus x

finish
