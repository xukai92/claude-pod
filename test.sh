#!/bin/bash
# Test suite for claude-pod. Runs without podman — tests script structure,
# helper functions, and CLI behavior.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CP="$TEST_DIR/claude-pod.bash"
RESULTS_FILE=$(mktemp)
echo "0 0" > "$RESULTS_FILE"
trap 'rm -f "$RESULTS_FILE"' EXIT

pass() {
    read -r p f < "$RESULTS_FILE"
    echo "$((p + 1)) $f" > "$RESULTS_FILE"
    echo "  PASS: $1"
}
fail() {
    read -r p f < "$RESULTS_FILE"
    echo "$p $((f + 1))" > "$RESULTS_FILE"
    echo "  FAIL: $1 — $2"
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        pass "$desc"
    else
        fail "$desc" "expected '$expected', got '$actual'"
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc" "output does not contain '$needle'"
    fi
}

assert_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$desc"
    else
        fail "$desc" "output unexpectedly contains '$needle'"
    fi
}

# Source helpers without running main (stop before case statement)
source_helpers() {
    local tmp
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' RETURN
    sed '/^case/,$d' "$CP" > "$tmp"
    source "$tmp"
}

# --- Tests ---

echo "=== CLI tests ==="

# --version
out=$("$CP" --version 2>&1)
assert_contains "--version shows version" "$out" "claude-pod"
assert_contains "--version has semver" "$out" "0."

# --help
out=$("$CP" --help 2>&1 || true)
assert_contains "--help shows usage" "$out" "Usage: claude-pod"
assert_contains "--help shows version" "$out" "claude-pod 0."
assert_contains "--help shows install" "$out" "install"
assert_contains "--help shows build" "$out" "build"
assert_contains "--help shows run" "$out" "run"
assert_contains "--help shows shell" "$out" "shell"
assert_contains "--help shows exec" "$out" "exec"
assert_contains "--help shows ps" "$out" "ps"
assert_contains "--help shows clean" "$out" "clean"
assert_contains "--help shows --keep-groups" "$out" "--keep-groups"
assert_contains "--help shows --max-memory" "$out" "--max-memory"
assert_contains "--help shows --port" "$out" "--port"
assert_contains "--help shows --writable-dir" "$out" "--writable-dir"
assert_contains "--help shows --detach" "$out" "--detach"
assert_contains "--help shows --network" "$out" "--network"
assert_contains "--help shows --host-loopback" "$out" "--host-loopback"
assert_contains "--help shows --notify" "$out" "--notify"
assert_contains "--help shows --env" "$out" "--env"
assert_contains "--help shows --gpu" "$out" "--gpu"
assert_contains "--help shows --no-yolo" "$out" "--no-yolo"
assert_contains "--help shows config path" "$out" "config.toml"

# -V alias
out=$("$CP" -V 2>&1)
assert_contains "-V is alias for --version" "$out" "claude-pod"

# Syntax
echo ""
echo "=== Syntax tests ==="
bash -n "$CP" && pass "script syntax valid" || fail "script syntax valid" "bash -n failed"
sh -n "$TEST_DIR/entrypoint.sh" && pass "entrypoint.sh syntax valid" || fail "entrypoint.sh syntax valid" "sh -n failed"

