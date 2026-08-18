#!/system/bin/sh

SOURCE_ROOT="${1:-${0%/tests/*}}"
TEST_ROOT="${2:-${TMPDIR:-/tmp}/pixel9pro_uecap_state_$$}"
PASS=0
FAIL=0

check_eq() {
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
        printf 'ok %s - %s\n' "$((PASS + FAIL))" "$1"
    else
        FAIL=$((FAIL + 1))
        printf 'not ok %s - %s (expected=%s actual=%s)\n' "$((PASS + FAIL))" "$1" "$2" "$3"
    fi
}

mkdir -p "$TEST_ROOT" || exit 2
export PIXEL9PRO_MODDIR="$TEST_ROOT"
export PIXEL9PRO_UECAP_MODE_FILE="$TEST_ROOT/mode"
export PIXEL9PRO_UECAP_MANUAL_MODE_FILE="$TEST_ROOT/manual"
export PIXEL9PRO_UECAP_POLICY_FILE="$TEST_ROOT/policy"
export PIXEL9PRO_UECAP_REASON_FILE="$TEST_ROOT/reason"
export PIXEL9PRO_UECAP_SWITCH_FILE="$TEST_ROOT/switch"
export PIXEL9PRO_UECAP_RECEIPT_FILE="$TEST_ROOT/runtime_receipt"
export PIXEL9PRO_UECAP_LOGDIR="$TEST_ROOT/logs"
export PIXEL9PRO_UECAP_TEST_MODE=1
export PIXEL9PRO_UECAP_BOOT_ID=test-boot
. "$SOURCE_ROOT/uecap_profile.sh"

check_eq 'UECap contract owns mode order' 'balanced special universal' "$UECAP_MODE_ORDER"
check_eq 'UECap contract owns default mode' balanced "$UECAP_DEFAULT_MODE"
check_eq 'UECap CLI exposes mode order for installer consumers' 'balanced special universal' "$(sh "$SOURCE_ROOT/uecap_profile.sh" modes)"
check_eq 'UECap CLI exposes default for installer consumers' balanced "$(sh "$SOURCE_ROOT/uecap_profile.sh" default)"
if sh "$SOURCE_ROOT/uecap_profile.sh" unknown >/dev/null 2>&1; then
    FAIL=$((FAIL + 1))
    printf 'not ok %s - UECap CLI rejects unknown commands\n' "$((PASS + FAIL))"
else
    PASS=$((PASS + 1))
    printf 'ok %s - UECap CLI rejects unknown commands\n' "$((PASS + FAIL))"
fi
check_eq 'UECap UI contract serializes modes and default' \
    '{"mode_order":["balanced","special","universal"],"default_mode":"balanced"}' \
    "$(uecap_print_ui_contract_json)"
if uecap_is_valid_mode special && ! uecap_is_valid_mode invalid; then
    PASS=$((PASS + 1))
    printf 'ok %s - UECap mode validator consumes contract order\n' "$((PASS + FAIL))"
else
    FAIL=$((FAIL + 1))
    printf 'not ok %s - UECap mode validator consumes contract order\n' "$((PASS + FAIL))"
fi

PIXEL9PRO_UECAP_RESTART_MODEM_RESULT=success
uecap_reload_modem pre_modem
check_eq 'pre-modem UECap path does not dispatch a late reload' false "$UECAP_RELOAD_DISPATCHED"
check_eq 'pre-modem UECap path records the explicit no-reload reason' not_required_pre_modem "$UECAP_RELOAD_RESULT"
uecap_reload_modem boot_manual
check_eq 'boot UECap path dispatches modem reload' true "$UECAP_RELOAD_DISPATCHED"
check_eq 'boot modem reload records success' success "$UECAP_RELOAD_RESULT"
PIXEL9PRO_UECAP_RESTART_MODEM_RESULT=fail
uecap_reload_modem boot_manual
check_eq 'boot modem reload failure is explicit' failed "$UECAP_RELOAD_RESULT"
PIXEL9PRO_UECAP_RESTART_MODEM_RESULT=success

