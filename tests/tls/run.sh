#!/usr/bin/env bash
# Real TLS test: ws.lua over LuaSec against `openssl s_server` on
# localhost:18443 with a throwaway self-signed certificate for localhost.
# Needs openssl@3 (Homebrew) and LuaSec in addon/.lua51 (tests/setup.sh).
#   bash tests/tls/run.sh
set -euo pipefail

TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDON="$(cd "$TESTS/.." && pwd)"
PORT=18443

if [ ! -x "$ADDON/.lua51/bin/lua5.1" ]; then
  echo "run tests/setup.sh first" >&2
  exit 2
fi
OPENSSL="$(brew --prefix openssl@3)/bin/openssl"
if [ ! -x "$OPENSSL" ]; then
  echo "openssl@3 not found; run tests/setup.sh first" >&2
  exit 2
fi
if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  echo "port $PORT is already in use" >&2
  exit 1
fi

source "$TESTS/env.sh"

# Fixtures and the server live only as long as this script.
D="$(mktemp -d)"
SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$D"
}
trap cleanup EXIT

if ! "$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
    -addext subjectAltName=DNS:localhost -keyout "$D/key.pem" -out "$D/cert.pem" 2>"$D/req.log"; then
  cat "$D/req.log" >&2
  exit 1
fi

"$OPENSSL" s_server -accept "$PORT" -cert "$D/cert.pem" -key "$D/key.pem" -www -quiet >"$D/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 50); do
  nc -z 127.0.0.1 "$PORT" 2>/dev/null && break
  sleep 0.1
done
if ! nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
  echo "openssl s_server did not start listening on $PORT within 5 s" >&2
  cat "$D/server.log" >&2
  exit 1
fi

status=0
lua5.1 "$TESTS/tls/test_tls.lua" "$D/cert.pem" || status=$?
if [ "$status" -ne 0 ]; then
  echo "openssl s_server output:" >&2
  cat "$D/server.log" >&2
fi
exit "$status"
