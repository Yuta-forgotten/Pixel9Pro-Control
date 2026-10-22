#!/bin/sh
# Execute the real worker with controlled system reads and a single sleep.
set -u
SOURCE_ROOT="$1"
MODDIR="$2/module"
mkdir -p "$MODDIR/scripts" "$MODDIR/webroot/cgi-bin" "$MODDIR/.background_worker.lock" || exit 2
for lib in background_tasks_lib.sh runtime_defaults_lib.sh thermal_history_lib.sh nr_mode_lib.sh profile_state_lib.sh; do
    cp "$SOURCE_ROOT/scripts/$lib" "$MODDIR/scripts/" || exit 2
done
cp "$SOURCE_ROOT/tests/fixtures/thermal_snapshot.sh" "$MODDIR/webroot/cgi-bin/_thermal_cache.sh" || exit 2
export PIXEL9PRO_MODDIR="$MODDIR"
. "$MODDIR/scripts/background_tasks_lib.sh"
. "$MODDIR/scripts/runtime_defaults_lib.sh"
. "$MODDIR/scripts/nr_mode_lib.sh"
. "$MODDIR/scripts/profile_state_lib.sh"
. "$SOURCE_ROOT/scripts/control_worker_lib.sh"
profile_state_init "$MODDIR"
SERVICE_BOOT_ID=$(cat /proc/sys/kernel/random/boot_id)
SERVICE_LOCK_DIR="$MODDIR/.background_worker.lock"
printf '%s' "$SERVICE_BOOT_ID" > "$MODDIR/.background_boot_ready"
printf off > "$MODDIR/.idle_isolate_mode"
SIM2_AUTO_FILE="$MODDIR/.sim2_auto_manage"
IDLE_ISOLATE_FILE="$MODDIR/.idle_isolate_mode"
STANDBY_DIAG_FILE="$MODDIR/.standby_diag_state"
THERMAL_CACHE="$MODDIR/.thermal_cache.json"
GAME_HANDOFF_POLICY_FILE="$MODDIR/.game_handoff_policy"
CPU_PROFILE_AVAILABLE=0
CPU_PROFILE_HEALTH_INTERVAL_S=300
log() { :; }
service_uptime() { awk '{printf "%d", $1}' /proc/uptime; }
service_start_ticks() { sed 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f20; }
read_onoff_file() { runtime_read_onoff "$1" "$2"; }
read_valid_sched_owner() { printf external; }
sbm_load_state() { SBM_PHASE=success; SBM_EFFECTIVE_MODE=ugt; }
display_state_read() { DISPLAY_STATE_INTERACTIVE=no; }
display_state_legacy_screen() { printf off; }
nr_mode_detect_setting() { NR_MODE_KEY=preferred_network_mode; NR_MODE_CURRENT=33; }
bg_read_enabled() { printf off; }
restore_boot_policies() { printf 'unexpected duplicate boot restore\n' >&2; exit 9; }
# Any policy IPC in the controlled off-screen case is a real failure.
settings() { printf 'unexpected settings IPC\n' >&2; exit 9; }
cmd() { printf 'unexpected cmd IPC\n' >&2; exit 9; }
dumpsys() { printf 'unexpected dumpsys IPC\n' >&2; exit 9; }
sleep() {
    [ "$1" = 900 ] || { printf 'unexpected sleep cadence: %s\n' "$1" >&2; exit 9; }
    printf '%s\n' "$1" > "$MODDIR/sleep_cadence"
    # Commit the highest pause while the production worker is waiting.
    printf on > "$MODDIR/.idle_isolate_mode"
}
control_worker_main || exit 1
[ "$(cat "$MODDIR/collector_calls")" = sysfs ] || exit 1
[ "$(cat "$MODDIR/sleep_cadence")" = 900 ] || exit 1
[ "$(wc -l < "$MODDIR/.thermal_history" | tr -d ' ')" = 2 ] || exit 1
grep -q 'worker_mode=deep_standby' "$STANDBY_DIAG_FILE" || exit 1
grep -q ',off,0,module$' "$MODDIR/.thermal_history" || exit 1
printf 'Production worker off-screen sysfs/cadence/master gate passed.\n'
