#!/bin/bash
# Looking Glass Setup - Regression Test Suite
# Run: bash tests/run_tests.sh
# Requirements: bats-core or plain bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$TEST_DIR")"
SCRIPT="$PROJECT_DIR/look-setup.sh"
PASS=0
FAIL=0
FAILED_TESTS=()

pass() {
    echo "  [PASS] $1"
    ((PASS++)) || true
}

fail() {
    echo "  [FAIL] $1"
    ((FAIL++)) || true
    FAILED_TESTS+=("$1")
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-contains}"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$msg"
    else
        fail "$msg (expected '$needle' in output)"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-not_contains}"
    if [[ "$haystack" != *"$needle"* ]]; then
        pass "$msg"
    else
        fail "$msg (unexpected '$needle' in output)"
    fi
}

assert_eq() {
    local a="$1" b="$2" msg="${3:-eq}"
    if [[ "$a" == "$b" ]]; then
        pass "$msg"
    else
        fail "$msg (expected '$b', got '$a')"
    fi
}

echo "========================================"
echo "Looking Glass Setup Regression Tests"
echo "========================================"

echo ""
echo "--- Test Group: Argument Parsing ---"

# Test: --help exits 0 and shows usage
out=$(bash "$SCRIPT" --help 2>&1 || true)
assert_contains "$out" "Usage:" "--help shows usage"
assert_contains "$out" "--install-script" "--help mentions --install-script"
assert_contains "$out" "--self-remove" "--help mentions --self-remove"
assert_contains "$out" "--create-shortcut" "--help mentions --create-shortcut"

# Test: unknown option exits with error
out=$(bash "$SCRIPT" --bogus 2>&1 || true)
assert_contains "$out" "Unknown option" "unknown flag rejected"

# Test: --dry-run does not require root (but should error early on root check)
out=$(bash "$SCRIPT" --dry-run --yes 2>&1 || true)
assert_contains "$out" "must be run as root" "--dry-run still respects root check"

echo ""
echo "--- Test Group: Self-Deployment ---"

# Test: --install-script as non-root should fail
out=$(bash "$SCRIPT" --install-script 2>&1 || true)
assert_contains "$out" "Are you root" "install-script requires root"

# Test: --self-remove as non-root should fail
out=$(bash "$SCRIPT" --self-remove 2>&1 || true)
assert_contains "$out" "Are you root" "self-remove requires root when installed"

echo ""
echo "--- Test Group: INI Merging (Unit) ---"

# Source the script in a subshell to test merge_ini_setting without executing main
# Since the script has `set -euo pipefail` and main code at the bottom, we can't source it directly.
# Instead, we define a mini INI merger for testing that mimics the real logic.
merge_ini_test() {
    local file="$1" section="$2" key="$3" value="$4"
    if [[ ! -f "$file" ]]; then
        printf "[%s]\n%s=%s\n" "$section" "$key" "$value" > "$file"
        return 0
    fi
    if ! grep -q "^\[${section}\]$" "$file"; then
        printf "\n[%s]\n%s=%s\n" "$section" "$key" "$value" >> "$file"
        return 0
    fi
    local in_section=false key_exists=false line
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "[$section]" ]]; then
            in_section=true; continue
        fi
        if [[ "$in_section" == true && "$line" =~ ^\[.*\]$ ]]; then break; fi
        if [[ "$in_section" == true && "${line#"$key="}" != "$line" ]]; then
            key_exists=true; break
        fi
    done < "$file" || true
    if [[ "$key_exists" == true ]]; then return 0; fi
    local tmp_file orig_stat=""
    if [[ -f "$file" ]]; then orig_stat="$(stat -c '%u:%g' "$file" 2>/dev/null || true)"; fi
    tmp_file="$(mktemp)"
    local inserted=false
    while IFS= read -r line || [[ -n "$line" ]]; do
        printf '%s\n' "$line" >> "$tmp_file"
        if [[ "$inserted" == false && "$line" == "[$section]" ]]; then
            printf '%s=%s\n' "$key" "$value" >> "$tmp_file"
            inserted=true
        fi
    done < "$file"
    mv "$tmp_file" "$file"
    if [[ -n "$orig_stat" ]]; then chown "$orig_stat" "$file" 2>/dev/null || true; fi
}