_uecap_source_guard="$TEST_ROOT/source_guard"
mkdir -p "$_uecap_source_guard" || exit 2
if (
    export PIXEL9PRO_MODDIR="$_uecap_source_guard"
    export PIXEL9PRO_UECAP_MODE_FILE="$_uecap_source_guard/mode"
    set -- apply special
    . "$SOURCE_ROOT/uecap_profile.sh"
    [ ! -e "$_uecap_source_guard/mode" ]
); then
    PASS=$((PASS + 1))
    printf 'ok %s - sourcing UECap library never runs CLI mutation\n' "$((PASS + FAIL))"
else
    FAIL=$((FAIL + 1))
    printf 'not ok %s - sourcing UECap library never runs CLI mutation\n' "$((PASS + FAIL))"
fi

printf 'balanced' > "$UECAP_MODE_FILE"
printf 'balanced' > "$UECAP_MANUAL_MODE_FILE"
printf 'manual' > "$UECAP_POLICY_FILE"
printf 'old_reason' > "$UECAP_REASON_FILE"
printf '100' > "$UECAP_SWITCH_FILE"

uecap_commit_state special manual_locked 200
check_eq 'transaction commits active mode' special "$(cat "$UECAP_MODE_FILE")"
check_eq 'transaction commits manual mode' special "$(cat "$UECAP_MANUAL_MODE_FILE")"
check_eq 'transaction keeps manual policy' manual "$(cat "$UECAP_POLICY_FILE")"
check_eq 'transaction commits reason' manual_locked "$(cat "$UECAP_REASON_FILE")"
check_eq 'transaction commits switch time' 200 "$(cat "$UECAP_SWITCH_FILE")"

printf 'balanced' > "$UECAP_MODE_FILE"
printf 'balanced' > "$UECAP_MANUAL_MODE_FILE"
printf 'old_reason' > "$UECAP_REASON_FILE"
printf '100' > "$UECAP_SWITCH_FILE"
rm -f "$UECAP_POLICY_FILE"
mkdir "$UECAP_POLICY_FILE" || exit 2

if uecap_commit_state universal manual_locked 300; then
    FAIL=$((FAIL + 1))
    printf 'not ok %s - transaction rejects a partial state commit\n' "$((PASS + FAIL))"
else
    PASS=$((PASS + 1))
    printf 'ok %s - transaction rejects a partial state commit\n' "$((PASS + FAIL))"
fi
check_eq 'failed transaction restores active mode' balanced "$(cat "$UECAP_MODE_FILE")"
check_eq 'failed transaction restores manual mode' balanced "$(cat "$UECAP_MANUAL_MODE_FILE")"
check_eq 'failed transaction preserves reason' old_reason "$(cat "$UECAP_REASON_FILE")"
check_eq 'failed transaction preserves switch time' 100 "$(cat "$UECAP_SWITCH_FILE")"
check_eq 'failed transaction reports incomplete state rollback' incomplete "$UECAP_STATE_ROLLBACK_RESULT"

rmdir "$UECAP_POLICY_FILE" || exit 2
printf 'manual' > "$UECAP_POLICY_FILE"
export PIXEL9PRO_UECAP_TARGET="$TEST_ROOT/target.binarypb"
export PIXEL9PRO_UECAP_SPECIAL="$TEST_ROOT/special.binarypb"
export PIXEL9PRO_UECAP_BALANCED="$TEST_ROOT/balanced.binarypb"
export PIXEL9PRO_UECAP_UNIVERSAL="$TEST_ROOT/universal.binarypb"
UECAP_TARGET="$PIXEL9PRO_UECAP_TARGET"
UECAP_SPECIAL="$PIXEL9PRO_UECAP_SPECIAL"
UECAP_BALANCED="$PIXEL9PRO_UECAP_BALANCED"
UECAP_UNIVERSAL="$PIXEL9PRO_UECAP_UNIVERSAL"
printf 'special-payload' > "$UECAP_SPECIAL"
printf 'balanced-payload' > "$UECAP_BALANCED"
printf 'universal-payload' > "$UECAP_UNIVERSAL"
printf 'balanced-payload' > "$UECAP_TARGET"
printf 'balanced' > "$UECAP_MODE_FILE"
printf 'balanced' > "$UECAP_MANUAL_MODE_FILE"
MOUNTED=1
FAIL_SPECIAL_BIND=1
FAIL_ALL_BINDS=0
RELOAD_FAIL=0

