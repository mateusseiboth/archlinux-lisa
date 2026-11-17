#!/usr/bin/env bash
# lisa-switch-session sets the session SDDM logs into (Plasma Mobile or Phosh)
# and restarts SDDM so the new one opens. Exercised on a fake config, a fake
# sessions directory and a restart command that only leaves a mark.
set -u
. "$(dirname "$0")/lib.sh"

SCRIPT="$REPO_ROOT/arch/ui/sddm/rootfs/usr/lib/lisa/lisa-switch-session"
work=$(make_tmpdir)
trap 'rm -rf "$work"' EXIT

conf="$work/20-autologin.conf"
sessions="$work/wayland-sessions"
mkdir -p "$sessions"
touch "$sessions/plasma-mobile.desktop" "$sessions/phosh.desktop"

reset_conf() {
	printf '# comment\n[Autologin]\nUser=mateusseiboth\nSession=plasma-mobile\nRelogin=false\n' >"$conf"
	rm -f "$work/restarted"
}

switch_to() {
	LISA_AUTOLOGIN_CONF="$conf" LISA_SESSIONS_DIR="$sessions" \
		LISA_RESTART_DM="touch $work/restarted" bash "$SCRIPT" "$@"
}

reset_conf
switch_to phosh >/dev/null
assert_eq 0 $? "switches to Phosh"
assert_eq "Session=phosh" "$(grep '^Session=' "$conf")" "autologin session is phosh"
assert_eq "User=mateusseiboth" "$(grep '^User=' "$conf")" "keeps the user"
assert_eq "Relogin=false" "$(grep '^Relogin=' "$conf")" "keeps the other settings"
assert_file "$work/restarted" "restarts the display manager"

switch_to plasma-mobile >/dev/null
assert_eq "Session=plasma-mobile" "$(grep '^Session=' "$conf")" "switches back to Plasma Mobile"

reset_conf
assert_fails "refuses a session that is not installed" switch_to gnome
assert_eq "Session=plasma-mobile" "$(grep '^Session=' "$conf")" "config untouched after a refusal"
assert_no_file "$work/restarted" "no restart after a refusal"

assert_fails "refuses a call without a session" switch_to
assert_fails "refuses a session name with a path" switch_to ../phosh

finish
