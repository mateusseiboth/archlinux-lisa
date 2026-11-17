#!/usr/bin/env bash
# extract-bsp.sh turns the pmbootstrap-built packages (kernel, device, firmware)
# into a distro-neutral BSP tree that the Arch and Ubuntu Touch builds consume.
set -u
. "$(dirname "$0")/lib.sh"

SCRIPT="$REPO_ROOT/common/extract-bsp.sh"
work=$(make_tmpdir)
trap 'rm -rf "$work"' EXIT

# An apk is concatenated gzip streams: a truncated signature tar, then the data
# tar. Building fixtures the same way checks the real format is handled.
make_apk() {
	local apk=$1 root=$2
	local sig="$work/sig"
	mkdir -p "$sig" && echo key >"$sig/.SIGN.RSA.test.rsa.pub"
	{
		tar -C "$sig" -cf - .SIGN.RSA.test.rsa.pub | head -c 1024 | gzip -n
		tar -C "$root" -cf - . | gzip -n
	} >"$apk"
}

put() {
	local root=$1 path=$2 content=$3
	mkdir -p "$root/$(dirname "$path")"
	printf '%s' "$content" >"$root/$path"
}

package() {
	local dir=$1 name=$2
	shift 2
	local root="$work/root-$name"
	rm -rf "$root" && mkdir -p "$root" "$dir"
	while [ $# -gt 0 ]; do
		put "$root" "$1" "$2"
		shift 2
	done
	make_apk "$dir/$name.apk" "$root"
}

pkgs="$work/packages"
cache="$work/cache"

package "$pkgs" linux-postmarketos-qcom-sc7280-7.2.9-r16 boot/vmlinuz old-kernel
package "$pkgs" linux-postmarketos-qcom-sc7280-7.2.9-r17 \
	boot/vmlinuz new-kernel \
	boot/dtbs/qcom/sm7325-xiaomi-lisa.dtb lisa-dtb \
	boot/dtbs/qcom/sm8250-other.dtb other-dtb \
	usr/share/kernel/postmarketos-qcom-sc7280/kernel.release 7.2.9 \
	usr/lib/modules/7.2.9/modules.dep deps \
	usr/lib/modules/7.2.9/kernel/drivers/gpu/panel-csot-vtdr6130.ko.zst panel
package "$pkgs" device-xiaomi-lisa-1-r9 boot/dtbo.img old-dtbo
package "$pkgs" device-xiaomi-lisa-1-r10 \
	boot/dtbo.img new-dtbo \
	usr/share/mkinitfs/modules/00-device-xiaomi-lisa.modules "fsa4480
panel-csot-vtdr6130" \
	usr/share/mkinitfs/hooks/50-xiaomi-lisa-panel-cycle.sh panel-hook \
	usr/share/alsa/ucm2/Xiaomi/lisa/HiFi.conf hifi \
	usr/share/alsa/ucm2/Xiaomi/lisa/lisa.conf lisa \
	etc/machine-info pmos-only
for sub in adsp cdsp gpu ipa modem vpu wpss; do
	package "$pkgs" "firmware-xiaomi-lisa-$sub-1-r0" "lib/firmware/qcom/sm7325/xiaomi/lisa/$sub.mbn" "$sub"
done
package "$pkgs" firmware-xiaomi-lisa-sensors-1-r0 usr/share/qcom/acdb/Forte/Forte_General_cal.acdb acdb
package "$cache" firmware-qcom-adreno-a660-20260110-r1.81de9dc1 usr/lib/firmware/qcom/a660_sqe.fw sqe
package "$cache" linux-firmware-ath11k-20261019-r0.c81c0d8f \
	lib/firmware/ath11k/WCN6750/hw1.0/board-2.bin.zst board \
	lib/firmware/ath11k/WCN6855/hw2.0/board-2.bin.zst unrelated
package "$cache" linux-firmware-qca-20261019-r0.79e5526e lib/firmware/qca/msbtfw11.mbn.zst bt

out="$work/bsp"
bash "$SCRIPT" --packages "$pkgs" --apk-cache "$cache" --out "$out" >/dev/null
assert_eq 0 $? "extracts the BSP"

mods="$out/rootfs/usr/lib/modules/7.2.9"
assert_eq new-kernel "$(cat "$mods/vmlinuz")" "takes the newest kernel (r17 over r16)"
assert_eq lisa-dtb "$(cat "$mods/dtbs/qcom/sm7325-xiaomi-lisa.dtb")" "copies the lisa DTB"
assert_no_file "$mods/dtbs/qcom/sm8250-other.dtb" "leaves the other DTBs out"
assert_no_file "$out/kernel/Image.gz" "kernel lives only in the module tree"
assert_eq 7.2.9 "$(cat "$out/kernel/kernel.release")" "records the kernel release"
assert_eq new-dtbo "$(cat "$out/kernel/dtbo.img")" "takes the newest device package (r10 over r9)"

assert_eq deps "$(cat "$out/rootfs/usr/lib/modules/7.2.9/modules.dep")" "installs the modules"
assert_file "$out/rootfs/usr/lib/modules/7.2.9/kernel/drivers/gpu/panel-csot-vtdr6130.ko.zst" "keeps the module tree"

fw="$out/rootfs/usr/lib/firmware/updates"
for sub in adsp cdsp gpu ipa modem vpu wpss; do
	assert_eq "$sub" "$(cat "$fw/qcom/sm7325/xiaomi/lisa/$sub.mbn")" "firmware $sub under firmware/updates"
done
assert_eq sqe "$(cat "$fw/qcom/a660_sqe.fw")" "Adreno firmware from usr/lib/firmware"
assert_eq board "$(cat "$fw/ath11k/WCN6750/hw1.0/board-2.bin.zst")" "WCN6750 Wi-Fi board file"
assert_no_file "$fw/ath11k/WCN6855" "only the WCN6750 part of ath11k"
assert_eq bt "$(cat "$fw/qca/msbtfw11.mbn.zst")" "Bluetooth firmware"
assert_eq acdb "$(cat "$out/rootfs/usr/share/qcom/acdb/Forte/Forte_General_cal.acdb")" "sensor calibration data"

assert_eq hifi "$(cat "$out/rootfs/usr/share/alsa/ucm2/Xiaomi/lisa/HiFi.conf")" "ALSA UCM"
assert_no_file "$out/rootfs/etc/machine-info" "drops pmOS-only files"

assert_eq "fsa4480
panel-csot-vtdr6130" "$(cat "$out/initramfs/modules")" "initramfs module list"
assert_eq panel-hook "$(cat "$out/initramfs/panel-cycle.sh")" "panel power-cycle hook"

rm "$pkgs"/device-xiaomi-lisa-*.apk
assert_fails "fails when a required package is missing" \
	bash "$SCRIPT" --packages "$pkgs" --apk-cache "$cache" --out "$work/bsp2"

finish
