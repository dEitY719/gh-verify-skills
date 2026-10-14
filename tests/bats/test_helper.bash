# shellcheck shell=bash
# Shared bats helper for this repo's tests/bats/*.bats.
#
#   BATS_LIB_PATH=<dir holding bats-support and bats-assert> bats -r tests/bats
#
# Moved here from dEitY719/dotfiles tests/bats/test_helper.bash
# (dEitY719/dotfiles#2200) and cut down to what the moved suites use.

bats_load_library bats-support
bats_load_library bats-assert

# Repo root, from this file's own location (tests/bats/test_helper.bash).
REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT

# A throwaway $HOME, so nothing a test runs can reach the developer's real
# config. CLAUDE_CONFIG_DIR is unset for the same reason: an isolated $HOME is
# not isolation while it still points at a live account dir.
setup_isolated_home() {
    TEST_TEMP_HOME="$(mktemp -d)"
    export TEST_TEMP_HOME HOME="$TEST_TEMP_HOME"
    unset CLAUDE_CONFIG_DIR
    export XDG_CONFIG_HOME="$TEST_TEMP_HOME"
    export XDG_CACHE_HOME="$TEST_TEMP_HOME"
    export XDG_DATA_HOME="$TEST_TEMP_HOME"
    export TERM=dumb
}

teardown_isolated_home() {
    if [ -n "${TEST_TEMP_HOME-}" ] && [ -d "$TEST_TEMP_HOME" ]; then
        rm -rf "$TEST_TEMP_HOME"
    fi
}

# herdr's agent-name rule: ^[a-z][a-z0-9_-]{0,31}$.
assert_valid_herdr_name() {
    [[ "$1" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] ||
        fail "not a valid herdr agent name: '$1'"
}
