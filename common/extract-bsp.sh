#!/usr/bin/env bash
# Extracts the lisa board support (mainline kernel, DTB, modules, firmware,
# device files) from the packages pmbootstrap built, into a distro-neutral tree:
#
#   <out>/kernel/     dtbo.img, kernel.release
#   <out>/initramfs/  modules (list for early boot), panel-cycle.sh
#   <out>/rootfs/     overlay copied onto the distro root (kernel, DTB, modules, firmware, UCM)
#
# Firmware goes to /usr/lib/firmware/updates so it never clashes with the
# distro linux-firmware package and wins over older copies of the same files.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
. "$REPO_ROOT/common/lisa.conf"

PMB_WORK=${PMB_WORK:-$HOME/.local/var/pmbootstrap}
packages="$PMB_WORK/packages/edge/aarch64"
apk_cache="$PMB_WORK/cache_apk_aarch64"
out="$REPO_ROOT/out/bsp"
# A kernel built by tools/build-kernel.sh, laid out like the kernel package.
kernel_root=""

MARKER=".lisa-bsp"

# source  package                          strategy[:argument]
PACKAGE_TABLE="
kernel   linux-postmarketos-qcom-sc7280    kernel
packages device-xiaomi-lisa                device
packages firmware-xiaomi-lisa-adsp         firmware
packages firmware-xiaomi-lisa-cdsp         firmware
packages firmware-xiaomi-lisa-gpu          firmware
packages firmware-xiaomi-lisa-ipa          firmware
packages firmware-xiaomi-lisa-modem        firmware
packages firmware-xiaomi-lisa-sensors      firmware
packages firmware-xiaomi-lisa-vpu          firmware
packages firmware-xiaomi-lisa-wpss         firmware
cache    firmware-qcom-adreno-a660         firmware
cache    linux-firmware-ath11k             firmware:ath11k/WCN6750
cache    linux-firmware-qca                firmware
"

die() {
	echo "extract-bsp: $*" >&2
	exit 1
}

parse_args() {
	while [ $# -gt 0 ]; do
		[ $# -ge 2 ] || die "opção sem valor: $1"
		case "$1" in
		--packages) packages=$2 ;;
		--apk-cache) apk_cache=$2 ;;
		--out) out=$2 ;;
		--kernel-root) kernel_root=$2 ;;
		*) die "opção desconhecida: $1" ;;
		esac
		shift 2
	done
}

# Never wipe a directory this script did not create.
prepare_out() {
	[ ! -e "$out" ] || [ -e "$out/$MARKER" ] || [ -z "$(ls -A "$out")" ] ||
		die "$out existe e não é um BSP gerado por este script"
	rm -rf "$out"
	mkdir -p "$out/kernel" "$out/initramfs" "$out/rootfs"
	touch "$out/$MARKER"
}

find_newest_apk() {
	local dir=$1 name=$2 newest
	newest=$(find "$dir" -maxdepth 1 -name "$name-[0-9]*.apk" | sort -V | tail -n 1)
	[ -n "$newest" ] || die "pacote $name não encontrado em $dir"
	echo "$newest"
}

unpack_apk() {
	local apk=$1 dest=$2
	mkdir -p "$dest"
	tar -xzf "$apk" -C "$dest" --ignore-zeros --warning=no-unknown-keyword ||
		die "não consegui abrir $apk"
}

copy_tree() {
	local from=$1 to=$2
	[ -d "$from" ] || return 0
	mkdir -p "$to"
	cp -a "$from/." "$to/"
}

# Kernel and DTB go next to the modules (/usr/lib/modules/<kver>/), the layout
# lisa-mkbootimg reads on every distro.
install_kernel() {
	local root=$1 release modules
	release=$(cat "$root"/usr/share/kernel/*/kernel.release)
	modules="$out/rootfs/usr/lib/modules/$release"
	echo "$release" >"$out/kernel/kernel.release"
	copy_tree "$root/usr/lib/modules" "$out/rootfs/usr/lib/modules"
	copy_tree "$root/lib/modules" "$out/rootfs/usr/lib/modules"
	install -Dm644 "$root/boot/vmlinuz" "$modules/vmlinuz"
	install -Dm644 "$root/boot/dtbs/qcom/$LISA_DTB_NAME" "$modules/dtbs/qcom/$LISA_DTB_NAME"
}

install_device() {
	local root=$1
	cp "$root/boot/dtbo.img" "$out/kernel/dtbo.img"
	cp "$root"/usr/share/mkinitfs/modules/*.modules "$out/initramfs/modules"
	cp "$root"/usr/share/mkinitfs/hooks/*panel-cycle.sh "$out/initramfs/panel-cycle.sh"
	copy_tree "$root/usr/share/alsa" "$out/rootfs/usr/share/alsa"
}

install_firmware() {
	local root=$1 subdir=${2:-}
	local dest="$out/rootfs/usr/lib/firmware/updates"
	copy_tree "$root/lib/firmware/$subdir" "$dest/$subdir"
	copy_tree "$root/usr/lib/firmware/$subdir" "$dest/$subdir"
	copy_tree "$root/usr/share/qcom" "$out/rootfs/usr/share/qcom"
}

source_dir() {
	case "$1" in
	packages | kernel) echo "$packages" ;;
	cache) echo "$apk_cache" ;;
	*) die "origem desconhecida: $1" ;;
	esac
}

# The directory holding the package's files: --kernel-root for the kernel when
# given, else the newest apk unpacked into a staging directory.
package_root() {
	local source=$1 name=$2 apk staging
	[ "$source" = kernel ] && [ -n "$kernel_root" ] && { echo "$kernel_root"; return; }
	apk=$(find_newest_apk "$(source_dir "$source")" "$name")
	staging=$(mktemp -d "$out/.unpack.XXXXXX")
	unpack_apk "$apk" "$staging"
	echo "$staging"
}

extract_package() {
	local source=$1 name=$2 strategy=$3 root
	root=$(package_root "$source" "$name")
	"install_${strategy%%:*}" "$root" "$(echo "$strategy" | cut -s -d: -f2)"
	echo "$name"
}

parse_args "$@"
prepare_out
echo "$PACKAGE_TABLE" | while read -r source name strategy; do
	[ -n "$source" ] || continue
	extract_package "$source" "$name" "$strategy"
done
rm -rf "$out"/.unpack.*
echo "BSP em $out"
