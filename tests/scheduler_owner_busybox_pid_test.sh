#!/system/bin/sh

SOURCE_ROOT="${1:-/sdcard/Download/Pixel9Pro-Control-TestLab/candidate/control}"
TEST_ROOT="${2:-/sdcard/Download/Pixel9Pro-Control-TestLab/runtime/owner_busybox_pid_$$}"
MOD="$TEST_ROOT/mod"
FAS="$TEST_ROOT/fas"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$((PASS + FAIL))" "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'not ok %s - %s\n' "$((PASS + FAIL))" "$1"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 expected=$2 actual=$3"; fi; }

mkdir -p "$MOD/scripts" "$FAS" || exit 2
cp "$SOURCE_ROOT/scripts/scheduler_owner_lib.sh" "$MOD/scripts/" || exit 2
. "$MOD/scripts/scheduler_owner_lib.sh" || exit 2
scheduler_owner_init "$MOD" "$FAS"

printf 'TAP version 13\n'
(
    _t_probe="$FAS/expected_pid"
    sh -c 'printf "%s" "$PPID"' > "$_t_probe" || exit 3
    _t_actual=$(cat "$_t_probe" 2>/dev/null)
    SO_TRANSITION_LOCK_MAX_ATTEMPTS=1 SO_TRANSITION_LOCK_RETRY_SLEEP_S=0 \
        so_acquire_transition_lock || exit 4
    _t_lock=$(cat "$SO_TRANSITION_LOCK_DIR/pid" 2>/dev/null)
    _t_lock_start=$(cat "$SO_TRANSITION_LOCK_DIR/start_ticks" 2>/dev/null)
    _t_lock_boot=$(cat "$SO_TRANSITION_LOCK_DIR/boot_id" 2>/dev/null)
    _t_live_start=$(so_process_start_ticks "$_t_lock")
    _t_live_boot=$(so_current_boot_id)
    printf '%s|%s|%s|%s|%s|%s\n' "$_t_actual" "$_t_lock" "$_t_lock_start" "$_t_live_start" "$_t_lock_boot" "$_t_live_boot" > "$FAS/result"
    so_release_transition_lock
)
assert_eq 'BusyBox worker acquires and releases the transition lock' 0 "$?"
_t_actual=$(cut -d'|' -f1 "$FAS/result" 2>/dev/null)
_t_lock=$(cut -d'|' -f2 "$FAS/result" 2>/dev/null)
_t_lock_start=$(cut -d'|' -f3 "$FAS/result" 2>/dev/null)
_t_live_start=$(cut -d'|' -f4 "$FAS/result" 2>/dev/null)
_t_lock_boot=$(cut -d'|' -f5 "$FAS/result" 2>/dev/null)
_t_live_boot=$(cut -d'|' -f6 "$FAS/result" 2>/dev/null)
assert_eq 'BusyBox child PPID matches lock metadata' "$_t_actual" "$_t_lock"
assert_eq 'BusyBox lock start ticks match the live worker' "$_t_lock_start" "$_t_live_start"
assert_eq 'BusyBox lock boot ID matches the current boot' "$_t_lock_boot" "$_t_live_boot"
assert_eq 'BusyBox worker leaves no transition lock directory' no "$([ -d "$FAS/.owner_transition.lock" ] && printf yes || printf no)"

printf '1..%s\n' "$((PASS + FAIL))"
printf '# pass=%s fail=%s root=%s\n' "$PASS" "$FAIL" "$TEST_ROOT"
[ "$FAIL" -eq 0 ]
