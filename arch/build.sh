#!/usr/bin/env bash
# Builds Arch Linux ARM for the Xiaomi 11 Lite 5G NE (lisa).
#
#   arch/build.sh [component...]     (default: sddm plasma-mobile phosh)
#
# Components live in arch/ui/: sddm (Wayland login screen with session picker),
# plasma-mobile, phosh. With no display manager the image boots to a text login.
#
# Output in out/arch/: rootfs.img (ext4 for userdata), boot.img, vendor_boot.img,
# dtbo.img. Needs Docker and the qemu-aarch64 binfmt handler (flag F) on the host.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
UI=${*:-sddm plasma-mobile phosh}
OUT=$REPO_ROOT/out/arch
BSP=$REPO_ROOT/out/bsp
BUILDER_IMAGE=docker.io/library/archlinux:latest
# The phone user is named after whoever builds the image, unless LISA_USER says otherwise.
USER_NAME=${LISA_USER:-$(id -un)}
PASSWORD=${LISA_PASSWORD:-147147}

die() {
	echo "arch/build.sh: $*" >&2
	exit 1
}

check_host() {
	local component
	for component in $UI; do
		[ -f "$REPO_ROOT/arch/ui/$component/packages" ] || die "componente desconhecido: $component (opções: sddm, plasma-mobile, phosh)"
	done
	grep -q '^flags: .*F' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null ||
		die "qemu-aarch64 binfmt com flag F não registrado (dnf install qemu-user-static)"
	[ -f "$BSP/kernel/kernel.release" ] || bash "$REPO_ROOT/common/extract-bsp.sh" --out "$BSP"
}

check_host
mkdir -p "$OUT"
# Half the cores by default, so the desktop stays usable during the build.
nice -n 10 docker run --rm --privileged \
	--cpus "${LISA_BUILD_CPUS:-$(($(nproc) / 2))}" \
	-v lisa-arch-cache:/cache \
	-v lisa-arch-work:/work \
	-v "$REPO_ROOT:/src:ro" \
	-v "$BSP:/bsp:ro" \
	-v "$OUT:/out" \
	-e LISA_UI="$UI" \
	-e LISA_KVER="$(cat "$BSP/kernel/kernel.release")" \
	-e LISA_USER="$USER_NAME" \
	-e LISA_PASSWORD="$PASSWORD" \
	-e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
	--security-opt label=disable \
	"$BUILDER_IMAGE" bash /src/arch/builder/build-in-container.sh

ls -lh "$OUT"
