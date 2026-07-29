#!/system/bin/sh

SOURCE_ROOT="${1:-${0%/tests/*}}"
TEST_ROOT="${2:-${TMPDIR:-/tmp}/pixel9pro_runtime_defaults_$$}"
PASS=0
FAIL=0
CMD_CALLS=0
VALUE_WRITE_CALLS=0

ok() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$((PASS + FAIL))" "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'not ok %s - %s\n' "$((PASS + FAIL))" "$1"; }
check_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 (expected=$2 actual=$3)"; fi
}

mkdir -p "$TEST_ROOT" || exit 2
. "$SOURCE_ROOT/scripts/runtime_defaults_lib.sh" || exit 2

runtime_android_cmd() {
    CMD_CALLS=$((CMD_CALLS + 1))
    [ "${FAIL_COMMAND_CALL:-0}" != "$CMD_CALLS" ] || return 1
    printf '%s' "$3" > "$TEST_ROOT/modem_count"
}
runtime_write_value() {
    VALUE_WRITE_CALLS=$((VALUE_WRITE_CALLS + 1))
    [ "${FAIL_MARKER_WRITE:-0}" = "0" ] || return 1
    printf '%s' "$2" > "$1"
}

printf 'TAP version 13\n'
check_eq 'NR screen-off delay contract' 300 "$NR_SCREEN_OFF_DELAY_S"
check_eq 'NR restore cooldown contract' 600 "$NR_RESTORE_COOLDOWN_S"
check_eq 'NR LTE mode contract' 9 "$NR_LTE_MODE"
check_eq 'owner screen-on poll contract' 5 "$OWNER_ARBITER_DEFAULT_SCREEN_ON_POLL_S"
check_eq 'owner screen-off poll contract' 15 "$OWNER_ARBITER_DEFAULT_SCREEN_OFF_POLL_S"
check_eq 'owner long-pause poll contract' 30 "$OWNER_ARBITER_DEFAULT_PAUSE_POLL_S"
check_eq 'unified worker screen-wake recheck contract' 30 "$UNIFIED_SCREEN_WAKE_RECHECK_S"
value_file="$TEST_ROOT/value_marker"
printf 'stable' > "$value_file"
VALUE_WRITE_CALLS=0
runtime_write_value_if_changed "$value_file" stable
check_eq 'unchanged runtime value skips the write path' 0 "$VALUE_WRITE_CALLS"
runtime_write_value_if_changed "$value_file" changed
check_eq 'changed runtime value writes exactly once' 1 "$VALUE_WRITE_CALLS"
check_eq 'changed runtime value is committed' changed "$(cat "$value_file")"
marker="$TEST_ROOT/sim_marker"
if runtime_set_sim_count_state "$marker" 1 disabled 2; then ok 'SIM transaction applies'; else not_ok 'SIM transaction applies'; fi
check_eq 'SIM transaction commits marker' disabled "$(cat "$marker")"
check_eq 'SIM transaction commits modem count' 1 "$(cat "$TEST_ROOT/modem_count")"
check_eq 'SIM transaction reports applied' applied "$SIM2_TRANSACTION_RESULT"

CMD_CALLS=0
FAIL_MARKER_WRITE=1
FAIL_COMMAND_CALL=0
if runtime_set_sim_count_state "$marker" 1 disabled 2; then not_ok 'marker failure rejects transaction'; else ok 'marker failure rejects transaction'; fi
check_eq 'marker failure rolls modem count back' 2 "$(cat "$TEST_ROOT/modem_count")"
check_eq 'marker failure reports complete rollback' state_failed_rolled_back "$SIM2_TRANSACTION_RESULT"

CMD_CALLS=0
FAIL_COMMAND_CALL=2
runtime_set_sim_count_state "$marker" 1 disabled 2
check_eq 'rollback command failure returns distinct status' 2 "$?"
check_eq 'rollback command failure is explicit' state_failed_rollback_incomplete "$SIM2_TRANSACTION_RESULT"

printf '1..%s\n' "$((PASS + FAIL))"
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
