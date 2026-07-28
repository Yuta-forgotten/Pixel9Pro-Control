#!/system/bin/sh

SOURCE_ROOT="${1:-/sdcard/Download/Pixel9Pro-Control-TestLab/candidate/control}"
TEST_ROOT="${2:-/sdcard/Download/Pixel9Pro-Control-TestLab/runtime/scheduler_boot_mode_$$}"
PASS=0
FAIL=0
TOTAL=0

ok() { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$TOTAL" "$1"; }
not_ok() { TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); printf 'not ok %s - %s\n' "$TOTAL" "$1"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 expected=$2 actual=$3"; fi; }
state_value() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -n 1 | tr -d '\r'; }

MOD="$TEST_ROOT/mod"
FAS="$TEST_ROOT/fas"
RUNTIME="$TEST_ROOT/runtime"
APD="$TEST_ROOT/apd.sh"
APD_STATE="$TEST_ROOT/apd_state"
APD_WRITES="$TEST_ROOT/apd_writes"
APD_FAIL="$TEST_ROOT/apd_fail"
BOOT_ID="$TEST_ROOT/boot_id"
UGT_COUNT="$TEST_ROOT/ugt_count"
PERMISSION="$TEST_ROOT/permission"
POWERHAL="$TEST_ROOT/powerhal"
mkdir -p "$MOD/scripts" "$FAS" "$RUNTIME" || exit 2
for _t_script in scheduler_owner_lib.sh scheduler_boot_mode_lib.sh scheduler_reconcile.sh runtime_defaults_lib.sh cpu_profile_lib.sh cpu_profile.sh; do
    cp "$SOURCE_ROOT/scripts/$_t_script" "$MOD/scripts/" || exit 2
done

cat > "$APD" <<'EOF'
#!/system/bin/sh
case "$1:$2" in
    module:list)
        _s=$(cat "$MOCK_APD_STATE" 2>/dev/null)
        case "$_s" in enabled) _e=true ;; disabled) _e=false ;; absent) printf '[]\n'; exit 0 ;; *) exit 2 ;; esac
        printf '[{"id": "uperf", "enabled": "%s", "remove": "false"}]\n' "$_e"
        ;;
    module:enable|module:disable)
        _n=$(cat "$MOCK_APD_WRITES" 2>/dev/null); case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
        printf '%s\n' $((_n + 1)) > "$MOCK_APD_WRITES"
        [ ! -f "$MOCK_APD_FAIL" ] || exit 1
        [ "$2" = "enable" ] && printf 'enabled\n' > "$MOCK_APD_STATE" || printf 'disabled\n' > "$MOCK_APD_STATE"
        ;;
    *) exit 64 ;;
esac
EOF

export MOCK_APD_STATE="$APD_STATE" MOCK_APD_WRITES="$APD_WRITES" MOCK_APD_FAIL="$APD_FAIL"
printf 'disabled\n' > "$APD_STATE"
printf '0\n' > "$APD_WRITES"
printf 'boot-a\n' > "$BOOT_ID"
printf '0\n' > "$UGT_COUNT"
printf 'ok\n' > "$PERMISSION"
printf '0\n' > "$POWERHAL"
printf 'pixel\n' > "$MOD/.sched_owner_desired"
printf 'pixel\n' > "$MOD/.cpu_sched_owner"
printf 'off\n' > "$MOD/.game_handoff_policy"
printf 'battery\n' > "$MOD/.current_profile"

. "$MOD/scripts/scheduler_owner_lib.sh" || exit 2
. "$MOD/scripts/scheduler_boot_mode_lib.sh" || exit 2
scheduler_owner_init "$MOD" "$FAS"
SBM_TEST_MODE=1
SBM_APD_BIN="$APD"
SBM_BOOT_ID_PATH="$BOOT_ID"
SBM_TEST_UPERF_COUNT_FILE="$UGT_COUNT"
SBM_TEST_CPUFREQ_PERMISSION_FILE="$PERMISSION"
SBM_TEST_POWERHAL_FAILURE_FILE="$POWERHAL"
SBM_TEST_NOW=100
SBM_STATE_COMMIT_RETRY_SLEEP_S=0
export SBM_TEST_MODE SBM_APD_BIN SBM_BOOT_ID_PATH SBM_TEST_UPERF_COUNT_FILE SBM_TEST_CPUFREQ_PERMISSION_FILE SBM_TEST_POWERHAL_FAILURE_FILE SBM_TEST_NOW SBM_STATE_COMMIT_RETRY_SLEEP_S
sbm_init "$MOD" "$FAS"

