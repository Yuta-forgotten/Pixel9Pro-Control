#!/system/bin/sh

SOURCE_ROOT="${1:-/sdcard/Download/Pixel9Pro-Control-TestLab/candidate/control}"
TEST_ROOT="${2:-/sdcard/Download/Pixel9Pro-Control-TestLab/runtime/scheduler_guard_$$}"
PASS=0; FAIL=0; TOTAL=0
ok() { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$TOTAL" "$1"; }
not_ok() { TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); printf 'not ok %s - %s\n' "$TOTAL" "$1"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 expected=$2 actual=$3"; fi; }

mkdir -p "$TEST_ROOT" || exit 2
. "$SOURCE_ROOT/scripts/scheduler_transition_guard_lib.sh" || exit 2
STG_MAX_ATTEMPTS=3
STG_DEADLINE_S=30
stg_init "$TEST_ROOT/guard"
printf 'TAP version 13\n'

for _t_now in 100 110 120; do
    if stg_begin_attempt profile:battery boot-a "$_t_now"; then ok "attempt $_t_now admitted"; else not_ok "attempt $_t_now admitted"; fi
    stg_record_failure "$_t_now" write_mismatch >/dev/null 2>&1 || true
done
stg_load
assert_eq 'third failure reaches terminal state' yes "$STG_TERMINAL"
assert_eq 'retry budget records exactly three attempts' 3 "$STG_ATTEMPTS"
stg_begin_attempt profile:battery boot-a 121 >/dev/null 2>&1
assert_eq 'terminal generation rejects further attempts' 77 "$?"
stg_load
assert_eq 'rejected attempt does not increment counter' 3 "$STG_ATTEMPTS"

if stg_begin_attempt profile:balanced boot-a 122; then ok 'target change opens new generation'; else not_ok 'target change opens new generation'; fi
stg_load
assert_eq 'new target resets attempt count' 1 "$STG_ATTEMPTS"
stg_record_success applied >/dev/null 2>&1
stg_load
assert_eq 'success is terminal' yes "$STG_TERMINAL"
assert_eq 'success result is explicit' applied "$STG_RESULT"

if stg_begin_attempt profile:balanced boot-b 200; then ok 'new boot opens new generation'; else not_ok 'new boot opens new generation'; fi
stg_load
assert_eq 'new boot resets attempt count' 1 "$STG_ATTEMPTS"

printf '1..%s\n' "$TOTAL"
printf '# pass=%s fail=%s root=%s\n' "$PASS" "$FAIL" "$TEST_ROOT"
[ "$FAIL" -eq 0 ]
