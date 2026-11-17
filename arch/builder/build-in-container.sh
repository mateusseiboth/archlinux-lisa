#!/usr/bin/env bash
# Runs in an x86_64 archlinux container (privileged, qemu-aarch64 binfmt on the
# host). Unpacks the official Arch Linux ARM tarball, runs setup-rootfs.sh in it
# and writes the images to /out.
#
# Mounts: /src (repository, read-only), /bsp (extracted BSP), /cache, /work, /out.
# Env: LISA_UI, LISA_KVER, LISA_PASSWORD, HOST_UID, HOST_GID.
set -euo pipefail

ALARM_URL=http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz
TARBALL=/cache/ArchLinuxARM-aarch64-latest.tar.gz
ROOTFS=/work/rootfs

log() {
	echo "==> $*"
}

install_host_tools() {
	pacman -Sy --noconfirm --needed arch-install-scripts e2fsprogs
}

download_alarm() {
	log "Arch Linux ARM tarball"
	curl -fsSL -o "$TARBALL.md5" "$ALARM_URL.md5"
	(cd /cache && sed 's/ .*$/  ArchLinuxARM-aarch64-latest.tar.gz/' "$TARBALL.md5" | md5sum -c --status) 2>/dev/null && return
	curl -fL -o "$TARBALL" "$ALARM_URL"
	(cd /cache && sed 's/ .*$/  ArchLinuxARM-aarch64-latest.tar.gz/' "$TARBALL.md5" | md5sum -c)
}

unpack_rootfs() {
	log "unpack"
	rm -rf "$ROOTFS"
	mkdir -p "$ROOTFS"
	bsdtar -xpf "$TARBALL" -C "$ROOTFS"
}

# Not /tmp: arch-chroot mounts a tmpfs over it.
stage_sources() {
	local build=$ROOTFS/var/tmp/lisa-build
	mkdir -p "$build/src"
	cp -a /src/arch /src/common "$build/src/"
	cp -a /bsp "$build/bsp"
}

run_setup() {
	log "setup (aarch64 chroot)"
	# arch-chroot needs the root to be a mount point.
	mount --bind "$ROOTFS" "$ROOTFS"
	# Packages survive between builds and stay out of the image.
	mkdir -p /cache/pacman-pkg
	mount --bind /cache/pacman-pkg "$ROOTFS/var/cache/pacman/pkg"
	arch-chroot "$ROOTFS" env LISA_UI="$LISA_UI" LISA_KVER="$LISA_KVER" LISA_PASSWORD="$LISA_PASSWORD" \
		bash /var/tmp/lisa-build/src/arch/builder/setup-rootfs.sh
	umount "$ROOTFS/var/cache/pacman/pkg"
	umount "$ROOTFS"
}

# ext4 sized to the content plus room for the first boot; resized to the whole
# userdata partition by lisa-resize-rootfs.service.
make_rootfs_image() {
	local used_mb size_mb
	log "rootfs.img"
	used_mb=$(du -sm --exclude=boot/boot.img --exclude=boot/vendor_boot.img "$ROOTFS" | cut -f1)
	size_mb=$((used_mb * 13 / 10 + 512))
	rm -f /out/rootfs.img
	mkfs.ext4 -q -L lisa-arch -d "$ROOTFS" /out/rootfs.img "${size_mb}M"
}

export_boot_images() {
	cp "$ROOTFS/boot/boot.img" "$ROOTFS/boot/vendor_boot.img" /out/
	cp /bsp/kernel/dtbo.img /out/
	chown "$HOST_UID:$HOST_GID" /out/*
}

install_host_tools
download_alarm
unpack_rootfs
stage_sources
run_setup
make_rootfs_image
export_boot_images
log "pronto: /out"
