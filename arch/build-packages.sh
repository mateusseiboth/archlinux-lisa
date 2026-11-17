#!/usr/bin/env bash
# Builds single packages from arch/pkgs without rebuilding the image, in a
# builder chroot kept between runs (Docker volume lisa-arch-builder).
#
#   arch/build-packages.sh <package>...      e.g. arch/build-packages.sh lisa-device
#
# Output in out/arch/pkgs/. arch/deploy.sh installs them on the phone.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
OUT=$REPO_ROOT/out/arch/pkgs
BSP=$REPO_ROOT/out/bsp

die() {
	echo "arch/build-packages.sh: $*" >&2
	exit 1
}

[ $# -gt 0 ] || die "uso: arch/build-packages.sh <pacote>... (pacotes em arch/pkgs)"
for name in "$@"; do
	[ -f "$REPO_ROOT/arch/pkgs/$name/PKGBUILD" ] || die "pacote desconhecido: $name"
done
[ -f "$BSP/kernel/kernel.release" ] || bash "$REPO_ROOT/common/extract-bsp.sh" --out "$BSP"

mkdir -p "$OUT"
docker run --rm --privileged \
	--cpus "${LISA_BUILD_CPUS:-$(nproc)}" \
	-v lisa-arch-cache:/cache \
	-v lisa-arch-builder:/builder \
	-v "$REPO_ROOT:/src:ro" \
	-v "$BSP:/bsp:ro" \
	-v "$OUT:/out" \
	-e LISA_KVER="$(cat "$BSP/kernel/kernel.release")" \
	-e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
	--security-opt label=disable \
	docker.io/library/archlinux:latest bash /src/arch/builder/build-packages-container.sh "$@"

ls -1 "$OUT"
