#!/usr/bin/env bash
# Runs inside the persistent aarch64 builder chroot (build-packages-container.sh)
# and builds the named packages from arch/pkgs into $BUILD/repo.
#
#   build-packages-chroot.sh <package>...
# Env: LISA_KVER.
set -euo pipefail

BUILD=/var/tmp/lisa-build
SRC=$BUILD/src
export LISA_BSP=$BUILD/bsp
export LISA_COMMON=$SRC/common
export LISA_KVER

# shellcheck source=arch/builder/makepkg-lib.sh
. "$SRC/arch/builder/makepkg-lib.sh"

[ -f /var/lib/lisa-builder-ready ] || {
	prepare_pacman
	pacman -Syu --noconfirm --needed base-devel
	touch /var/lib/lisa-builder-ready
}
pacman -Syu --noconfirm
ensure_builder_user
chown -R builder: "$BUILD/repo"
for name in "$@"; do
	build_package "$name"
done
