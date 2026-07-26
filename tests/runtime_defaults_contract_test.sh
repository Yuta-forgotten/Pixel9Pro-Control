#!/system/bin/sh

SOURCE_ROOT="${1:-${0%/tests/*}}"
TEST_ROOT="${2:-${TMPDIR:-/tmp}/pixel9pro_runtime_defaults_$$}"
PASS=0
FAIL=0
CMD_CALLS=0

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
    [ "${FAIL_MARKER_WRITE:-0}" = "0" ] || return 1
    printf '%s' "$2" > "$1"
}

printf 'TAP version 13\n'
check_eq 'NR screen-off delay contract' 300 "$NR_SCREEN_OFF_DELAY_S"
check_eq 'NR restore cooldown contract' 600 "$NR_RESTORE_COOLDOWN_S"
check_eq 'NR LTE mode contract' 9 "$NR_LTE_MODE"
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
