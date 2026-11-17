#!/usr/bin/env bash
# Golden test: fed with the inputs of the pmOS install that boots on the phone,
# mkbootimg-lisa.sh must reproduce its boot.img and vendor_boot.img byte for byte.
# Skipped when the pmbootstrap rootfs chroot is not on this machine.
set -u
. "$(dirname "$0")/lib.sh"

PMOS_BOOT=${PMOS_BOOT:-$HOME/.local/var/pmbootstrap/chroot_rootfs_xiaomi-lisa/boot}

[ -f "$PMOS_BOOT/vendor_boot.img" ] || { echo "  skip: no pmOS boot dir at $PMOS_BOOT"; exit 0; }

work=$(make_tmpdir)
trap 'rm -rf "$work"' EXIT

unpack_bootimg --boot_img "$PMOS_BOOT/vendor_boot.img" --out "$work/ref" --format mkbootimg >"$work/ref-args"
pmos_cmdline=$(sed -n "s/.*--vendor_cmdline '\([^']*\)'.*/\1/p" "$work/ref-args")
distro_cmdline=${pmos_cmdline#"console=tty0 cma=256M "}

bash "$REPO_ROOT/common/mkbootimg-lisa.sh" --kernel "$PMOS_BOOT/vmlinuz" \
	--dtb "$PMOS_BOOT/sm7325-xiaomi-lisa.dtb" --ramdisk "$PMOS_BOOT/initramfs" \
	--cmdline "$distro_cmdline" --out "$work/out" >/dev/null

assert_same_file "$PMOS_BOOT/boot.img" "$work/out/boot.img" "boot.img identical to pmOS"
assert_same_file "$PMOS_BOOT/vendor_boot.img" "$work/out/vendor_boot.img" "vendor_boot.img identical to pmOS"

finish
