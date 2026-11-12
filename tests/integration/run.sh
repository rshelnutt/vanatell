#!/usr/bin/env bash
# End-to-end test: the real vanatell.lua under the stub Windower (real ws.lua,
# real clock) and a phone client, both against a relay on localhost:8787.
#   bash tests/integration/run.sh
#     XR_RELAY=fake, the default: runs fake_relay.lua on 127.0.0.1:8787 for
#     the length of the test. It keeps its state in memory only.
#   XR_RELAY=external RELAY_KEY=<RELAY_KEY from relay/.dev.vars> bash tests/integration/run.sh
#     tests a relay that is already running, such as `pnpm dev` in relay/.
#     RELAY_URL defaults to http://localhost:8787. Each run creates an account
#     on that relay.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS="$(cd "$HERE/.." && pwd)"
ADDON="$(cd "$TESTS/.." && pwd)"
PORT=8787

if [ ! -x "$ADDON/.lua51/bin/lua5.1" ]; then
  echo "run tests/setup.sh first" >&2
  exit 2
fi

source "$TESTS/env.sh"

LOG=""
case "${XR_RELAY:-fake}" in
  fake)
    if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
      echo "port $PORT in use; set XR_RELAY=external to test against it" >&2
      exit 2
    fi
    LOG="$(mktemp)"
    RELAY_PID=""
    cleanup() {
      if [ -n "$RELAY_PID" ]; then
        kill "$RELAY_PID" 2>/dev/null || true
        wait "$RELAY_PID" 2>/dev/null || true
      fi
      rm -f "$LOG"
    }
    trap cleanup EXIT
    lua5.1 "$HERE/fake_relay.lua" "$PORT" dev-relay-key >"$LOG" 2>&1 &
    RELAY_PID=$!
    READY="fake relay listening on 127.0.0.1:$PORT"
    for _ in $(seq 50); do
      grep -qxF "$READY" "$LOG" && break
      kill -0 "$RELAY_PID" 2>/dev/null || break
      sleep 0.1
    done
    if ! grep -qxF "$READY" "$LOG"; then
      echo "fake relay did not print '$READY' within 5 s" >&2
      cat "$LOG" >&2
      exit 1
    fi
    export RELAY_URL="http://localhost:$PORT" RELAY_KEY=dev-relay-key
    ;;
  external)
    export RELAY_URL="${RELAY_URL:-http://localhost:$PORT}"
    if [ -z "${RELAY_KEY:-}" ]; then
      echo "XR_RELAY=external needs RELAY_KEY, the relay's RELAY_KEY (relay/.dev.vars for pnpm dev)" >&2
      exit 2
    fi
    export RELAY_KEY
    ;;
  *)
    echo "XR_RELAY must be fake or external" >&2
    exit 2
    ;;
esac

status=0
lua5.1 "$HERE/test_live.lua" || status=$?
if [ "$status" -ne 0 ] && [ -n "$LOG" ]; then
  echo "fake relay output:" >&2
  cat "$LOG" >&2
fi
exit "$status"