printf 'TAP version 13\n'

# KernelSU/Magisk boot verification may read standard module markers, but
# next-boot staging remains APatch-only until their CLIs are verified.
FALLBACK_MODULES="$TEST_ROOT/modules"
mkdir -p "$FALLBACK_MODULES/uperf" || exit 2
printf '1\n' > "$FALLBACK_MODULES/uperf/disable"
SBM_TEST_MODE=0
SBM_APD_BIN="$TEST_ROOT/missing_apd"
SBM_MODULES_ROOT="$FALLBACK_MODULES"
SBM_MODULES_UPDATE_ROOT="$TEST_ROOT/modules_update"
assert_eq 'module marker fallback reads disabled UGT' disabled "$(sbm_apd_module_state)"
rm -f "$FALLBACK_MODULES/uperf/disable"
assert_eq 'module marker fallback reads enabled UGT' enabled "$(sbm_apd_module_state)"
sbm_stage_mode pixel >/dev/null 2>&1
assert_eq 'non-APatch staging fails closed before mutation' 69 "$?"
SBM_TEST_MODE=1
SBM_APD_BIN="$APD"
SBM_MODULES_ROOT="$TEST_ROOT/unused_modules"
SBM_MODULES_UPDATE_ROOT="$TEST_ROOT/unused_modules_update"

if sbm_stage_mode ugt; then ok 'UGT mode stages through APatch'; else not_ok 'UGT mode stages through APatch'; fi
assert_eq 'staging does not change current-boot desired owner' pixel "$(cat "$MOD/.sched_owner_desired")"
assert_eq 'UGT stage is pending reboot' pending_reboot "$(state_value "$MOD/.scheduler_boot_state" phase)"
assert_eq 'UGT APatch state enabled' enabled "$(cat "$APD_STATE")"
assert_eq 'UGT stage performs one mutation' 1 "$(cat "$APD_WRITES")"

_t_pending_sig=$(cksum "$MOD/.scheduler_boot_state" | awk '{print $1 ":" $2}')
SBM_BOOT_VERIFY_INTERVAL_S=0 SCHEDULER_RECONCILE_FAS_ROOT="$FAS" \
sh "$MOD/scripts/scheduler_reconcile.sh" boot "$MOD" >/dev/null 2>&1
assert_eq 'same-boot reconcile preserves pending transition' pending_reboot "$(state_value "$MOD/.scheduler_boot_state" phase)"
assert_eq 'same-boot reconcile does not republish desired owner' pixel "$(cat "$MOD/.sched_owner_desired")"
assert_eq 'same-boot reconcile does not rewrite pending state' "$_t_pending_sig" "$(cksum "$MOD/.scheduler_boot_state" | awk '{print $1 ":" $2}')"

if sbm_cancel_pending; then ok 'pending mode can be cancelled'; else not_ok 'pending mode can be cancelled'; fi
assert_eq 'cancel restores APatch disabled state' disabled "$(cat "$APD_STATE")"
assert_eq 'cancel restores verified active state' success "$(state_value "$MOD/.scheduler_boot_state" phase)"

if sbm_stage_mode ugt; then ok 'UGT mode restages after cancel'; else not_ok 'UGT mode restages after cancel'; fi
printf 'boot-b\n' > "$BOOT_ID"
printf '1\n' > "$UGT_COUNT"
SBM_BOOT_VERIFY_INTERVAL_S=0 SBM_VERIFY_INTERVAL_S=0 \
SBM_TEST_FAIL_COMMIT_ALWAYS_PHASE=success \
SCHEDULER_RECONCILE_FAS_ROOT="$FAS" \
sh "$MOD/scripts/scheduler_reconcile.sh" boot "$MOD" >/dev/null 2>&1
_t_rc=$?
assert_eq 'UGT boot verification succeeds' 0 "$_t_rc"
assert_eq 'UGT boot publishes desired owner after reboot' external "$(cat "$MOD/.sched_owner_desired")"
assert_eq 'UGT boot publishes effective owner after verification' external "$(cat "$MOD/.cpu_sched_owner")"
sbm_load_state
assert_eq 'terminal fallback publishes UGT success after primary commit exhaustion' active_ugt "$SBM_RESULT"
assert_eq 'terminal fallback is explicitly recorded' yes "$(state_value "$MOD/.scheduler_terminal_state" fallback)"

