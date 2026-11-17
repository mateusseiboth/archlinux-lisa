#!/usr/bin/env bash
# Runs package() of arch/pkgs/lisa-device/PKGBUILD against a fake BSP and checks
# where every file lands. Caught: the ALSA UCM ended in /usr/share/ucm2 instead
# of /usr/share/alsa/ucm2, so the phone had no sound.
set -u
. "$(dirname "$0")/lib.sh"

PKG_DIR="$REPO_ROOT/arch/pkgs/lisa-device"
work=$(make_tmpdir)
trap 'rm -rf "$work"' EXIT

bsp="$work/bsp"
mkdir -p "$bsp/initramfs" "$bsp/rootfs/usr/share/alsa/ucm2/Xiaomi/lisa" "$bsp/rootfs/usr/share/alsa/ucm2/conf.d/sm8250"
printf 'fsa4480\npanel-csot-vtdr6130\n' >"$bsp/initramfs/modules"
echo panel-hook >"$bsp/initramfs/panel-cycle.sh"
echo hifi >"$bsp/rootfs/usr/share/alsa/ucm2/Xiaomi/lisa/HiFi.conf"
ln -s ../../Xiaomi/lisa/lisa.conf "$bsp/rootfs/usr/share/alsa/ucm2/conf.d/sm8250/Xiaomi 11 Lite 5G NE.conf"

pkgdir="$work/pkg"
mkdir -p "$pkgdir"
(
	cd "$PKG_DIR" || exit 1
	export LISA_BSP="$bsp" LISA_COMMON="$REPO_ROOT/common"
	# shellcheck disable=SC1091
	. ./PKGBUILD
	package
)
assert_eq 0 $? "package() runs"

ucm="$pkgdir/usr/share/alsa/ucm2"
assert_eq hifi "$(cat "$ucm/Xiaomi/lisa/HiFi.conf" 2>/dev/null)" "UCM under /usr/share/alsa/ucm2"
assert_eq ../../Xiaomi/lisa/lisa.conf "$(readlink "$ucm/conf.d/sm8250/Xiaomi 11 Lite 5G NE.conf")" "UCM card link kept"
assert_no_file "$pkgdir/usr/share/ucm2" "nothing in /usr/share/ucm2"

assert_contains "$(cat "$pkgdir/boot/extlinux/extlinux.conf")" \
	"append console=tty0 cma=256M root=PARTLABEL=userdata rw rootwait" "extlinux cmdline from lisa.conf"
conf=$(cat "$pkgdir/etc/mkinitcpio.conf.d/lisa.conf")
assert_contains "$conf" "MODULES=(fsa4480 panel-csot-vtdr6130)" "initramfs modules from the BSP"
assert_contains "$conf" "a660_sqe.fw" "GPU firmware in the initramfs"
assert_eq /usr/lib/lisa/lisa-mkbootimg "$(readlink "$pkgdir/usr/bin/lisa-mkbootimg")" "lisa-mkbootimg on PATH"
assert_eq panel-hook "$(cat "$pkgdir/usr/lib/lisa/panel-cycle.sh")" "panel power-cycle script"
assert_file "$pkgdir/usr/lib/initcpio/hooks/lisa-panel" "initcpio hook"
assert_file "$pkgdir/usr/lib/systemd/logind.conf.d/50-lisa-powerkey.conf" "common rootfs overlay"
assert_file "$pkgdir/usr/lib/udev/rules.d/81-lisa-sensors.rules" "accelerometer udev rule"
assert_contains "$(cat "$PKG_DIR/PKGBUILD")" "hexagonrpcd" "depends on hexagonrpcd"

finish
