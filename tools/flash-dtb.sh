#!/usr/bin/env bash
# Puts a new device tree on the running phone. The ABL hands U-Boot (and Linux)
# the DTB of vendor_boot_a, so a DT change means a new vendor_boot_a: the DTB,
# an empty ramdisk, the stock load addresses (mkbootimg-lisa.sh).
#
#   tools/flash-dtb.sh <dtb>
#
# Keeps the vendor_boot_a it replaces in out/vendor_boot-backup/, writes the new
# one with dd on the phone and reads it back. sudo on the phone asks for the
# password, or reads it from LISA_SUDO_PASSWORD. If the phone does not come
# back: Power + Volume Down, then fastboot flash vendor_boot_a <the backup>.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
HOST=${LISA_HOST:-$(id -un)@172.16.42.1}
PART=/dev/disk/by-partlabel/vendor_boot_a

die() {
	echo "flash-dtb: $*" >&2
	exit 1
}

dtb=${1:-}
[ -f "$dtb" ] || die "uso: tools/flash-dtb.sh <dtb>"

remote_sudo() {
	[ -z "${LISA_SUDO_PASSWORD:-}" ] || {
		# shellcheck disable=SC2029 # the command is built here on purpose
		printf '%s\n' "$LISA_SUDO_PASSWORD" | ssh "$HOST" "sudo -S -p '' $1"
		return
	}
	# shellcheck disable=SC2029
	ssh -t "$HOST" "sudo $1"
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf '' | (cd "$work" && cpio -o -H newc --quiet) >"$work/empty.cpio"
head -c 64 /dev/zero >"$work/no-kernel"
bash "$REPO_ROOT/common/mkbootimg-lisa.sh" --kernel "$work/no-kernel" --dtb "$dtb" \
	--ramdisk "$work/empty.cpio" --out "$work" >/dev/null

backup_dir=$REPO_ROOT/out/vendor_boot-backup
mkdir -p "$backup_dir"
backup=$backup_dir/vendor_boot_a-$(date +%Y%m%d-%H%M%S).img
size=$(stat -c %s "$work/vendor_boot.img")
remote_sudo "dd if=$PART bs=4096 status=none" >"$backup"
[ -s "$backup" ] || die "não consegui ler o vendor_boot_a atual"
echo "backup: $backup"

remote=$(ssh "$HOST" mktemp)
scp -q "$work/vendor_boot.img" "$HOST:$remote"
remote_sudo "dd if=$remote of=$PART bs=4096 conv=fsync status=none; rm -f $remote"
written=$(remote_sudo "head -c $size $PART" | sha256sum | cut -d' ' -f1)
expected=$(sha256sum <"$work/vendor_boot.img" | cut -d' ' -f1)
[ "$written" = "$expected" ] || die "o que foi gravado não confere ($written != $expected); restaure com o backup"
echo "vendor_boot_a gravado e conferido ($expected). Reinicie o aparelho para usar o DTB novo."
