#!/usr/bin/env bash
# Builds boot.img + vendor_boot.img in the layout the stock lisa ABL accepts.
#
#   mkbootimg-lisa.sh --kernel Image.gz --dtb sm7325-xiaomi-lisa.dtb \
#       --ramdisk initramfs --cmdline "root=..." --out out/
set -euo pipefail

. "$(dirname "$(readlink -f "$0")")/lisa.conf"

die() {
	echo "mkbootimg-lisa: $*" >&2
	exit 1
}

usage() {
	die "uso: $0 --kernel <Image.gz> --dtb <dtb> --ramdisk <initramfs> [--cmdline <args>] --out <dir>"
}

kernel="" dtb="" ramdisk="" cmdline="" out=""

parse_args() {
	while [ $# -gt 0 ]; do
		[ $# -ge 2 ] || usage
		case "$1" in
		--kernel) kernel=$2 ;;
		--dtb) dtb=$2 ;;
		--ramdisk) ramdisk=$2 ;;
		--cmdline) cmdline=$2 ;;
		--out) out=$2 ;;
		*) usage ;;
		esac
		shift 2
	done
}

require_file() {
	local label=$1 path=$2
	[ -n "$path" ] || die "falta --$label"
	[ -f "$path" ] || die "--$label não encontrado: $path"
}

validate() {
	require_file kernel "$kernel"
	require_file dtb "$dtb"
	require_file ramdisk "$ramdisk"
	[ -n "$out" ] || die "falta --out"
}

build_boot_img() {
	local kernel_with_dtb="$out/.kernel-dtb"
	cat "$kernel" "$dtb" >"$kernel_with_dtb"
	mkbootimg --header_version "$LISA_HEADER_VERSION" \
		--kernel "$kernel_with_dtb" \
		--output "$out/boot.img"
	rm -f "$kernel_with_dtb"
}

build_vendor_boot_img() {
	mkbootimg --header_version "$LISA_HEADER_VERSION" \
		--pagesize "$LISA_PAGESIZE" \
		--base "$LISA_BASE" \
		--kernel_offset "$LISA_KERNEL_OFFSET" \
		--ramdisk_offset "$LISA_RAMDISK_OFFSET" \
		--tags_offset "$LISA_TAGS_OFFSET" \
		--dtb_offset "$LISA_DTB_OFFSET" \
		--dtb "$dtb" \
		--vendor_ramdisk "$ramdisk" \
		--vendor_cmdline "${LISA_CMDLINE_BASE}${cmdline:+ $cmdline}" \
		--vendor_boot "$out/vendor_boot.img"
}

parse_args "$@"
validate
mkdir -p "$out"
build_boot_img
build_vendor_boot_img
echo "$out/boot.img"
echo "$out/vendor_boot.img"