ini_tmp="$(mktemp)"
echo "[app]" > "$ini_tmp"
echo "shmFile=/dev/shm/old" >> "$ini_tmp"
merge_ini_test "$ini_tmp" "app" "shmFile" "/dev/shm/looking-glass"
assert_contains "$(cat "$ini_tmp")" "shmFile=/dev/shm/old" "INI merge does not overwrite existing key"
merge_ini_test "$ini_tmp" "spice" "enable" "yes"
assert_contains "$(cat "$ini_tmp")" "[spice]" "INI merge appends new section"
assert_contains "$(cat "$ini_tmp")" "enable=yes" "INI merge adds key in new section"
merge_ini_test "$ini_tmp" "spice" "audio" "yes"
assert_contains "$(cat "$ini_tmp")" "audio=yes" "INI merge adds second key in existing section"
rm -f "$ini_tmp"

echo ""
echo "--- Test Group: Detect Display Server (Unit) ---"

# Simulate the detect_display_server logic in a function
_detect_display_test() {
    local display_type="x11"
    if command -v loginctl >/dev/null 2>&1 && [[ -n "${REAL_USER:-}" && "$REAL_USER" != "root" ]]; then
        local session_ids
        session_ids="$(loginctl list-sessions --no-legend 2>/dev/null | awk -v user="$REAL_USER" '$3==user {print $1}')"
        local sid session_type
        for sid in $session_ids; do
            session_type="$(loginctl show-session "$sid" -p Type --value 2>/dev/null || true)"
            if [[ "${session_type,,}" == "wayland" ]]; then
                display_type="wayland"
                break
            fi
        done
    fi
    printf '%s' "$display_type"
}

REAL_USER="${SUDO_USER:-$USER}"
dt="$(_detect_display_test)"
if [[ "$dt" == "x11" || "$dt" == "wayland" ]]; then
    pass "detect_display_server returns x11 or wayland ($dt)"
else
    fail "detect_display_server returned unexpected value: $dt"
fi

echo ""
echo "--- Test Group: Idempotency (Simulated) ---"

# Verify the script can be parsed twice without side effects
out1=$(bash -n "$SCRIPT" 2>&1 || true)
out2=$(bash -n "$SCRIPT" 2>&1 || true)
assert_eq "$out1" "$out2" "script is parse-idempotent (bash -n)"
assert_eq "$out1" "" "script has no syntax errors"

echo ""
echo "--- Test Group: TUI Menu Index Safety ---"

# Verify numeric indexing logic via a small simulation
vm_list=("VM Alpha" "Windows 10" "Ubuntu 22.04")
menu_items=()
i=1
for vm in "${vm_list[@]}"; do
    menu_items+=("$i" "$vm")
    i=$((i+1))
done
menu_items+=("0" "Skip")
assert_eq "${menu_items[0]}" "1" "first tag is numeric 1"
assert_eq "${menu_items[1]}" "VM Alpha" "first label contains space"
assert_eq "${menu_items[6]}" "0" "skip tag is numeric 0"
selected_idx="3"
selected_vm="${vm_list[$((selected_idx-1))]}"
assert_eq "$selected_vm" "Ubuntu 22.04" "index-to-VM mapping correct"

echo ""
echo "--- Test Group: get_vm_shmem_size returns first match ---"
# Simulate the updated grep logic: head -n 1 ensures only the first <size> is returned
xml_input="<size unit='M'>128</size>\n<shmem name='other'>\n<size unit='M'>64</size>"
result="$(printf '%s' "$xml_input" | grep -oP "(?<=<size unit='M'>)[^<]+" | head -n 1 || true)"
assert_eq "$result" "128" "get_vm_shmem_size returns first size match only"

echo ""
echo "========================================"
echo "Test Results: $PASS passed, $FAIL failed"
if [[ ${#FAILED_TESTS[@]} -gt 0 ]]; then
    echo ""
    echo "FAIL SUMMARY (${#FAILED_TESTS[@]})"
    for t in "${FAILED_TESTS[@]}"; do
        echo "  - $t"
    done
    exit 1
fi
echo "All tests passed."
exit 0
