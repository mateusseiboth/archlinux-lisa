#!/usr/bin/env bash
# lisa-usb-gadget exposes an NCM network function on the USB port (same IDs as
# pmOS), so the phone answers at 172.16.42.1 during bring-up. Exercised against
# a fake configfs + UDC directory.
set -u
. "$(dirname "$0")/lib.sh"

SCRIPT="$REPO_ROOT/common/rootfs/usr/lib/lisa/lisa-usb-gadget"
work=$(make_tmpdir)
trap 'rm -rf "$work"' EXIT

configfs="$work/config"
udc="$work/udc"
mkdir -p "$configfs/usb_gadget" "$udc/a600000.usb"
echo "0123456789abcdef0123456789abcdef" >"$work/machine-id"

run_gadget() {
	LISA_CONFIGFS="$configfs" LISA_UDC_DIR="$udc" LISA_MACHINE_ID_FILE="$work/machine-id" bash "$SCRIPT"
}

run_gadget
assert_eq 0 $? "configures the gadget"

g="$configfs/usb_gadget/lisa"
assert_eq 0x18d1 "$(cat "$g/idVendor")" "vendor id as pmOS"
assert_eq 0xd001 "$(cat "$g/idProduct")" "product id as pmOS"
assert_eq "Xiaomi 11 Lite 5G NE" "$(cat "$g/strings/0x409/product")" "product name"
assert_eq 0123456789abcdef "$(cat "$g/strings/0x409/serialnumber")" "serial from machine-id"
assert_file "$g/functions/ncm.usb0" "NCM function"
assert_eq "$g/functions/ncm.usb0" "$(readlink "$g/configs/c.1/ncm.usb0")" "NCM linked into the configuration"
assert_eq a600000.usb "$(cat "$g/UDC")" "bound to the USB controller"

run_gadget
assert_eq 0 $? "running again keeps the existing gadget"

rm -rf "$configfs/usb_gadget/lisa" "$udc/a600000.usb"
assert_fails "fails without a USB controller" run_gadget

finish
