#!/usr/bin/env bash
# Runs the addon's Lua 5.1 unit tests: every tests/unit/test_*.lua, or only
# the files given. Prints PASS/FAIL per file; exits 1 if any file failed.
#   bash tests/run.sh [files...]
set -uo pipefail

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADDON="$(cd "$TESTS/.." && pwd)"
ROOT="$(cd "$ADDON/.." && pwd)"

if [ ! -x "$ADDON/.lua51/bin/lua5.1" ]; then
  echo "run tests/setup.sh first" >&2
  exit 2
fi

source "$TESTS/env.sh"

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=()
  for f in "$TESTS"/unit/test_*.lua; do
    [ -e "$f" ] && files+=("$f")
  done
fi
if [ "${#files[@]}" -eq 0 ]; then
  echo "no test files found in $TESTS/unit" >&2
  exit 1
fi

status=0
for f in "${files[@]}"; do
  name="${f#"$ROOT/"}"
  if lua5.1 "$f"; then
    echo "PASS $name"
  else
    echo "FAIL $name"
    status=1
  fi
done
exit "$status"
