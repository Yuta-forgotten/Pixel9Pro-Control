#!/system/bin/sh

SOURCE_ROOT="${1:-${0%/tests/*}}"
TEST_ROOT="${2:-${TMPDIR:-/tmp}/pixel9pro_profile_state_$$}"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$((PASS + FAIL))" "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'not ok %s - %s\n' "$((PASS + FAIL))" "$1"; }
assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 expected=$2 actual=$3"; fi
}

mkdir -p "$TEST_ROOT" || exit 2
. "$SOURCE_ROOT/scripts/cpu_profile_lib.sh" || exit 2
. "$SOURCE_ROOT/scripts/profile_state_lib.sh" || exit 2
profile_state_init "$TEST_ROOT" || exit 2
printf 'TAP version 13\n'

printf 'battery\n' > "$PROFILE_FILE"
printf 'default\n' > "$PROFILE_MANUAL_FILE"
printf 'auto\n' > "$PROFILE_POLICY_FILE"
assert_eq '读取合法当前 profile' battery "$(profile_state_read_active balanced)"
assert_eq '读取合法手动 profile' default "$(profile_state_read_manual balanced)"
assert_eq '读取合法 policy' auto "$(profile_state_read_policy)"

printf 'light\n' > "$PROFILE_FILE"
printf 'invalid\n' > "$PROFILE_POLICY_FILE"
assert_eq '旧 light profile 归一为默认值' balanced "$(profile_state_read_active balanced)"
assert_eq '非法 policy 回退 manual' manual "$(profile_state_read_policy)"

rm -f "$PROFILE_FILE" "$PROFILE_POLICY_FILE"
assert_eq '缺失 profile 使用调用方默认值' default "$(profile_state_read_active default)"
assert_eq '缺失 policy 使用 manual' manual "$(profile_state_read_policy)"

printf 'balanced\n' > "$PROFILE_FILE"
printf 'balanced\n' > "$PROFILE_MANUAL_FILE"
printf 'manual\n' > "$PROFILE_POLICY_FILE"
printf 'manual_selected\n' > "$PROFILE_AUTO_REASON_FILE"
profile_state_commit battery default auto auto_enabled
assert_eq '四文件 profile state 事务提交成功' 0 "$?"
assert_eq '事务复读当前 profile' battery "$(cat "$PROFILE_FILE")"
assert_eq '事务复读手动 profile' default "$(cat "$PROFILE_MANUAL_FILE")"
assert_eq '事务复读 policy' auto "$(cat "$PROFILE_POLICY_FILE")"
assert_eq '事务复读 reason' auto_enabled "$(cat "$PROFILE_AUTO_REASON_FILE")"

_test_atomic_write() {
    _test_path="$1"
    _test_value="$2"
    if [ "${PROFILE_STATE_TEST_FAIL_ONCE:-0}" = "1" ] \
        && [ "$_test_path" = "$PROFILE_POLICY_FILE" ]; then
        PROFILE_STATE_TEST_FAIL_ONCE=0
        return 1
    fi
    [ -n "$_test_path" ] && [ ! -d "$_test_path" ] || return 1
    _test_tmp="${_test_path}.test.$$"
    printf '%s' "$_test_value" > "$_test_tmp" 2>/dev/null \
        && mv "$_test_tmp" "$_test_path" 2>/dev/null \
        && [ "$(cat "$_test_path" 2>/dev/null)" = "$_test_value" ]
}
profile_state_atomic_write() { _test_atomic_write "$1" "$2"; }
PROFILE_STATE_TEST_FAIL_ONCE=1
profile_state_commit balanced balanced manual manual_policy >/dev/null 2>&1
assert_eq '四文件提交写失败时返回失败' 1 "$?"
assert_eq '四文件提交失败后 rollback complete' complete "$PROFILE_STATE_ROLLBACK_RESULT"
assert_eq 'rollback 恢复当前 profile' battery "$(cat "$PROFILE_FILE")"
assert_eq 'rollback 恢复手动 profile' default "$(cat "$PROFILE_MANUAL_FILE")"
assert_eq 'rollback 恢复 policy' auto "$(cat "$PROFILE_POLICY_FILE")"
assert_eq 'rollback 恢复 reason' auto_enabled "$(cat "$PROFILE_AUTO_REASON_FILE")"

PROFILE_STATE_HISTORY_MAX=2
profile_state_append_history balanced manual_selected 100 manual pixel 0 36000 0 0 16/40/200
assert_eq 'history 首行写入成功' 0 "$?"
profile_state_append_history battery auto_hot 101 auto pixel 1 40000 1 0 28/80/320
profile_state_append_history default manual_policy 102 manual pixel 0 37000 0 1024 9/52/165
assert_eq 'history 按共享上限裁剪' 2 "$(wc -l < "$PROFILE_HISTORY_FILE" | tr -d ' ')"
assert_eq 'history 保留最新 observation' '102,manual,pixel,default,manual_policy,0,37000,0,1024,9/52/165' "$(profile_state_history_last)"
assert_eq 'history owner/schema 检查通过' 0 "$(profile_state_history_has_owner_field; echo $?)"

printf '1..%s\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
