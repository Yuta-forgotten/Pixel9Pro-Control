#!/system/bin/sh
set -u

SOURCE_ROOT="${1:-.}"
TEST_ROOT="${2:-${TMPDIR:-/tmp}/pixel9pro_thermal_history_$$}"
MODULE="$TEST_ROOT/module"
mkdir -p "$MODULE/webroot/cgi-bin" "$MODULE/scripts" || exit 2
cp "$SOURCE_ROOT/scripts/thermal_history_lib.sh" "$MODULE/scripts/" || exit 2
cp "$SOURCE_ROOT/scripts/background_tasks_lib.sh" "$MODULE/scripts/" || exit 2
cp "$SOURCE_ROOT/webroot/cgi-bin/_common.sh" "$MODULE/webroot/cgi-bin/" || exit 2
cp "$SOURCE_ROOT/webroot/cgi-bin/_thermal_cache.sh" "$MODULE/webroot/cgi-bin/" || exit 2
cp "$SOURCE_ROOT/webroot/cgi-bin/thermal.sh" "$MODULE/webroot/cgi-bin/" || exit 2

# Execute the production encoder, including controls and trailing newlines.
PIXEL9PRO_MODDIR="$MODULE"
export PIXEL9PRO_MODDIR
. "$MODULE/webroot/cgi-bin/_common.sh" || exit 2
_escape_value=$(printf 'quote"\\tab\tline\nnext\rend\n\n_')
_escape_value=${_escape_value%_}
printf '@@escape\n{"value":"'
json_escape "$_escape_value"
printf '"}\n'

now=$(date +%s)
printf '%s,39000,boot-a,session-a,thermal_hal,1,0,ok,on,100,module\n' "$((now - 1200))" > "$MODULE/.thermal_history"
printf '%s,33100,boot-a,session-a,thermal_sysfs,1,0,screen_off_sample,off,400,battery\n' "$((now - 900))" >> "$MODULE/.thermal_history"
printf '%s,41000,boot-a,session-a,thermal_hal,1,0,ok,on,700,module\n' "$((now - 600))" >> "$MODULE/.thermal_history"

run_history() {
    REQUEST_METHOD=GET REMOTE_ADDR=127.0.0.1 QUERY_STRING="$1" \
        PIXEL9PRO_MODDIR="$MODULE" sh "$MODULE/webroot/cgi-bin/thermal.sh"
}

printf '@@module\n%s\n' "$(run_history "history=1&sensor=module&start_ts=$((now - 1800))&end_ts=$now")"
printf '@@battery\n%s\n' "$(run_history "history=1&sensor=battery&start_ts=$((now - 7200))&end_ts=$now")"
printf '@@empty\n%s\n' "$(run_history "history=1&sensor=module&start_ts=$((now - 7200))&end_ts=$((now - 2000))")"
printf '@@invalid\n%s\n' "$(run_history "history=1&sensor=power&start_ts=$((now - 1800))&end_ts=$now")"

# Replay a real foreground cache read while the service is not running.
printf '[{"zone":"VIRTUAL-SKIN","temp":39250},{"zone":"battery","temp":33100}]' > "$MODULE/.thermal_cache.json"
printf '@@live\n%s\n' "$(run_history '')"
run_history '' >/dev/null
printf '@@afterlive\n%s\n' "$(run_history "history=1&sensor=module&start_ts=$((now - 1800))&end_ts=$((now + 30))")"

# Exercise lock ownership: a busy writer is skipped, a previous boot is reclaimed.
mkdir "$MODULE/.thermal_history.lock" || exit 2
printf 'active\n' > "$MODULE/.thermal_history.lock/token"
run_history '' >/dev/null
[ -f "$MODULE/.thermal_history.lock/token" ] || exit 1
printf 'previous-boot\n' > "$MODULE/.thermal_history.lock/boot"
run_history '' >/dev/null
[ ! -d "$MODULE/.thermal_history.lock" ] || exit 1

printf '%s,38500\n' "$((now - 60))" > "$MODULE/.thermal_history"
printf '@@legacy\n%s\n' "$(run_history "history=1&sensor=module&start_ts=$((now - 1800))&end_ts=$now")"
printf '%s,38200,boot-a,legacy-session,service_worker,1,0,ok,on,900,300\n' "$((now - 120))" > "$MODULE/.thermal_history"
printf '@@legacy_extended\n%s\n' "$(run_history "history=1&sensor=module&start_ts=$((now - 1800))&end_ts=$now")"

# The highest switch blocks the shared writer, including foreground cache reads.
cp "$MODULE/.thermal_history" "$TEST_ROOT/before_pause"
printf 'on' > "$MODULE/.idle_isolate_mode"
run_history '' >/dev/null
cmp -s "$MODULE/.thermal_history" "$TEST_ROOT/before_pause" || exit 1
printf '@@paused\n%s\n' "$(run_history "history=1&sensor=module&start_ts=$((now - 1800))&end_ts=$now")"
printf 'off' > "$MODULE/.idle_isolate_mode"
run_history '' >/dev/null
cmp -s "$MODULE/.thermal_history" "$TEST_ROOT/before_pause" && exit 1

mkdir -p "$TEST_ROOT/migration/old" "$TEST_ROOT/migration/new" || exit 2
export OLDDIR="$TEST_ROOT/migration/old" MODPATH="$TEST_ROOT/migration/new"
printf '39000\n' > "$OLDDIR/.thermal_history"
printf 'retired power data\n' > "$OLDDIR/.power_history"
printf 'manual\n' > "$OLDDIR/.profile_policy"
printf '_migration_failed=0\n' > "$TEST_ROOT/migration/run.sh"
awk '/^    for _sf in / { capture=1 } capture { print } capture && /^    done$/ { exit }' "$SOURCE_ROOT/customize.sh" >> "$TEST_ROOT/migration/run.sh"
printf '[ "$_migration_failed" -eq 0 ]\n' >> "$TEST_ROOT/migration/run.sh"
sh "$TEST_ROOT/migration/run.sh" || exit 1
cmp -s "$OLDDIR/.thermal_history" "$MODPATH/.thermal_history" || exit 1
cmp -s "$OLDDIR/.profile_policy" "$MODPATH/.profile_policy" || exit 1
[ ! -e "$MODPATH/.power_history" ] || exit 1

if grep -Eq 'system_history_config|analytics_enabled|power_rank|dumpsys batterystats|thermal_burst|\.power_history|charge_counter' "$SOURCE_ROOT/service.sh" "$SOURCE_ROOT/scripts/control_worker_lib.sh"; then
    printf 'not ok - service retains a power-history or burst path\n'
    exit 1
fi
grep -q 'HISTORY_INTERVAL_ON=60$' "$SOURCE_ROOT/scripts/control_worker_lib.sh" || exit 1
grep -q 'HISTORY_INTERVAL_OFF=900$' "$SOURCE_ROOT/scripts/control_worker_lib.sh" || exit 1
grep -q '_thermal_source=sysfs' "$SOURCE_ROOT/scripts/control_worker_lib.sh" || exit 1
grep -q '_thermal_source=hal' "$SOURCE_ROOT/scripts/control_worker_lib.sh" || exit 1
