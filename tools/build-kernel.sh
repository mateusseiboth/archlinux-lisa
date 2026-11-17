#!/usr/bin/env bash
# Builds the lisa kernel from a git tree (the sc7280-mainline base plus the
# pmaports patches) the way the pmaports APKBUILD does, with Alpine's clang
# (LLVM=1: the config enables CFI, so a GCC build would not match), in Docker.
# The result is laid out like the kernel package, for
# common/extract-bsp.sh --kernel-root.
#
#   tools/build-kernel.sh            -> out/kernel-root/
#
# Env: LISA_KERNEL_SRC (default ~/Dev/mobile/linux-lisa), LISA_KERNEL_CONFIG
# (default the pmaports config), LISA_BUILD_CPUS.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
SRC=${LISA_KERNEL_SRC:-$HOME/Dev/mobile/linux-lisa}
CONFIG=${LISA_KERNEL_CONFIG:-$HOME/Dev/mobile/pmaports/device/community/linux-postmarketos-qcom-sc7280/config-postmarketos-qcom-sc7280.aarch64}
OUT=$REPO_ROOT/out/kernel-root
FLAVOR=postmarketos-qcom-sc7280

die() {
	echo "build-kernel: $*" >&2
	exit 1
}

[ -f "$SRC/Makefile" ] || die "árvore do kernel não encontrada: $SRC"
[ -f "$CONFIG" ] || die "config não encontrada: $CONFIG"
# An out-of-tree build refuses a tree configured in place. Only those files go:
# mrproper would also delete sources (it removes *.i, and this tree has
# firmware as .i files).
rm -rf "$SRC/.config" "$SRC/include/config" "$SRC/include/generated" "$SRC/arch/arm64/include/generated"

rm -rf "$OUT"
mkdir -p "$OUT"
docker run --rm \
	--cpus "${LISA_BUILD_CPUS:-$(nproc)}" \
	-v "$SRC:/src:ro" \
	-v "$CONFIG:/config:ro" \
	-v lisa-kernel-build:/build \
	-v "$OUT:/out" \
	-e FLAVOR="$FLAVOR" \
	-e BUILD_VERSION="lisa-$(git -C "$SRC" rev-parse --short HEAD)" \
	-e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
	--security-opt label=disable \
	docker.io/library/alpine:edge sh -euc '
		# The pmaports makedepends, plus build-base that every abuild chroot has.
		apk add --no-cache bash bc bison build-base clang coreutils diffutils elfutils-dev findutils flex \
			linux-headers lld llvm openssl openssl-dev pahole perl python3 tar xz zstd >/dev/null
		k() { make -C /src O=/build ARCH=arm64 LLVM=1 "$@"; }
		cp /config /build/.config
		k olddefconfig >/dev/null
		k -j"$(nproc)" KBUILD_BUILD_VERSION="$BUILD_VERSION"
		install -Dm644 /build/arch/arm64/boot/vmlinuz /out/boot/vmlinuz
		install -Dm644 /build/arch/arm64/boot/vmlinuz.efi /out/boot/linux.efi
		k modules_install dtbs_install INSTALL_MOD_PATH=/out/usr INSTALL_MOD_STRIP=1 \
			INSTALL_DTBS_PATH=/out/boot/dtbs >/dev/null
		rm -f /out/usr/lib/modules/*/build
		install -D /build/include/config/kernel.release "/out/usr/share/kernel/$FLAVOR/kernel.release"
		chown -R "$HOST_UID:$HOST_GID" /out
	'

echo "kernel $(cat "$OUT/usr/share/kernel/$FLAVOR/kernel.release") em $OUT"
