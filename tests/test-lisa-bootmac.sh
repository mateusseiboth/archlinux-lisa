#!/usr/bin/env bash
# lisa-bootmac gives Wi-Fi and Bluetooth their own stable addresses: the WCN6750
# ships the generic 00:03:7F:12:22:22 for Wi-Fi and no Bluetooth address at all,
# which leaves hci0 unconfigured (BlueZ ignores it). Addresses come from the
# machine-id; ip and btmgmt are fakes that record their arguments.
set -u
. "$(dirname "$0")/lib.sh"

SCRIPT="$REPO_ROOT/common/rootfs/usr/lib/lisa/lisa-bootmac"
work=$(make_tmpdir)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
for tool in ip btmgmt; do
	printf '#!/bin/sh\necho "%s $*" >>"%s/calls"\n' "$tool" "$work" >"$work/bin/$tool"
	chmod +x "$work/bin/$tool"
done

run_bootmac() {
	: >"$work/calls"
	PATH="$work/bin:$PATH" LISA_MACHINE_ID_FILE="$1" bash "$SCRIPT"
}

echo 0123456789abcdef0123456789abcdef >"$work/id-a"
echo fedcba9876543210fedcba9876543210 >"$work/id-b"

run_bootmac "$work/id-a"
assert_eq 0 $? "sets the addresses"
calls_a=$(cat "$work/calls")
wlan_a=$(sed -n 's/^ip link set dev wlan0 address \(.*\)$/\1/p' "$work/calls")
bt_a=$(sed -n 's/^btmgmt --index 0 public-addr \(.*\)$/\1/p' "$work/calls")

mac_re='^[0-9a-f]{2}(:[0-9a-f]{2}){5}$'
assert_matches "$wlan_a" "$mac_re" "Wi-Fi address well formed"
assert_matches "$bt_a" "$mac_re" "Bluetooth address well formed"
assert_eq 2 $((0x${wlan_a%%:*} & 3)) "Wi-Fi address is locally administered unicast"
assert_ne "$wlan_a" "$bt_a" "Wi-Fi and Bluetooth differ"
assert_contains "$calls_a" "ip link set dev wlan0 down" "takes wlan0 down before the change"
assert_contains "$calls_a" "ip link set dev wlan0 up" "brings wlan0 back up"

run_bootmac "$work/id-a"
assert_eq "$calls_a" "$(cat "$work/calls")" "same machine-id, same addresses"

run_bootmac "$work/id-b"
assert_ne "$wlan_a" "$(sed -n 's/^ip link set dev wlan0 address \(.*\)$/\1/p' "$work/calls")" \
	"another machine-id, another address"

assert_fails "fails without a machine-id" run_bootmac "$work/missing"

finish
