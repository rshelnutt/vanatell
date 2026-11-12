#!/usr/bin/env bash
# Builds the addon's test toolchain: Lua 5.1.5 into .lua51, and
# luasocket and LuaSec (against Homebrew openssl@3) into the same rocks tree.
# Safe to re-run.
set -euo pipefail

ADDON="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="$ADDON/.lua51"
BUILD="$ADDON/.lua51-build"
LUA_URL="https://www.lua.org/ftp/lua-5.1.5.tar.gz"
LUA_SHA256="2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333"
TARBALL="$BUILD/lua-5.1.5.tar.gz"
SRC="$BUILD/lua-5.1.5"
MAKE_LOG="$BUILD/make-macosx.log"

# True when a make log shows a readline error. Lines that are echoed
# commands (make ... MYLIBS="-lreadline", gcc ... -lreadline) don't count.
readline_failed() {
  grep -i readline "$1" | grep -Ev '^([^ ]*/)?(make|gcc|cc|clang)( |$)' >/dev/null
}

lua_version="$("$PREFIX/bin/lua5.1" -v 2>&1 || true)"
case "$lua_version" in
  *"Lua 5.1.5"*)
    echo "Lua 5.1.5 already built in $PREFIX"
    ;;
  *)
    mkdir -p "$BUILD"
    curl -fsSL "$LUA_URL" -o "$TARBALL"
    actual="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
    if [ "$actual" != "$LUA_SHA256" ]; then
      echo "lua-5.1.5.tar.gz sha256 mismatch: expected $LUA_SHA256, got $actual" >&2
      rm -f "$TARBALL"
      exit 1
    fi
    rm -rf "$SRC"
    tar -xzf "$TARBALL" -C "$BUILD"
    (
      cd "$SRC"
      if ! make macosx 2>&1 | tee "$MAKE_LOG"; then
        if ! readline_failed "$MAKE_LOG"; then
          echo "make macosx failed (not a readline problem); see $MAKE_LOG" >&2
          exit 1
        fi
        echo "make macosx failed on readline; building without it" >&2
        make clean
        make -C src all MYCFLAGS="-DLUA_USE_POSIX -DLUA_USE_DLOPEN" MYLIBS=""
      fi
      make install INSTALL_TOP="$PREFIX"
    )
    ln -sf lua "$PREFIX/bin/lua5.1"
    ;;
esac

brew list luarocks >/dev/null 2>&1 || brew install luarocks
luarocks --lua-version=5.1 --lua-dir="$PREFIX" --tree="$PREFIX" install luasocket 3.1.0-1
# Windower bundles LuaSec 1.0.2, so the tests use the same version.
brew list openssl@3 >/dev/null 2>&1 || brew install openssl@3
luarocks --lua-version=5.1 --lua-dir="$PREFIX" --tree="$PREFIX" install luasec 1.0.2-1 OPENSSL_DIR="$(brew --prefix openssl@3)"
