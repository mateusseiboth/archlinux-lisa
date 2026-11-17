# archlinux-lisa: notes for agents

- Shell project. Gate before finishing: `bash tests/run.sh` and shellcheck through Docker
  (`docker run --rm -v "$PWD:/mnt:ro" -w /mnt docker.io/koalaman/shellcheck:stable -x -s bash ...`).
  Tests come first (red, then green).
- The host has no passwordless sudo: everything that needs root runs in a privileged Docker container.
- Boot facts live only in `common/lisa.conf`. `tests/test-mkbootimg-matches-pmos.sh` proves the ABL images are
  byte-identical to the pmOS ones that boot. Keep it passing.
- The phone boots through U-Boot on boot_a (repo u-boot-lisa, branch `linux-only`, env in
  `board/qualcomm/hakios-lisa.env`, checked by `test-env.sh`). Linux gets the ABL's DTB (prevbl_fdt_addr), not an
  extlinux `fdt` line.
- UI components are data: `arch/ui/<name>/{packages,services,target,rootfs/}`. Add a component, not an `if`.
- Lomiri is not packaged for Arch (only lomiri-ui-toolkit in the AUR, 2026-11); that would be its own project.
- Never commit firmware, `out/` or backups. Commit messages carry no AI attribution.
