# Source me (bash or zsh): puts the addon's Lua 5.1 toolchain, its rocks
# tree and the test stubs on the search paths.
#   source tests/env.sh

_xr_env_tests="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

_xr_env() {
  local tests="$1"
  local addon prefix
  addon="$(cd "$tests/.." && pwd)"
  prefix="$addon/.lua51"
  eval "$(luarocks --lua-version=5.1 --lua-dir="$prefix" --tree="$prefix" path)"
  export PATH="$prefix/bin:$PATH"
  export LUA_PATH="$tests/stubs/?.lua;$tests/lib/?.lua;${LUA_PATH:-}"
  export XR_ADDON_DIR="$addon/"
}

_xr_env "$_xr_env_tests"
unset -f _xr_env
unset _xr_env_tests
