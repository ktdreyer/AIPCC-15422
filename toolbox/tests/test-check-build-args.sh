#!/bin/bash
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/check-build-args.sh"
FIXTURES="$(cd "$(dirname "$0")" && pwd)/fixtures/check-build-args"

pass=0
fail=0

run_test() {
    local name="$1"
    local expected_exit="$2"
    shift 2
    local actual_exit=0
    "$@" > /dev/null 2>&1 || actual_exit=$?
    if [ "$actual_exit" -eq "$expected_exit" ]; then
        echo "PASS: $name"
        pass=$((pass + 1))
    else
        echo "FAIL: $name (expected exit $expected_exit, got $actual_exit)"
        fail=$((fail + 1))
    fi
}

# --- Basic argument handling ---
run_test "no arguments" \
    1  "$SCRIPT"
run_test "file not found" \
    0  "$SCRIPT" /nonexistent/file.conf
run_test "empty file" \
    0  "$SCRIPT" "$FIXTURES/empty.conf"

# --- GA builds: no VERSION_KEY ---
run_test "GA rhaiis (no version key)" \
    0  "$SCRIPT" "$FIXTURES/ga-rhaiis.conf"
run_test "GA bootc (no version key)" \
    0  "$SCRIPT" "$FIXTURES/ga-bootc.conf"

# --- EA/fast detection without VERSION_KEY (always checks) ---
run_test "EA image refs detected (no version key)" \
    1  "$SCRIPT" "$FIXTURES/ea-rhaiis.conf"
run_test "fast image refs detected (no version key)" \
    1  "$SCRIPT" "$FIXTURES/fast-rhaiis.conf"

# --- VERSION_KEY: EA/fast builds skip the check ---
run_test "EA build with EA refs (RHAIIS_VERSION)" \
    0  env VERSION_KEY=RHAIIS_VERSION "$SCRIPT" "$FIXTURES/ea-rhaiis.conf"
run_test "EA build with EA refs (RHELAI_VERSION_ID)" \
    0  env VERSION_KEY=RHELAI_VERSION_ID "$SCRIPT" "$FIXTURES/ea-bootc.conf"
run_test "fast build with fast refs (RHAIIS_VERSION)" \
    0  env VERSION_KEY=RHAIIS_VERSION "$SCRIPT" "$FIXTURES/fast-rhaiis.conf"

# --- VERSION_KEY: GA builds still catch EA/fast refs ---
run_test "EA image on GA version (RHAIIS_VERSION)" \
    1  env VERSION_KEY=RHAIIS_VERSION "$SCRIPT" "$FIXTURES/ea-image-ga-version.conf"
run_test "fast image on GA version (RHAIIS_VERSION)" \
    1  env VERSION_KEY=RHAIIS_VERSION "$SCRIPT" "$FIXTURES/fast-image-ga-version.conf"

# --- False positive: version ID with -EA but no dot ---
run_test "version ID 3.5-EA1 (no dot, no version key)" \
    0  "$SCRIPT" "$FIXTURES/version-id-ea-no-dot.conf"

# --- Multiple files ---
run_test "multiple GA files" \
    0  "$SCRIPT" "$FIXTURES/ga-rhaiis.conf" "$FIXTURES/ga-bootc.conf"
run_test "multiple files, one has EA image on GA version" \
    1  env VERSION_KEY=RHAIIS_VERSION "$SCRIPT" "$FIXTURES/ga-rhaiis.conf" "$FIXTURES/ea-image-ga-version.conf"
run_test "mixed: GA file + EA file with version key" \
    0  env VERSION_KEY=RHAIIS_VERSION "$SCRIPT" "$FIXTURES/ga-rhaiis.conf" "$FIXTURES/ea-rhaiis.conf"

# --- VERSION_KEY set but not present in file (skipped) ---
run_test "version key missing from file (skipped)" \
    0  env VERSION_KEY=RHELAI_VERSION_ID "$SCRIPT" "$FIXTURES/no-version-key.conf"

echo
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