# Stage Pixel without stopping UGT in the current boot, then verify a clean next boot.
if sbm_stage_mode pixel; then ok 'Pixel mode stages without hot-stopping UGT'; else not_ok 'Pixel mode stages without hot-stopping UGT'; fi
assert_eq 'Pixel stage leaves current UGT process untouched' 1 "$(cat "$UGT_COUNT")"
printf 'boot-c\n' > "$BOOT_ID"
printf '0\n' > "$UGT_COUNT"

CPU0="$TEST_ROOT/cpu0"; CPU4="$TEST_ROOT/cpu4"; CPU7="$TEST_ROOT/cpu7"
CPUSET="$TEST_ROOT/cpuset"; VENDOR="$TEST_ROOT/vendor"; CAP="$TEST_ROOT/cap"
mkdir -p "$CPU0/sched_pixel" "$CPU4/sched_pixel" "$CPU7/sched_pixel" \
    "$CPUSET/top-app" "$CPUSET/foreground" "$CPUSET/background" "$CPUSET/system-background" "$VENDOR" || exit 2
for _t_root in "$CPU0" "$CPU4" "$CPU7"; do printf '9\n' > "$_t_root/sched_pixel/response_time_ms"; printf '9\n' > "$_t_root/sched_pixel/response_time_ms_nom"; done
printf '0-7\n' > "$CPUSET/top-app/cpus"; printf '0-6\n' > "$CPUSET/foreground/cpus"
printf '0-3\n' > "$CPUSET/background/cpus"; printf '0-3\n' > "$CPUSET/system-background/cpus"
printf '1024\n' > "$VENDOR/ug_bg_uclamp_max"; printf '308\n' > "$VENDOR/ug_bg_group_throttle"; printf '1024\n' > "$CAP"
export CPU_PROFILE_TEST_MODE=1 CPU_PROFILE_CPU0_ROOT="$CPU0" CPU_PROFILE_CPU4_ROOT="$CPU4" CPU_PROFILE_CPU7_ROOT="$CPU7"
export CPU_PROFILE_CPUSET_ROOT="$CPUSET" CPU_PROFILE_VENDOR_SCHED_ROOT="$VENDOR" CPU_PROFILE_UCLAMP_PATH="$CAP"
PUBLISH_FAIL_MARKER="$TEST_ROOT/fail_publish_once"
printf '1\n' > "$PUBLISH_FAIL_MARKER"
SBM_VERIFY_SAMPLES=1 SBM_VERIFY_INTERVAL_S=0 SBM_RETRY_SLEEP_S=0 \
SR_TEST_FAIL_PUBLISH_STEP=effective_owner SR_TEST_FAIL_PUBLISH_MARKER="$PUBLISH_FAIL_MARKER" \
SCHEDULER_RECONCILE_FAS_ROOT="$FAS" \
sh "$MOD/scripts/scheduler_reconcile.sh" boot "$MOD" >/dev/null 2>&1
_t_rc=$?
assert_eq 'partial Pixel owner publish fails closed' 1 "$_t_rc"
sbm_load_state
assert_eq 'partial owner publish reaches terminal failure' failed "$SBM_PHASE"
assert_eq 'partial owner publish reports complete rollback' failed_publish_pixel_effective_rolled_back "$SBM_RESULT"
assert_eq 'partial owner publish restores desired owner' external "$(cat "$MOD/.sched_owner_desired")"
assert_eq 'partial owner publish restores effective owner' external "$(cat "$MOD/.cpu_sched_owner")"

SBM_VERIFY_SAMPLES=1 SBM_VERIFY_INTERVAL_S=0 SBM_RETRY_SLEEP_S=0 \
SCHEDULER_RECONCILE_FAS_ROOT="$FAS" \
sh "$MOD/scripts/scheduler_reconcile.sh" retry "$MOD" >/dev/null 2>&1
_t_rc=$?
assert_eq 'Pixel boot verification succeeds' 0 "$_t_rc"
assert_eq 'Pixel boot publishes desired owner after reboot' pixel "$(cat "$MOD/.sched_owner_desired")"
assert_eq 'Pixel boot publishes effective owner after verification' pixel "$(cat "$MOD/.cpu_sched_owner")"
assert_eq 'Pixel battery L2 is atomic with profile' '150/80' "$(cat "$VENDOR/ug_bg_uclamp_max")/$(cat "$VENDOR/ug_bg_group_throttle")"

