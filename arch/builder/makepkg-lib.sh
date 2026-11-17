# Shared by setup-rootfs.sh (image build) and build-packages-chroot.sh (single
# packages): pacman set-up for qemu-user and makepkg as an unprivileged user.
# Runs inside the aarch64 Arch Linux ARM chroot.
#
# Callers set BUILD (work dir with src/, bsp/, pkgs/, repo/) and SRC, and export
# LISA_BSP, LISA_COMMON, LISA_KVER for the PKGBUILDs that repackage the BSP.
# shellcheck shell=bash

log() {
	echo "==> $*"
}

prepare_pacman() {
	# The build volume confuses the space check, and qemu-user has no Landlock
	# for pacman's download sandbox. Both come back in restore_pacman.
	sed -i 's/^CheckSpace/#CheckSpace/' /etc/pacman.conf
	grep -q '^DisableSandbox' /etc/pacman.conf || sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
	pacman-key --init
	pacman-key --populate archlinuxarm
}

# The lisa kernel has Landlock, so the image keeps pacman's sandbox.
restore_pacman() {
	sed -i 's/^#CheckSpace/CheckSpace/; /^DisableSandbox$/d' /etc/pacman.conf
}

ensure_builder_user() {
	id builder >/dev/null 2>&1 || useradd -m builder
	mkdir -p "$BUILD/pkgs" "$BUILD/repo"
	chown builder: "$BUILD/repo"
}

# Extra makepkg options a package asks for (arch/pkgs/<name>/makepkg.flags),
# e.g. --nodeps for the packages that only repackage the BSP.
read_makepkg_flags() {
	local file=$SRC/arch/pkgs/$1/makepkg.flags
	[ -f "$file" ] && cat "$file"
	return 0
}

stage_package() {
	local name=$1 dir=$BUILD/pkgs/$1
	rm -rf "$dir"
	cp -r "$SRC/arch/pkgs/$name" "$dir"
	chown -R builder: "$dir"
	echo "$dir"
}

as_builder() {
	runuser -u builder -- env LISA_BSP="$LISA_BSP" LISA_COMMON="$LISA_COMMON" \
		LISA_KVER="$LISA_KVER" PKGDEST="$BUILD/repo" "$@"
}

# depends, makedepends and checkdepends from the repositories; the ones built
# here (qrtr for rmtfs, ...) from $BUILD/repo.
install_build_deps() {
	local dir=$1 dep local_pkg deps=()
	mapfile -t deps < <(cd "$dir" && as_builder makepkg --printsrcinfo |
		sed -n 's/^\t\(make\|check\)\?depends = \([^<>=]*\).*/\2/p' | sort -u)
	[ ${#deps[@]} -gt 0 ] || return 0
	for dep in "${deps[@]}"; do
		pacman -T "$dep" >/dev/null && continue
		local_pkg=$(find "$BUILD/repo" -maxdepth 1 -name "$dep-[0-9]*.pkg.tar.*" | sort -V | tail -n 1)
		[ -z "$local_pkg" ] || { pacman -U --noconfirm --asdeps "$local_pkg"; continue; }
		pacman -S --noconfirm --needed --asdeps "$dep"
	done
}

build_package() {
	local name=$1 dir flags
	dir=$(stage_package "$name")
	flags=$(read_makepkg_flags "$name")
	case " $flags " in
	*" --nodeps "*) ;;
	*) install_build_deps "$dir" ;;
	esac
	log "makepkg $name"
	# shellcheck disable=SC2086 # flags are separate makepkg options
	(cd "$dir" && as_builder makepkg --noconfirm --cleanbuild --force $flags)
}
