#!/usr/bin/env bash
# lisa-mkbootimg runs inside the distro root (image build or kernel update on
# the phone) and turns the installed kernel + initramfs into /boot/boot.img and
# /boot/vendor_boot.img. Arch (mkinitcpio) and Ubuntu (initramfs-tools) name the
# initramfs differently; both must work.
set -u
. "$(dirname "$0")/lib.sh"

SCRIPT="$REPO_ROOT/common/lisa-mkbootimg"
work=$(make_tmpdir)
trap 'rm -rf "$work"' EXIT

make_root() {
	local root=$1 kver=$2
	mkdir -p "$root/usr/lib/modules/$kver/dtbs/qcom" "$root/boot"
	head -c 4096 /dev/urandom | gzip -n >"$root/usr/lib/modules/$kver/vmlinuz"
	printf '/dts-v1/;\n/ { model = "%s"; };\n' "$kver" >"$work/$kver.dts"
	dtc -q -I dts -O dtb -o "$root/usr/lib/modules/$kver/dtbs/qcom/sm7325-xiaomi-lisa.dtb" "$work/$kver.dts"
}

vendor_cmdline() {
	unpack_bootimg --boot_img "$1/boot/vendor_boot.img" --out "$work/unpack" --format mkbootimg |
		sed -n "s/.*--vendor_cmdline '\([^']*\)'.*/\1/p"
}

# Arch layout: mkinitcpio writes /boot/initramfs-linux-lisa.img.
arch="$work/arch"
make_root "$arch" 7.2.9
head -c 2048 /dev/urandom >"$arch/boot/initramfs-linux-lisa.img"
bash "$SCRIPT" --root "$arch" >/dev/null
assert_eq 0 $? "builds from an Arch root"
assert_file "$arch/boot/boot.img" "writes /boot/boot.img"
assert_file "$arch/boot/vendor_boot.img" "writes /boot/vendor_boot.img"
unpack_bootimg --boot_img "$arch/boot/vendor_boot.img" --out "$work/a" >/dev/null
assert_same_file "$arch/boot/initramfs-linux-lisa.img" "$work/a/vendor_ramdisk" "uses the mkinitcpio initramfs"
assert_same_file "$arch/usr/lib/modules/7.2.9/dtbs/qcom/sm7325-xiaomi-lisa.dtb" "$work/a/dtb" "uses the installed DTB"
assert_eq "console=tty0 cma=256M root=PARTLABEL=userdata rw rootwait" "$(vendor_cmdline "$arch")" \
	"default cmdline mounts userdata as root"

# Ubuntu layout: initramfs-tools writes /boot/initrd.img-<kver>; newest kernel wins.
ubuntu="$work/ubuntu"
make_root "$ubuntu" 7.2.8
make_root "$ubuntu" 7.2.10
head -c 2048 /dev/urandom >"$ubuntu/boot/initrd.img-7.2.8"
head -c 2048 /dev/urandom >"$ubuntu/boot/initrd.img-7.2.10"
mkdir -p "$ubuntu/etc/lisa"
echo "root=PARTLABEL=userdata rw rootwait quiet splash" >"$ubuntu/etc/lisa/cmdline"
bash "$SCRIPT" --root "$ubuntu" >/dev/null
assert_eq 0 $? "builds from an Ubuntu root"
unpack_bootimg --boot_img "$ubuntu/boot/vendor_boot.img" --out "$work/u" >/dev/null
assert_same_file "$ubuntu/boot/initrd.img-7.2.10" "$work/u/vendor_ramdisk" "picks the newest kernel (7.2.10 over 7.2.8)"
assert_eq "console=tty0 cma=256M root=PARTLABEL=userdata rw rootwait quiet splash" "$(vendor_cmdline "$ubuntu")" \
	"/etc/lisa/cmdline overrides the distro cmdline"

bash "$SCRIPT" --root "$ubuntu" --kernel-release 7.2.8 >/dev/null
unpack_bootimg --boot_img "$ubuntu/boot/vendor_boot.img" --out "$work/u8" >/dev/null
assert_same_file "$ubuntu/boot/initrd.img-7.2.8" "$work/u8/vendor_ramdisk" "--kernel-release selects a kernel"

empty="$work/empty"
mkdir -p "$empty/usr/lib/modules"
assert_fails "fails without an installed kernel" bash "$SCRIPT" --root "$empty"

noinitrd="$work/noinitrd"
make_root "$noinitrd" 7.2.9
assert_fails "fails without an initramfs" bash "$SCRIPT" --root "$noinitrd"

finish
