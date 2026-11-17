#!/usr/bin/env bash
# Installs packages built by arch/build-packages.sh on the phone over the USB
# network. sudo asks for the phone user's password, or reads it from
# LISA_SUDO_PASSWORD (never stored anywhere).
#
#   arch/deploy.sh out/arch/pkgs/lisa-device-1-3-aarch64.pkg.tar.zst ...
set -euo pipefail

HOST=${LISA_HOST:-$(id -un)@172.16.42.1}

[ $# -gt 0 ] || { echo "uso: arch/deploy.sh <pacote.pkg.tar.zst>..." >&2; exit 1; }

remote_dir=$(ssh "$HOST" mktemp -d)
scp -q "$@" "$HOST:$remote_dir/"
names=$(for pkg in "$@"; do printf '%s/%s ' "$remote_dir" "$(basename "$pkg")"; done)
# shellcheck disable=SC2029 # the paths are built here on purpose
[ -z "${LISA_SUDO_PASSWORD:-}" ] || {
	printf '%s\n' "$LISA_SUDO_PASSWORD" | ssh "$HOST" "sudo -S -p '' pacman -U --noconfirm $names; rm -rf $remote_dir"
	exit
}
# shellcheck disable=SC2029
ssh -t "$HOST" "sudo pacman -U --noconfirm $names; rm -rf $remote_dir"