uecap_target_is_mounted() { [ "$MOUNTED" -eq 1 ]; }
uecap_unmount() { MOUNTED=0; printf 'stock-payload' > "$UECAP_TARGET"; }
uecap_mount_bind() {
    [ "$FAIL_ALL_BINDS" -eq 0 ] || return 1
    if [ "$FAIL_SPECIAL_BIND" -eq 1 ] && [ "$1" = "$UECAP_SPECIAL" ]; then return 1; fi
    cp "$1" "$2" || return 1
    MOUNTED=1
}
uecap_reload_modem() {
    [ "$RELOAD_FAIL" -eq 0 ] || { UECAP_RELOAD_DISPATCHED=false; UECAP_RELOAD_RESULT=failed; return 1; }
    UECAP_RELOAD_RESULT=success
    UECAP_RELOAD_DISPATCHED=true
}

uecap_apply_mode special manual_locked
check_eq 'bind failure returns rolled-back status' 1 "$?"
check_eq 'bind failure result is explicit' bind_failed_rolled_back "$UECAP_APPLY_RESULT"
check_eq 'bind failure restores previous payload' "$(uecap_hash "$UECAP_BALANCED")" "$(uecap_hash "$UECAP_TARGET")"

FAIL_SPECIAL_BIND=0
FAIL_ALL_BINDS=1
uecap_apply_mode special manual_locked
check_eq 'bind rollback failure returns distinct status' 2 "$?"
check_eq 'bind rollback failure is explicit' bind_failed_rollback_incomplete "$UECAP_APPLY_RESULT"

FAIL_ALL_BINDS=0
MOUNTED=1
printf 'balanced-payload' > "$UECAP_TARGET"
RELOAD_FAIL=1
uecap_apply_mode special manual_locked
check_eq 'modem reload failure returns applied status' 3 "$?"
check_eq 'modem reload failure keeps applied mode' special "$(cat "$UECAP_MODE_FILE")"
check_eq 'modem reload failure is explicit' applied_reload_failed "$UECAP_APPLY_RESULT"
check_eq 'runtime receipt records reload failure' applied_reload_failed "$(uecap_receipt_get apply_result)"
check_eq 'runtime receipt never claims modem effective after reload failure' unverified "$(uecap_receipt_get effective_state)"
check_eq 'runtime receipt keeps bind verification separate' verified "$(uecap_receipt_get bind_status)"

RELOAD_FAIL=0
uecap_apply_mode universal manual_locked
check_eq 'successful apply dispatches modem reload' 0 "$?"
check_eq 'runtime receipt records successful modem reload' success "$(uecap_receipt_get reload_result)"
check_eq 'successful bind remains separately verified' verified "$(uecap_receipt_get bind_status)"
check_eq 'successful reload records accepted handoff, not unverified effective payload' reload_accepted "$(uecap_receipt_get effective_state)"

UECAP_RELOAD_DISPATCHED=false
UECAP_RELOAD_RESULT=not_required_pre_modem
uecap_capture_radio_snapshot
uecap_write_runtime_receipt universal "$(uecap_hash "$UECAP_UNIVERSAL")" \
    "$(uecap_hash "$UECAP_TARGET")" pre_modem applied pre_modem_bind
if uecap_pre_modem_receipt_is_current universal; then
    PASS=$((PASS + 1))
    printf 'ok %s - same-boot pre-modem receipt validates source and target\n' "$((PASS + FAIL))"
else
    FAIL=$((FAIL + 1))
    printf 'not ok %s - same-boot pre-modem receipt validates source and target\n' "$((PASS + FAIL))"
fi
PIXEL9PRO_UECAP_BOOT_ID=other-boot
if uecap_pre_modem_receipt_is_current universal; then
    FAIL=$((FAIL + 1))
    printf 'not ok %s - cross-boot pre-modem receipt is rejected\n' "$((PASS + FAIL))"
else
    PASS=$((PASS + 1))
    printf 'ok %s - cross-boot pre-modem receipt is rejected\n' "$((PASS + FAIL))"
fi
PIXEL9PRO_UECAP_BOOT_ID=test-boot

printf '1..%s\n' "$((PASS + FAIL))"
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
