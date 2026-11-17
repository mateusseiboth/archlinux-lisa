#!/usr/bin/env bash
# Runs every tests/test-*.sh and fails if any of them fails.
set -u

dir=$(cd "$(dirname "$0")" && pwd)
status=0

for test in "$dir"/test-*.sh; do
	echo "== $(basename "$test")"
	bash "$test" || status=1
done

exit "$status"
