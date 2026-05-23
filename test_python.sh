#!/bin/bash
# Test suite for the Python claude-pod rewrite.
# Verifies CLI behavior and dry-run fixture parity against the bash reference.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="python3 ${TEST_DIR}/claude-pod.py"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1 — $2"; }

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"
    else fail "$desc" "output does not contain '$needle'"; fi
}

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then pass "$desc"
    else fail "$desc" "expected '$expected', got '$actual'"; fi
}

normalize() {
    sed 's/claude-pod-[0-9]\{5,\}/claude-pod-TIMESTAMP/g'
}

# --- CLI tests ---
echo "=== Python CLI tests ==="

out=$($PY --version 2>&1)
assert_contains "--version shows version" "$out" "claude-pod"
assert_contains "--version has semver" "$out" "0."

out=$($PY -V 2>&1)
assert_contains "-V is alias for --version" "$out" "claude-pod"

out=$($PY --help 2>&1 || true)
assert_contains "--help shows usage" "$out" "claude-pod"
assert_contains "--help shows run" "$out" "run"
assert_contains "--help shows shell" "$out" "shell"
assert_contains "--help shows build" "$out" "build"
assert_contains "--help shows exec" "$out" "exec"
assert_contains "--help shows ps" "$out" "ps"
assert_contains "--help shows clean" "$out" "clean"
assert_contains "--help shows install" "$out" "install"

out=$($PY run --help 2>&1 || true)
assert_contains "run --help shows --dry-run" "$out" "--dry-run"
assert_contains "run --help shows --detach" "$out" "--detach"
assert_contains "run --help shows --gpu" "$out" "--gpu"
assert_contains "run --help shows --no-yolo" "$out" "--no-yolo"
assert_contains "run --help shows --max-memory" "$out" "--max-memory"
assert_contains "run --help shows --network" "$out" "--network"
assert_contains "run --help shows --port" "$out" "--port"
assert_contains "run --help shows --env" "$out" "--env"
assert_contains "run --help shows --writable-dir" "$out" "--writable-dir"
assert_contains "run --help shows --keep-groups" "$out" "--keep-groups"
assert_contains "run --help shows --notify" "$out" "--notify"
assert_contains "run --help shows --host-network" "$out" "--host-network"

out=$($PY shell --help 2>&1 || true)
assert_contains "shell --help shows --dry-run" "$out" "--dry-run"
assert_contains "shell --help shows --gpu" "$out" "--gpu"

# --- Unknown flag forwarding (run subcommand) ---
echo ""
echo "=== Unknown flag forwarding ==="

out=$($PY run --dry-run --model opus 2>&1 | normalize)
assert_contains "run forwards unknown --model flag" "$out" "--model opus"

# --- Dry-run fixture parity tests ---
echo ""
echo "=== Dry-run fixture parity ==="

declare -A FIXTURE_CMDS=(
    [run_default]="run --dry-run"
    [run_wd]="run --dry-run -wd /tmp/test"
    [run_env]="run --dry-run -e FOO=bar -e BAZ=qux"
    [run_gpu]="run --dry-run --gpu"
    [run_no_yolo]="run --dry-run --no-yolo"
    [run_max_memory]="run --dry-run --max-memory 4g"
    [run_network_host]="run --dry-run --network host"
    [run_host_network]="run --dry-run --host-network"
    [run_detach]="run --dry-run --detach"
    [run_keep_groups]="run --dry-run --keep-groups"
    [run_port]="run --dry-run -p 3000:3000"
    [run_combined]="run --dry-run -e FOO=bar --gpu --max-memory 4g --no-yolo"
    [shell_default]="shell --dry-run"
    [shell_wd]="shell --dry-run -wd /tmp/test"
    [shell_env]="shell --dry-run -e FOO=bar"
    [shell_gpu]="shell --dry-run --gpu"
    [shell_max_memory]="shell --dry-run --max-memory 4g"
    [shell_network_host]="shell --dry-run --network host"
)

for name in "${!FIXTURE_CMDS[@]}"; do
    fixture="$TEST_DIR/tests/fixtures/${name}.txt"
    if [[ ! -f "$fixture" ]]; then
        fail "fixture $name" "file not found: $fixture"
        continue
    fi
    expected=$(normalize < "$fixture" | sed 's/[[:space:]]*$//')
    actual=$($PY ${FIXTURE_CMDS[$name]} 2>&1 | normalize | sed 's/[[:space:]]*$//')
    assert_eq "fixture $name" "$expected" "$actual"
done

# --- pod.cache_source_dir override ---
echo ""
echo "=== pod.cache_source_dir override ==="

tmp_proj=$(mktemp -d)
tmp_cache=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '$tmp_proj' '$tmp_cache'" EXIT

cat > "$tmp_proj/.claude-pod.toml" <<EOF
[pod]
cache_source_dir = "$tmp_cache"
EOF

# Run from the temp project dir so the project config is picked up
cache_out=$(cd "$tmp_proj" && $PY run --dry-run 2>/dev/null)
assert_contains "cache_source_dir override appears in mount args" "$cache_out" "$tmp_cache"
# Container-side target must be the standard ~/.cache path
assert_contains "cache_source_dir mounts to container ~/.cache" "$cache_out" "${HOME}/.cache"
# Override path must not appear on the right-hand side of the volume spec
# (i.e. source and dest differ — source is tmp_cache, dest is ~/.cache)
cache_vol_spec="$tmp_cache:${HOME}/.cache"
assert_contains "cache_source_dir volume spec has correct src:dst" "$cache_out" "$cache_vol_spec"

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
