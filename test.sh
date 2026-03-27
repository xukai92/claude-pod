#!/bin/bash
# Test suite for claude-pod. Runs without podman — tests script structure,
# helper functions, and CLI behavior.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CP="$TEST_DIR/claude-pod"
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

# --- Structure tests ---
echo ""
echo "=== Structure tests ==="

# All expected functions exist
for fn in die require_image require_podman suggest_podman_install mount_home_items \
          cwd_needs_mount resolve_dirs has_local_build_files build_base_args \
          portable_realpath is_macos ensure_podman_machine parse_shared_flags \
          cmd_build cmd_run cmd_shell cmd_exec cmd_ps cmd_clean cmd_install \
          cfg_get cfg_get_array; do
    grep -q "^${fn}()" "$CP" && pass "function $fn defined" || fail "function $fn defined" "not found"
done

# All subcommands routed
for cmd in install build run shell exec ps clean; do
    grep -q "${cmd})" "$CP" && pass "subcommand $cmd routed" || fail "subcommand $cmd routed" "not found"
done

# Key variables
for var in VERSION IMAGE CONFIG_FILE CONTAINER_NAME_PREFIX DATA_DIR HOST_OS; do
    grep -q "^${var}=" "$CP" && pass "variable $var defined" || fail "variable $var defined" "not found"
done

# --- Summary ---
echo ""
read -r PASS FAIL < "$RESULTS_FILE"
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
