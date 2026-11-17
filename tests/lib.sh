# Minimal assertion helpers shared by every tests/test-*.sh.
# shellcheck shell=bash

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export REPO_ROOT

FAILURES=0

fail() {
	echo "  FAIL: $*" >&2
	FAILURES=$((FAILURES + 1))
}

pass() {
	echo "  ok: $*"
}

assert_eq() {
	local expected=$1 actual=$2 label=$3
	[ "$expected" = "$actual" ] || { fail "$label: expected [$expected], got [$actual]"; return; }
	pass "$label"
}

assert_ne() {
	local unexpected=$1 actual=$2 label=$3
	[ "$unexpected" != "$actual" ] || { fail "$label: got [$actual]"; return; }
	pass "$label"
}

assert_matches() {
	local value=$1 regex=$2 label=$3
	[[ $value =~ $regex ]] || { fail "$label: [$value] does not match $regex"; return; }
	pass "$label"
}

assert_contains() {
	local haystack=$1 needle=$2 label=$3
	case "$haystack" in
	*"$needle"*) pass "$label" ;;
	*) fail "$label: [$needle] not found in [$haystack]" ;;
	esac
}

assert_same_file() {
	local expected=$1 actual=$2 label=$3
	cmp -s "$expected" "$actual" || { fail "$label: $actual differs from $expected"; return; }
	pass "$label"
}

assert_file() {
	local path=$1 label=$2
	[ -e "$path" ] || { fail "$label: $path missing"; return; }
	pass "$label"
}

assert_no_file() {
	local path=$1 label=$2
	[ ! -e "$path" ] || { fail "$label: $path should not exist"; return; }
	pass "$label"
}

assert_fails() {
	local label=$1
	shift
	"$@" >/dev/null 2>&1 && { fail "$label: command succeeded"; return; }
	pass "$label"
}

make_tmpdir() {
	mktemp -d "${TMPDIR:-/tmp}/lisa-linux-test.XXXXXX"
}

finish() {
	[ "$FAILURES" -eq 0 ] || { echo "$FAILURES failure(s)" >&2; exit 1; }
	echo "all passed"
}