# --- Helper function tests (sourced) ---
echo ""
echo "=== Helper function tests ==="
(
    source_helpers

    # cwd_needs_mount
    assert_eq "cwd_needs_mount: /tmp needs mount" "true" \
        "$(cwd_needs_mount /tmp && echo true || echo false)"
    assert_eq "cwd_needs_mount: HOME does not" "false" \
        "$(cwd_needs_mount "$HOME" && echo true || echo false)"
    assert_eq "cwd_needs_mount: HOME subdir does not" "false" \
        "$(cwd_needs_mount "$HOME/src" && echo true || echo false)"

    # resolve_dirs — needs BASH_SOURCE[0] to point at the real script location.
    # Create a temp wrapper that sources the helpers from the correct path.
    tmp_wrapper=$(mktemp "$TEST_DIR/.test-resolve-XXXXXX")
    sed '/^case/,$d' "$CP" > "$tmp_wrapper"
    echo 'resolve_dirs; echo "$SCRIPT_DIR|$BUILD_DIR"' >> "$tmp_wrapper"
    out=$(bash "$tmp_wrapper" 2>/dev/null || true)
    rm -f "$tmp_wrapper"
    assert_eq "resolve_dirs: SCRIPT_DIR matches test dir" "$TEST_DIR" "${out%%|*}"
    assert_eq "resolve_dirs: BUILD_DIR is SCRIPT_DIR when clone" "$TEST_DIR" "${out##*|}"

    # has_local_build_files — set vars directly since we can't rely on BASH_SOURCE
    SCRIPT_DIR="$TEST_DIR"
    BUILD_DIR="$TEST_DIR"
    has_local_build_files && pass "has_local_build_files: true in clone" \
        || fail "has_local_build_files: true in clone" "returned false"
    SCRIPT_DIR="/nonexistent"
    has_local_build_files && fail "has_local_build_files: false when no files" "returned true" \
        || pass "has_local_build_files: false when no files"

    # die (calls exit, so test in a nested bash with just the function)
    out=$(bash -c 'die() { echo "error: $*" >&2; exit 1; }; die "test error"' 2>&1 || true)
    assert_contains "die: prints error" "$out" "error: test error"

    # cfg_get with no config file
    out=$(CONFIG_FILE="/nonexistent" cfg_get "section" "key")
    assert_eq "cfg_get: empty when no config" "" "$out"

    # HOST_OS variable
    assert_eq "HOST_OS matches uname" "$(uname -s)" "$HOST_OS"

    # is_macos
    if [[ "$(uname -s)" == "Darwin" ]]; then
        is_macos && pass "is_macos: true on macOS" || fail "is_macos: true on macOS" "returned false"
    else
        is_macos && fail "is_macos: false on Linux" "returned true" || pass "is_macos: false on Linux"
    fi

    # portable_realpath
    cwd_before=$(pwd)
    rp_out=$(portable_realpath "$CP")
    cp_dir_phys=$(cd "$(dirname "$CP")" && pwd -P)
    cp_phys="${cp_dir_phys}/$(basename "$CP")"
    assert_eq "portable_realpath: resolves to physical path" "$cp_phys" "$rp_out"
    assert_eq "portable_realpath: preserves PWD" "$cwd_before" "$(pwd)"

    # parse_shared_flags: typical case with all flag types
    env_vars=(); gpu=false; host_loopback=false; max_memory=""; network=""
    ports=(); writable_dirs=(); _parse_remaining=()
    parse_shared_flags -e FOO=bar --gpu --host-loopback --max-memory 4g \
        --network=host -p 3000:3000 --port=8080:80 -wd /tmp --unknown extra
    assert_eq "parse_shared_flags: env_vars" "FOO=bar" "${env_vars[0]}"
    assert_eq "parse_shared_flags: gpu" "true" "$gpu"
    assert_eq "parse_shared_flags: host_loopback" "true" "$host_loopback"
    assert_eq "parse_shared_flags: max_memory" "4g" "$max_memory"
    assert_eq "parse_shared_flags: network" "host" "$network"
    assert_eq "parse_shared_flags: ports count" "2" "${#ports[@]}"
    assert_eq "parse_shared_flags: port 0" "3000:3000" "${ports[0]}"
    assert_eq "parse_shared_flags: port 1" "8080:80" "${ports[1]}"
    assert_eq "parse_shared_flags: writable_dirs" "/tmp" "${writable_dirs[0]}"
    assert_eq "parse_shared_flags: remaining 0" "--unknown" "${_parse_remaining[0]}"
    assert_eq "parse_shared_flags: remaining 1" "extra" "${_parse_remaining[1]}"

    # parse_shared_flags: empty input leaves defaults
    env_vars=(); gpu=false; host_loopback=false; max_memory=""; network=""
    ports=(); writable_dirs=(); _parse_remaining=()
    parse_shared_flags
    assert_eq "parse_shared_flags: empty env_vars" "0" "${#env_vars[@]}"
    assert_eq "parse_shared_flags: empty remaining" "0" "${#_parse_remaining[@]}"
    assert_eq "parse_shared_flags: gpu default" "false" "$gpu"

    # parse_shared_flags: --env missing value (should die/exit non-zero)
    out=$(bash -c "source <(sed '/^case/,\$d' '$CP'); parse_shared_flags --env" 2>&1 || true)
    assert_contains "parse_shared_flags: --env missing value errors" "$out" "error"

    # parse_shared_flags: --port missing value
    out=$(bash -c "source <(sed '/^case/,\$d' '$CP'); parse_shared_flags --port" 2>&1 || true)
    assert_contains "parse_shared_flags: --port missing value errors" "$out" "error"
)

