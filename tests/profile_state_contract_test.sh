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

printf '1..%s\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
