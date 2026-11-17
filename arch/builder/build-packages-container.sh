#!/usr/bin/env bash
# Runs in an x86_64 archlinux container (privileged, qemu-aarch64 binfmt on the
# host). Keeps an Arch Linux ARM builder chroot in /builder between runs and
# builds the named packages there; the results land in /out.
#
# Mounts: /src (repository, read-only), /bsp, /cache, /builder, /out.
# Env: LISA_KVER, HOST_UID, HOST_GID. Arguments: package names.
set -euo pipefail

ALARM_URL=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
TARBALL=/cache/ArchLinuxARM-aarch64-latest.tar.gz
ROOTFS=/builder/rootfs
BUILD=$ROOTFS/var/tmp/lisa-build

pacman -Sy --noconfirm --needed arch-install-scripts >/dev/null

[ -d "$ROOTFS/usr" ] || {
	[ -f "$TARBALL" ] || curl -fL -o "$TARBALL" "$ALARM_URL"
	mkdir -p "$ROOTFS"
	bsdtar -xpf "$TARBALL" -C "$ROOTFS"
}

# Fresh sources every run; packages built before stay available as local deps.
rm -rf "$BUILD/src" "$BUILD/bsp" "$BUILD/pkgs"
mkdir -p "$BUILD/src" "$BUILD/repo"
cp -a /src/arch /src/common "$BUILD/src/"
cp -a /bsp "$BUILD/bsp"
find /out -maxdepth 1 -name '*.pkg.tar.*' -exec cp -n {} "$BUILD/repo/" \;

# Everything newer than this mark leaves for /out, split packages included.
touch "$BUILD/.started"
mountpoint -q "$ROOTFS" || mount --bind "$ROOTFS" "$ROOTFS"
mkdir -p /cache/pacman-pkg
mount --bind /cache/pacman-pkg "$ROOTFS/var/cache/pacman/pkg"
arch-chroot "$ROOTFS" env LISA_KVER="$LISA_KVER" \
	bash /var/tmp/lisa-build/src/arch/builder/build-packages-chroot.sh "$@"
umount "$ROOTFS/var/cache/pacman/pkg"
umount "$ROOTFS"

find "$BUILD/repo" -maxdepth 1 -name '*.pkg.tar.*' -newer "$BUILD/.started" -exec cp {} /out/ \;
chown "$HOST_UID:$HOST_GID" /out/*