# Health is read-only; the first explicit repair consumes the only auto budget.
printf '200\n' > "$VENDOR/ug_bg_uclamp_max"
_t_before=$(cat "$VENDOR/ug_bg_uclamp_max")
SCHEDULER_RECONCILE_FAS_ROOT="$FAS" sh "$MOD/scripts/scheduler_reconcile.sh" health "$MOD" >/dev/null 2>&1
_t_health_rc=$?
assert_eq 'health reports profile drift' 5 "$_t_health_rc"
assert_eq 'health does not write scheduler nodes' "$_t_before" "$(cat "$VENDOR/ug_bg_uclamp_max")"
SBM_VERIFY_SAMPLES=1 SBM_VERIFY_INTERVAL_S=0 SBM_RETRY_SLEEP_S=0 \
SCHEDULER_RECONCILE_FAS_ROOT="$FAS" sh "$MOD/scripts/scheduler_reconcile.sh" repair "$MOD" >/dev/null 2>&1
assert_eq 'one bounded repair restores battery L2' 150 "$(cat "$VENDOR/ug_bg_uclamp_max")"
printf '200\n' > "$VENDOR/ug_bg_uclamp_max"
SBM_VERIFY_SAMPLES=1 SBM_VERIFY_INTERVAL_S=0 SBM_RETRY_SLEEP_S=0 \
SCHEDULER_RECONCILE_FAS_ROOT="$FAS" sh "$MOD/scripts/scheduler_reconcile.sh" repair "$MOD" >/dev/null 2>&1
_t_second_repair_rc=$?
assert_eq 'second automatic repair is latched' 77 "$_t_second_repair_rc"
assert_eq 'latched repair leaves drift untouched' 200 "$(cat "$VENDOR/ug_bg_uclamp_max")"

# APatch mutation failure is bounded and reaches a final state.
printf 'disabled\n' > "$APD_STATE"; printf '0\n' > "$APD_WRITES"; printf '1\n' > "$APD_FAIL"; printf '0\n' > "$UGT_COUNT"
SBM_RETRY_SLEEP_S=0
export SBM_RETRY_SLEEP_S
sbm_stage_mode ugt >/dev/null 2>&1
_t_stage_fail_rc=$?
assert_eq 'failed APatch staging returns nonzero' 1 "$_t_stage_fail_rc"
assert_eq 'failed APatch staging stops after retry budget' 3 "$(cat "$APD_WRITES")"
assert_eq 'failed APatch staging is terminal' failed "$(state_value "$MOD/.scheduler_boot_state" phase)"

# A final state-commit failure rolls APatch staging back and publishes a
# terminal failure instead of leaving an untracked next-boot mutation.
rm -f "$APD_FAIL"
printf 'disabled\n' > "$APD_STATE"; printf '0\n' > "$APD_WRITES"; printf '0\n' > "$UGT_COUNT"
COMMIT_FAIL_MARKER="$TEST_ROOT/fail_commit_once"
printf '1\n' > "$COMMIT_FAIL_MARKER"
SBM_TEST_FAIL_COMMIT_PHASE=pending_reboot
SBM_TEST_FAIL_COMMIT_MARKER="$COMMIT_FAIL_MARKER"
export SBM_TEST_FAIL_COMMIT_PHASE SBM_TEST_FAIL_COMMIT_MARKER
sbm_stage_mode ugt >/dev/null 2>&1
_t_commit_fail_rc=$?
unset SBM_TEST_FAIL_COMMIT_PHASE SBM_TEST_FAIL_COMMIT_MARKER
assert_eq 'state commit failure returns distinct nonzero' 74 "$_t_commit_fail_rc"
assert_eq 'state commit failure rolls APatch state back' disabled "$(cat "$APD_STATE")"
assert_eq 'state commit rollback performs one compensating write' 2 "$(cat "$APD_WRITES")"
assert_eq 'state commit failure publishes terminal status' failed "$(state_value "$MOD/.scheduler_boot_state" phase)"
assert_eq 'state commit failure reports complete rollback' failed_stage_state_commit_rolled_back "$(state_value "$MOD/.scheduler_boot_state" result)"

printf '1..%s\n' "$TOTAL"
printf '# pass=%s fail=%s root=%s\n' "$PASS" "$FAIL" "$TEST_ROOT"
[ "$FAIL" -eq 0 ]
