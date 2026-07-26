#!/system/bin/sh

SOURCE_ROOT="${1:-/sdcard/Download/Pixel9Pro-Control-TestLab/candidate/control}"
TEST_ROOT="${2:-/sdcard/Download/Pixel9Pro-Control-TestLab/runtime/scheduler_detect_test_$$}"
PASS=0
FAIL=0
TOTAL=0

ok() { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$TOTAL" "$1"; }
not_ok() { TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); printf 'not ok %s - %s\n' "$TOTAL" "$1"; }

assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 expected=$2 actual=$3"; fi
}

new_case() {
    CASE_ROOT="$TEST_ROOT/$1"
    SCHEDULER_MODULES_ROOT="$CASE_ROOT/modules"
    SCHEDULER_MODULES_UPDATE_ROOT="$CASE_ROOT/modules_update"
    SCHEDULER_FAS_RUNTIME_ROOT="$CASE_ROOT/fas_runtime"
    SCHEDULER_FAS_MODE_PATH="$CASE_ROOT/dev_fas_mode"
    SCHEDULER_TEST_RUNTIME_ROOT="$CASE_ROOT/processes"
    SCHEDULER_TEST_MODE=1
    mkdir -p "$SCHEDULER_MODULES_ROOT" "$SCHEDULER_MODULES_UPDATE_ROOT" \
        "$SCHEDULER_FAS_RUNTIME_ROOT" "$SCHEDULER_TEST_RUNTIME_ROOT" || exit 2
}

write_module() {
    _t_dir="$SCHEDULER_MODULES_ROOT/$1"
    mkdir -p "$_t_dir" || exit 2
    printf 'id=%s\nname=%s\nversion=1.0\n' "$2" "$3" > "$_t_dir/module.prop"
}

mkdir -p "$TEST_ROOT" || exit 2
. "$SOURCE_ROOT/scripts/scheduler_detect_lib.sh"
printf 'TAP version 13\n'

new_case runtime_only
printf 'fas-rs:game:com.example.game\n' > "$SCHEDULER_FAS_RUNTIME_ROOT/.owner_state"
if detect_fas_rs_scheduler; then _t_detected=yes; else _t_detected=no; fi
assert_eq 'runtime directory alone does not expose fas-rs' no "$_t_detected"
assert_eq 'runtime directory leaves fas-rs detected false' no "$FAS_RS_DETECTED"

new_case fas_module
write_module fas_rs fas_rs 'fas-rs'
detect_fas_rs_scheduler
assert_eq 'fas-rs module is detected' yes "$FAS_RS_DETECTED"
assert_eq 'enabled fas-rs module is enabled' yes "$FAS_RS_MODULE_ENABLED"

new_case fas_disabled
write_module fas_rs fas_rs 'fas-rs'
printf '1\n' > "$SCHEDULER_MODULES_ROOT/fas_rs/disable"
detect_fas_rs_scheduler
assert_eq 'disabled fas-rs module is still detected' yes "$FAS_RS_DETECTED"
assert_eq 'disabled fas-rs module is not enabled' no "$FAS_RS_MODULE_ENABLED"

new_case ugt_only
write_module uperf uperf 'Uperf Game Turbo'
detect_external_scheduler
assert_eq 'UGT-only fixture detects UGT' yes "$UPERF_DETECTED"
assert_eq 'UGT-only fixture does not detect fas-rs' no "$FAS_RS_DETECTED"
assert_eq 'UGT-only external kind is uperf' uperf "$EXTERNAL_SCHEDULER_KIND"

new_case both_modules
write_module uperf uperf 'Uperf Game Turbo'
write_module fas_rs fas_rs 'fas-rs'
detect_external_scheduler
assert_eq 'combined fixture detects UGT' yes "$UPERF_DETECTED"
assert_eq 'combined fixture detects fas-rs' yes "$FAS_RS_DETECTED"

new_case live_fas
printf '1\n' > "$SCHEDULER_TEST_RUNTIME_ROOT/fas-rs_alive"
printf 'balance\n' > "$SCHEDULER_FAS_MODE_PATH"
detect_fas_rs_scheduler
assert_eq 'live fas-rs process exposes runtime UI' yes "$FAS_RS_DETECTED"
assert_eq 'live fas-rs process is active' yes "$FAS_RS_ACTIVE"

printf '1..%s\n' "$TOTAL"
printf '# pass=%s fail=%s root=%s\n' "$PASS" "$FAIL" "$TEST_ROOT"
[ "$FAIL" -eq 0 ]
