# archlinux-lisa

Arch Linux ARM for the Xiaomi 11 Lite 5G NE / 11 LE (`lisa`, Snapdragon 778G
SM7325) on the mainline kernel. Plasma Mobile and Phosh are both installed.
The phone logs straight into Plasma Mobile, which starts on its lock screen
(numeric keypad); SDDM's own greeter is not usable on a phone. The app
launcher has "Mudar para Phosh" / "Mudar para Plasma Mobile": they set the
autologin session (`lisa-switch-session`, through pkexec with no password for
the active user) and restart SDDM, which closes the open apps.

The kernel, DTB and firmware are the ones of the postmarketOS port in
[xiaomi-lisa-mainline](https://github.com/mateusseiboth/xiaomi-lisa-mainline),
so the hardware support is the same: display, GPU, touch, Wi-Fi, Bluetooth,
battery, speakers and cameras work; microphones, fingerprint and calls do not.

## How it boots

```
ABL (stock Xiaomi) -> boot_a: U-Boot (u-boot-lisa, branch linux-only)
                   -> vendor_boot_a: the DTB only
U-Boot menu        -> "Arch Linux": sysboot on userdata, /boot/extlinux/extlinux.conf
                   -> /boot/vmlinuz-linux-lisa + /boot/initramfs-linux-lisa.img
```

The rootfs is a plain ext4 written to `userdata` (no partition table inside).
A kernel update is a normal `pacman -Syu`: mkinitcpio rebuilds the initramfs
and U-Boot reads the new files on the next boot. Nothing has to be flashed.

The U-Boot menu (hold Volume Down while powering on) also has fastboot, the UFS
as a USB disk for the PC (UMS), a serial console over USB and a shell.

Booting straight from the ABL without U-Boot also works: `lisa-mkbootimg`
writes `/boot/boot.img` and `/boot/vendor_boot.img` in the layout the ABL
accepts, byte-identical to what pmOS builds.

## Layout

| Path | Content |
| --- | --- |
| `common/lisa.conf` | Boot facts (load offsets, cmdline, root partition) |
| `common/extract-bsp.sh` | Kernel, DTB, modules, firmware and device files out of the pmbootstrap packages, into `out/bsp/` |
| `common/mkbootimg-lisa.sh` | boot.img + vendor_boot.img for the stock ABL |
| `common/lisa-mkbootimg` | The same from inside the installed system (pacman hook) |
| `common/rootfs/` | USB network gadget (172.16.42.1), first-boot growth of the rootfs to the whole userdata, Power key left to the shell, stable Wi-Fi and Bluetooth addresses (`lisa-bootmac`) |
| `arch/pkgs/` | PKGBUILDs: `linux-lisa`, `lisa-firmware`, `lisa-device`, and the Qualcomm services Arch Linux ARM does not ship (`qrtr`, `rmtfs`, `tqftpserv`, `qbootctl`) |
| `arch/ui/` | Image components: `base`, `sddm` (display manager on Wayland), `plasma-mobile` (autologin, locked at start), `phosh` |
| `arch/build.sh` | The image builder (Docker, Arch Linux ARM tarball, qemu-user chroot) |
| `tests/` | `bash tests/run.sh` |

## Build

Needs Docker and the `qemu-aarch64` binfmt handler with the `F` flag
(`qemu-user-static` on Fedora). No root on the host.

```sh
bash common/extract-bsp.sh            # from the pmbootstrap packages of xiaomi-lisa
bash arch/build.sh                    # sddm plasma-mobile phosh
bash arch/build.sh sddm plasma-mobile # or any set of components
```

Single packages, without rebuilding the image, in a builder chroot kept
between runs, then installed on the phone over the USB network:

```sh
bash arch/build-packages.sh lisa-device hexagonrpcd   # -> out/arch/pkgs/
bash arch/deploy.sh out/arch/pkgs/lisa-device-*.pkg.tar.*
```

A device tree change reaches the phone through vendor_boot_a (the ABL hands
its DTB to U-Boot and Linux): `tools/flash-dtb.sh <dtb>` writes a DTB-only
vendor_boot over SSH, keeps the old one in `out/vendor_boot-backup/` and reads
the new one back.

Output in `out/arch/`: `rootfs.img`, plus `boot.img`, `vendor_boot.img` and
`dtbo.img` for booting without U-Boot. The build uses every CPU core
(`LISA_BUILD_CPUS` limits it).

The phone user is named after the user running the build (`LISA_USER` changes
it), password `147147` (`LISA_PASSWORD`).

## Install

1. ABL fastboot (Power + Volume Down): flash `boot_a` with U-Boot from
   [u-boot-lisa](https://github.com/mateusseiboth/u-boot-lisa) (branch
   `linux-only`) and `vendor_boot_a` with a vendor_boot v3 holding the DTB.
2. U-Boot menu, "USB disk for the PC": the phone's UFS LUN 0 shows up on the
   PC. Write the rootfs to the `userdata` partition:
   `dd if=out/arch/rootfs.img of=/dev/sdX33 bs=4M oflag=direct status=progress`.
3. Eject the disk on the PC: the phone restarts into Arch Linux.

Over USB, the phone answers at `ssh <user>@172.16.42.1`.
