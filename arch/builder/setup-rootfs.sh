#!/usr/bin/env bash
# Runs inside the aarch64 Arch Linux ARM chroot (qemu-user). Builds the lisa
# packages, installs them with the selected UI components and configures the system.
#
# Env: LISA_UI (space-separated component directories under arch/ui, for example
# "sddm plasma-mobile phosh"), LISA_KVER, LISA_PASSWORD.
set -euo pipefail

BUILD=/var/tmp/lisa-build
SRC=$BUILD/src
export LISA_BSP=$BUILD/bsp
export LISA_COMMON=$SRC/common
export LISA_KVER

# Built in this order: rmtfs and tqftpserv link against qrtr.
NATIVE_PKGS=(qrtr rmtfs tqftpserv qbootctl)
BSP_PKGS=(lisa-firmware lisa-device linux-lisa)
MAKEDEPENDS=(base-devel meson linux-api-headers systemd)

log() {
	echo "==> $*"
}

read_list() {
	[ -f "$1" ] || return 0
	grep -v '^#' "$1" | sed '/^$/d'
}

# base is always installed; each component adds packages, services, a rootfs
# overlay and, for a display manager, the default target.
components() {
	local component
	echo base
	for component in $LISA_UI; do
		echo "$component"
	done
}

read_component_lists() {
	local file=$1 component
	for component in $(components); do
		read_list "$SRC/arch/ui/$component/$file"
	done
}

prepare_pacman() {
	# qemu-user has no landlock and the build volume confuses the space check.
	sed -i 's/^CheckSpace/#CheckSpace/' /etc/pacman.conf
	grep -q '^DisableSandbox' /etc/pacman.conf || sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
	pacman-key --init
	pacman-key --populate archlinuxarm
}

restore_pacman() {
	sed -i 's/^#CheckSpace/CheckSpace/; /^DisableSandbox$/d' /etc/pacman.conf
}

# The generic image kernel and its boot files are useless on lisa.
remove_generic_kernel() {
	local generic
	mapfile -t generic < <(pacman -Qq linux-aarch64 uboot-tools 2>/dev/null || true)
	[ ${#generic[@]} -eq 0 ] || pacman -Rdd --noconfirm "${generic[@]}"
}

build_package() {
	local name=$1
	local dir=$BUILD/pkgs/$name
	cp -r "$SRC/arch/pkgs/$name" "$dir"
	chown -R builder: "$dir"
	(cd "$dir" && runuser -u builder -- env LISA_BSP="$LISA_BSP" LISA_COMMON="$LISA_COMMON" \
		LISA_KVER="$LISA_KVER" PKGDEST="$BUILD/repo" makepkg --noconfirm --cleanbuild)
}

build_native_packages() {
	local name
	for name in "${NATIVE_PKGS[@]}"; do
		log "makepkg $name"
		build_package "$name"
		pacman -U --noconfirm --asdeps "$BUILD"/repo/"$name"-[0-9]*.pkg.tar.*
	done
}

build_bsp_packages() {
	local name
	for name in "${BSP_PKGS[@]}"; do
		log "makepkg $name"
		build_package "$name"
	done
}

install_packages() {
	local name packages=() built=()
	mapfile -t packages < <(read_component_lists packages)
	pacman -S --noconfirm --needed "${packages[@]}"
	for name in "${BSP_PKGS[@]}"; do
		built+=("$BUILD"/repo/"$name"-[0-9]*.pkg.tar.*)
	done
	pacman -U --noconfirm --needed "${built[@]}"
	pacman -D --asexplicit "${NATIVE_PKGS[@]}"
}

apply_ui_overlays() {
	local component overlay
	for component in $(components); do
		overlay=$SRC/arch/ui/$component/rootfs
		[ ! -d "$overlay" ] || cp -a "$overlay/." /
	done
}

enable_services() {
	local target
	read_component_lists services | xargs -r systemctl enable
	target=$(read_component_lists target | tail -n 1)
	systemctl set-default "${target:-multi-user.target}"
	# Nothing here needs the network to be up; waiting only delays boot.
	systemctl mask systemd-networkd-wait-online.service NetworkManager-wait-online.service
}

configure_system() {
	echo lisa >/etc/hostname
	sed -i 's/^#\(en_US.UTF-8\)/\1/; s/^#\(pt_BR.UTF-8\)/\1/' /etc/locale.gen
	locale-gen
	echo LANG=en_US.UTF-8 >/etc/locale.conf
	echo "alarm:$LISA_PASSWORD" | chpasswd
	usermod -aG wheel,video,audio,input,network alarm
	echo '%wheel ALL=(ALL:ALL) ALL' >/etc/sudoers.d/10-wheel
	chmod 440 /etc/sudoers.d/10-wheel
	printf 'PARTLABEL=%s / ext4 rw,relatime 0 1\n' userdata >/etc/fstab
}

cleanup() {
	local orphans
	mapfile -t orphans < <(pacman -Qdtq || true)
	[ ${#orphans[@]} -eq 0 ] || pacman -Rns --noconfirm "${orphans[@]}"
	userdel -r builder 2>/dev/null || true
	restore_pacman
	# The package cache is a bind mount of the build cache (build-in-container.sh).
	rm -rf "$BUILD"
}

prepare_pacman
remove_generic_kernel
pacman -Syu --noconfirm --needed --asdeps "${MAKEDEPENDS[@]}"
useradd -m builder
mkdir -p "$BUILD/pkgs" "$BUILD/repo"
chown builder: "$BUILD/repo"
build_native_packages
build_bsp_packages
install_packages
apply_ui_overlays
enable_services
configure_system
log "lisa-mkbootimg"
lisa-mkbootimg
cleanup