# --- Entrypoint tests ---
echo ""
echo "=== Entrypoint tests ==="
ep=$(cat "$TEST_DIR/entrypoint.sh")
assert_contains "entrypoint: uses CLAUDE_POD_CMD" "$ep" "CLAUDE_POD_CMD"
assert_contains "entrypoint: defaults to claude" "$ep" '${CLAUDE_POD_CMD:-claude}'
assert_contains "entrypoint: fish path" "$ep" '*/fish)'
assert_contains "entrypoint: dangerously-skip-permissions" "$ep" "--dangerously-skip-permissions"
assert_contains "entrypoint: CLAUDE_POD_SHELL check" "$ep" "CLAUDE_POD_SHELL"
assert_contains "entrypoint: NOTIFY_CMD support" "$ep" "NOTIFY_CMD"
assert_contains "entrypoint: CLAUDE_POD_NO_YOLO support" "$ep" "CLAUDE_POD_NO_YOLO"

# --- Project config tests ---
echo ""
echo "=== Project config tests ==="
(
    source_helpers

    # Create temp dirs for config testing
    proj_dir=$(mktemp -d)
    global_dir=$(mktemp -d)
    trap 'rm -rf "$proj_dir" "$global_dir"' EXIT

    global_cfg="$global_dir/config.toml"
    proj_cfg="$proj_dir/.claude-pod.toml"

    # --- load_project_config ---
    load_project_config "$proj_dir"
    assert_eq "load_project_config: no file = empty" "" "$PROJECT_CONFIG"

    cat > "$proj_cfg" <<'TOML'
[defaults]
writable_dirs = ["/proj/a", "/proj/b"]
extra_env = ["PROJ_VAR=1"]
TOML
    load_project_config "$proj_dir"
    assert_eq "load_project_config: sets PROJECT_CONFIG" "$proj_cfg" "$PROJECT_CONFIG"

    # --- cfg_get with explicit file arg ---
    cat > "$global_cfg" <<'TOML'
[defaults]
notify_command = "echo global"
TOML
    out=$(cfg_get "defaults" "notify_command" "$global_cfg")
    assert_eq "cfg_get: reads explicit file" "echo global" "$out"

    # --- cfg_get_array with explicit file arg ---
    out=$(cfg_get_array "defaults" "writable_dirs" "$proj_cfg" | tr '\n' ',')
    assert_eq "cfg_get_array: reads project file" "/proj/a,/proj/b," "$out"

    # --- cfg_get_merged: project wins over global ---
    CONFIG_FILE="$global_cfg"
    cat > "$proj_cfg" <<'TOML'
[defaults]
notify_command = "echo project"
TOML
    PROJECT_CONFIG="$proj_cfg"
    out=$(cfg_get_merged "defaults" "notify_command")
    assert_eq "cfg_get_merged: project wins" "echo project" "$out"

    # --- cfg_get_merged: falls back to global ---
    PROJECT_CONFIG="$proj_cfg"
    out=$(cfg_get_merged "defaults" "nonexistent_key")
    assert_eq "cfg_get_merged: falls back to global for missing key" "" "$out"

    cat >> "$global_cfg" <<'TOML'
fallback_key = "global_val"
TOML
    out=$(cfg_get_merged "defaults" "fallback_key")
    assert_eq "cfg_get_merged: global fallback works" "global_val" "$out"

    # --- cfg_get_array_merged: appends project to global ---
    cat > "$global_cfg" <<'TOML'
[defaults]
writable_dirs = ["/global/x"]
extra_env = ["GLOBAL=1"]
TOML
    cat > "$proj_cfg" <<'TOML'
[defaults]
writable_dirs = ["/proj/a", "/proj/b"]
extra_env = ["PROJ=2"]
TOML
    CONFIG_FILE="$global_cfg"
    PROJECT_CONFIG="$proj_cfg"
    out=$(cfg_get_array_merged "defaults" "writable_dirs" | tr '\n' ',')
    assert_eq "cfg_get_array_merged: merges writable_dirs" "/global/x,/proj/a,/proj/b," "$out"
    out=$(cfg_get_array_merged "defaults" "extra_env" | tr '\n' ',')
    assert_eq "cfg_get_array_merged: merges extra_env" "GLOBAL=1,PROJ=2," "$out"

    # --- cfg_get_array_merged: no project config = global only ---
    PROJECT_CONFIG=""
    out=$(cfg_get_array_merged "defaults" "writable_dirs" | tr '\n' ',')
    assert_eq "cfg_get_array_merged: global only when no project" "/global/x," "$out"

    # --- cfg_get_merged: project can override to empty ---
    cat > "$proj_cfg" <<'TOML'
[defaults]
notify_command = ""
TOML
    PROJECT_CONFIG="$proj_cfg"
    cat > "$global_cfg" <<'TOML'
[defaults]
notify_command = "echo global"
TOML
    CONFIG_FILE="$global_cfg"
    out=$(cfg_get_merged "defaults" "notify_command")
    assert_eq "cfg_get_merged: project overrides to empty" "" "$out"

    # --- cfg_has_key ---
    cfg_has_key "defaults" "notify_command" "$global_cfg" && pass "cfg_has_key: finds existing key" \
        || fail "cfg_has_key: finds existing key" "returned false"
    cfg_has_key "defaults" "no_such_key" "$global_cfg" && fail "cfg_has_key: missing key" "returned true" \
        || pass "cfg_has_key: missing key returns false"

    # cfg_has_key with no-space format (key="value")
    nospace_cfg=$(mktemp)
    cat > "$nospace_cfg" <<'TOML'
[defaults]
notify_command="echo compact"
TOML
    cfg_has_key "defaults" "notify_command" "$nospace_cfg" && pass "cfg_has_key: no-space key=value" \
        || fail "cfg_has_key: no-space key=value" "returned false"

    # cfg_get with no-space format
    out=$(cfg_get "defaults" "notify_command" "$nospace_cfg")
    assert_eq "cfg_get: no-space key=value" "echo compact" "$out"

    # cfg_get_array with no-space format
    cat > "$nospace_cfg" <<'TOML'
[defaults]
writable_dirs=["/a", "/b"]
TOML
    out=$(cfg_get_array "defaults" "writable_dirs" "$nospace_cfg" | tr '\n' ',')
    assert_eq "cfg_get_array: no-space key=value" "/a,/b," "$out"
    rm -f "$nospace_cfg"

    # --- cfg_get_array_merged: no global config = project only ---
    cat > "$proj_cfg" <<'TOML'
[defaults]
writable_dirs = ["/proj/a", "/proj/b"]
TOML
    CONFIG_FILE="/nonexistent"
    PROJECT_CONFIG="$proj_cfg"
    out=$(cfg_get_array_merged "defaults" "writable_dirs" | tr '\n' ',')
    assert_eq "cfg_get_array_merged: project only when no global" "/proj/a,/proj/b," "$out"
)

# --- Structure tests ---
echo ""
echo "=== Structure tests ==="

# All expected functions exist
for fn in die require_image require_podman suggest_podman_install mount_home_items \
          cwd_needs_mount resolve_dirs has_local_build_files build_base_args \
          portable_realpath is_macos ensure_podman_machine parse_shared_flags \
          cmd_build cmd_run cmd_shell cmd_exec cmd_ps cmd_clean cmd_install \
          cfg_get cfg_get_array cfg_has_key cfg_get_merged cfg_get_array_merged load_project_config; do
    grep -q "^${fn}()" "$CP" && pass "function $fn defined" || fail "function $fn defined" "not found"
done

# All subcommands routed
for cmd in install build run shell exec ps clean; do
    grep -q "${cmd})" "$CP" && pass "subcommand $cmd routed" || fail "subcommand $cmd routed" "not found"
done

# Key variables
for var in VERSION IMAGE CONFIG_FILE PROJECT_CONFIG CONTAINER_NAME_PREFIX DATA_DIR HOST_OS; do
    grep -q "^${var}=" "$CP" && pass "variable $var defined" || fail "variable $var defined" "not found"
done

# --- Summary ---
echo ""
read -r PASS FAIL < "$RESULTS_FILE"
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
