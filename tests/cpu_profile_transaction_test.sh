#!/system/bin/sh

SOURCE_ROOT="${1:-/sdcard/Download/Pixel9Pro-Control-TestLab/candidate/control}"
TEST_ROOT="${2:-/sdcard/Download/Pixel9Pro-Control-TestLab/runtime/cpu_profile_transaction_$$}"
PASS=0
FAIL=0
TOTAL=0

ok() { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$TOTAL" "$1"; }
not_ok() { TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); printf 'not ok %s - %s\n' "$TOTAL" "$1"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 expected=$2 actual=$3"; fi; }

MOD="$TEST_ROOT/mod"
CPU0="$TEST_ROOT/cpu0"
CPU4="$TEST_ROOT/cpu4"
CPU7="$TEST_ROOT/cpu7"
CPUSET="$TEST_ROOT/cpuset"
VENDOR="$TEST_ROOT/vendor_sched"
CAP="$TEST_ROOT/uclamp_cap"
MOCK_BIN="$TEST_ROOT/bin"
mkdir -p "$MOD/scripts" "$CPU0/sched_pixel" "$CPU4/sched_pixel" "$CPU7/sched_pixel" \
    "$CPUSET/top-app" "$CPUSET/foreground" "$CPUSET/background" "$CPUSET/system-background" "$VENDOR" || exit 2
mkdir -p "$MOCK_BIN" || exit 2
cat > "$MOCK_BIN/log" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$MOCK_BIN" || exit 2
cp "$SOURCE_ROOT/scripts/cpu_profile.sh" "$MOD/scripts/" || exit 2
cp "$SOURCE_ROOT/scripts/cpu_profile_lib.sh" "$MOD/scripts/" || exit 2
printf 'pixel\n' > "$MOD/.cpu_sched_owner"
printf 'battery\n' > "$MOD/.current_profile"
for _t_root in "$CPU0" "$CPU4" "$CPU7"; do
    printf '9\n' > "$_t_root/sched_pixel/response_time_ms"
    printf '9\n' > "$_t_root/sched_pixel/response_time_ms_nom"
done
printf '0-7\n' > "$CPUSET/top-app/cpus"
printf '0-6\n' > "$CPUSET/foreground/cpus"
printf '0-3\n' > "$CPUSET/background/cpus"
printf '0-3\n' > "$CPUSET/system-background/cpus"
printf '1024\n' > "$VENDOR/ug_bg_uclamp_max"
printf '308\n' > "$VENDOR/ug_bg_group_throttle"
printf '1024\n' > "$CAP"

run_profile() {
    CPU_PROFILE_TEST_MODE=1 \
    CPU_PROFILE_CPU0_ROOT="$CPU0" CPU_PROFILE_CPU4_ROOT="$CPU4" CPU_PROFILE_CPU7_ROOT="$CPU7" \
    CPU_PROFILE_CPUSET_ROOT="$CPUSET" CPU_PROFILE_VENDOR_SCHED_ROOT="$VENDOR" \
    CPU_PROFILE_UCLAMP_PATH="$CAP" \
    CPU_PROFILE_FAIL_ONCE_PATH="${CPU_PROFILE_FAIL_ONCE_PATH:-}" \
    CPU_PROFILE_FAIL_ONCE_MARKER="${CPU_PROFILE_FAIL_ONCE_MARKER:-}" \
    PATH="$MOCK_BIN:$PATH" sh "$MOD/scripts/cpu_profile.sh" "$1" "$MOD" "${2:-}" 2>/dev/null
}

runtime_signature() {
    for _t_file in \
        "$CPU0/sched_pixel/response_time_ms" "$CPU4/sched_pixel/response_time_ms" "$CPU7/sched_pixel/response_time_ms" \
        "$CAP" "$CPUSET/top-app/cpus" "$CPUSET/foreground/cpus" "$CPUSET/background/cpus" "$CPUSET/system-background/cpus" \
        "$VENDOR/ug_bg_uclamp_max" "$VENDOR/ug_bg_group_throttle"; do
        tr -d ' \r\n\t' < "$_t_file"
        printf '|'
    done
}

printf 'TAP version 13\n'
if run_profile battery; then ok 'battery transaction applies'; else not_ok 'battery transaction applies'; fi
assert_eq 'battery response contract' '32/96/200' "$(cat "$CPU0/sched_pixel/response_time_ms")/$(cat "$CPU4/sched_pixel/response_time_ms")/$(cat "$CPU7/sched_pixel/response_time_ms")"
assert_eq 'battery L2 follows current profile' '150/80' "$(cat "$VENDOR/ug_bg_uclamp_max")/$(cat "$VENDOR/ug_bg_group_throttle")"
assert_eq 'battery cap' 0 "$(cat "$CAP")"

printf 'balanced\n' > "$MOD/.power_profile"
if run_profile verify; then ok 'verify is read-only and ignores legacy power profile'; else not_ok 'verify is read-only and ignores legacy power profile'; fi

printf 'balanced\n' > "$MOD/.current_profile"
if run_profile balanced; then ok 'balanced transaction applies'; else not_ok 'balanced transaction applies'; fi
_t_before=$(runtime_signature)
printf 'battery\n' > "$MOD/.current_profile"
FAIL_MARKER="$TEST_ROOT/fail_once"
printf '1\n' > "$FAIL_MARKER"
CPU_PROFILE_FAIL_ONCE_PATH="$VENDOR/ug_bg_group_throttle"
CPU_PROFILE_FAIL_ONCE_MARKER="$FAIL_MARKER"
export CPU_PROFILE_FAIL_ONCE_PATH CPU_PROFILE_FAIL_ONCE_MARKER
run_profile battery >/dev/null 2>&1
_t_rc=$?
unset CPU_PROFILE_FAIL_ONCE_PATH CPU_PROFILE_FAIL_ONCE_MARKER
assert_eq 'partial L2 failure reports rolled back transaction' 3 "$_t_rc"
assert_eq 'partial L2 failure restores full runtime snapshot' "$_t_before" "$(runtime_signature)"

printf '1..%s\n' "$TOTAL"
printf '# pass=%s fail=%s root=%s\n' "$PASS" "$FAIL" "$TEST_ROOT"
[ "$FAIL" -eq 0 ]
