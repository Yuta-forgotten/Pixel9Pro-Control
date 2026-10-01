#!/bin/sh
# Host behavior tests for production standby observations. Android commands are
# replaced with counted fixtures; no device, Settings, wakelock or alarm is used.
set -u

SOURCE_ROOT="${1:-${0%/tests/*}}"
SOURCE_ROOT=$(cd "$SOURCE_ROOT" && pwd) || exit 2
TEST_PARENT="${2:-${TMPDIR:-work/tests}}"
mkdir -p "$TEST_PARENT" || exit 2
TEST_ROOT=$(mktemp -d "$TEST_PARENT/pixel9pro_standby.XXXXXX") || exit 2
case "$TEST_ROOT" in "$TEST_PARENT"/pixel9pro_standby.*) ;; *) exit 2 ;; esac
trap 'rm -rf "$TEST_ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$((PASS + FAIL))" "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'not ok %s - %s\n' "$((PASS + FAIL))" "$1"; }
check_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 (expected=$2 actual=$3)"; fi
}
check_absent() { if [ ! -e "$2" ]; then ok "$1"; else not_ok "$1"; fi; }
command -v python3 >/dev/null 2>&1 || { printf 'fixture failure: python3 is required\n'; exit 2; }
STANDBY_TEST_REAL_CAT=$(command -v cat) || exit 2
STANDBY_TEST_CALLS="$TEST_ROOT/calls"
export STANDBY_TEST_REAL_CAT STANDBY_TEST_CALLS
mkdir "$TEST_ROOT/bin" || exit 2
cat > "$TEST_ROOT/bin/cat" <<'MOCK_CAT'
#!/bin/sh
case "${1:-}" in
    /sys/class/power_supply/battery/temp) printf '312\n' ;;
    *) "$STANDBY_TEST_REAL_CAT" "$@" ;;
esac
MOCK_CAT
cat > "$TEST_ROOT/bin/dumpsys" <<'MOCK_DUMPSYS'
#!/bin/sh
printf 'dumpsys %s\n' "$*" >> "$STANDBY_TEST_CALLS"
if [ "${1:-}" = -t ]; then shift 2; fi
case "${1:-}" in
    thermalservice)
        [ "${STANDBY_TEST_DUMP_FAIL:-0}" != 1 ] || { printf 'Thermal Status: 2\n'; exit 1; }
        printf '%s\n' 'Thermal Status: 2' 'Current temperatures from HAL:' \
            'Temperature{mValue=39.125, mType=3, mName=VIRTUAL-SKIN, mStatus=0}' \
            'Current cooling devices from HAL:'
        ;;
    batterystats)
        [ "${STANDBY_TEST_DUMP_FAIL:-0}" != 1 ] || { printf '  UID partial failed dump\n'; exit 1; }
        case " $* " in
            *' --history '*)
                printf '%s\n' '9,h,0:RESET:TIME:1790000000000' \
                    '9,h,0,Bl=75,Bcc=3000,Bt=310,Bv=4100,Bs=d,-S,di=full'
                ;;
            *' --checkin '*) printf '%s\n' '9,0,l,bt,0,0,0,0,0,123456' '9,0,l,pwi,screen,1.5' ;;
            *)
                [ "${STANDBY_TEST_DUMP_EMPTY:-0}" != 1 ] || exit 0
                printf '%s\n' 'Estimated power use (mAh):' '  UID 1000: 1.5' 'unretained raw detail'
                ;;
        esac
        ;;
    *) exit 1 ;;
esac
MOCK_DUMPSYS
cat > "$TEST_ROOT/bin/timeout" <<'MOCK_TIMEOUT'
#!/bin/sh
printf 'timeout %s\n' "$*" >> "$STANDBY_TEST_CALLS"
[ "${1:-}" = -k ] && [ "${2:-}" = 2 ] || exit 90
shift 2
[ "${1:-}" = 15 ] || exit 91
shift
[ "${1:-}" = dumpsys ] && [ "${2:-}" = -t ] && [ "${3:-}" = 10 ] || exit 92
[ "${STANDBY_TEST_TIMEOUT_FAIL:-0}" != 1 ] || exit 124
"$@"
MOCK_TIMEOUT
chmod +x "$TEST_ROOT/bin/cat" "$TEST_ROOT/bin/dumpsys" "$TEST_ROOT/bin/timeout"
PATH="$TEST_ROOT/bin:$PATH"
export PATH
reset_calls() { : > "$STANDBY_TEST_CALLS"; }
count_calls() { awk -v kind="$1" '$1 == kind { n++ } END { print n+0 }' "$STANDBY_TEST_CALLS"; }

printf 'TAP version 13\n'
. "$SOURCE_ROOT/webroot/cgi-bin/_thermal_cache.sh" || exit 2
reset_calls
if build_thermal_json sysfs > "$TEST_ROOT/sysfs.json"; then
    ok 'sysfs thermal production builder succeeds'
else
    not_ok 'sysfs thermal production builder succeeds'
fi
check_eq 'sysfs thermal builder makes zero Binder dumps' 0 "$(count_calls dumpsys)"
if python3 - "$TEST_ROOT/sysfs.json" <<'ASSERT_SYSFS'
import json, sys
zones = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(zones, list)
actual = {zone["zone"]: zone["temp"] for zone in zones}
assert actual.get("battery") == 31200, actual
assert "VIRTUAL-SKIN" not in actual, actual
ASSERT_SYSFS
then ok 'sysfs JSON preserves measured battery and omits unavailable virtual skin'
else not_ok 'sysfs JSON preserves measured battery and omits unavailable virtual skin'; fi

for mode in hal default; do
    reset_calls
    if [ "$mode" = default ]; then
        build_thermal_json > "$TEST_ROOT/$mode.json"
    else
        build_thermal_json "$mode" > "$TEST_ROOT/$mode.json"
    fi
    check_eq "$mode thermal builder performs one HAL dump" 1 "$(count_calls dumpsys)"
    if python3 - "$TEST_ROOT/$mode.json" <<'ASSERT_HAL'
import json, sys
zones = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(zones, list)
actual = {zone["zone"]: zone["temp"] for zone in zones}
assert actual.get("VIRTUAL-SKIN") == 39125, actual
assert actual.get("battery") == 31200, actual
ASSERT_HAL
    then ok "$mode thermal JSON includes actual HAL and sysfs temperatures"
    else not_ok "$mode thermal JSON includes actual HAL and sysfs temperatures"; fi
done
reset_calls
if build_thermal_json invalid > "$TEST_ROOT/invalid.json"; then
    not_ok 'invalid thermal observation mode is rejected'
else
    ok 'invalid thermal observation mode is rejected'
fi
check_eq 'invalid mode never reaches Binder' 0 "$(count_calls dumpsys)"
check_eq 'invalid mode does not emit a successful JSON sample' 0 "$(wc -c < "$TEST_ROOT/invalid.json" | tr -d ' ')"

# Execute the real collector before any directories or parser fixtures exist.
# Safe standby entry must return before dependency, path, and state preparation.
for screen in off unknown doze absent; do
    reset_calls
    collector_mod="$TEST_ROOT/collector_$screen"
    collector_state="$TEST_ROOT/state_$screen"
    if [ "$screen" = absent ]; then
        PIXEL9PRO_MODDIR="$collector_mod" PIXEL9PRO_STATE_ROOT="$collector_state" \
            sh "$SOURCE_ROOT/scripts/power_rank_collect.sh"
    else
        PIXEL9PRO_MODDIR="$collector_mod" PIXEL9PRO_STATE_ROOT="$collector_state" \
            sh "$SOURCE_ROOT/scripts/power_rank_collect.sh" "$screen" doze
    fi
    check_eq "collector $screen is an inert successful exit" 0 "$?"
    check_eq "collector $screen performs no Binder dump" 0 "$(count_calls dumpsys)"
    check_absent "collector $screen creates no module state directory" "$collector_mod"
    check_absent "collector $screen creates no history state directory" "$collector_state"
done

for display in doze off; do
    reset_calls
    collector_mod="$TEST_ROOT/collector_contradiction_$display"
    collector_state="$TEST_ROOT/state_contradiction_$display"
    PIXEL9PRO_MODDIR="$collector_mod" PIXEL9PRO_STATE_ROOT="$collector_state" \
        sh "$SOURCE_ROOT/scripts/power_rank_collect.sh" on "$display"
    check_eq "collector rejects on plus $display without side effects" 0 "$?"
    check_eq "contradictory $display display makes no Binder dump" 0 "$(count_calls dumpsys)"
    check_absent "contradictory $display display creates no module state" "$collector_mod"
    check_absent "contradictory $display display creates no history state" "$collector_state"
done

collector_mod="$TEST_ROOT/collector_on"
collector_state="$TEST_ROOT/state_on"
mkdir -p "$collector_mod/scripts"
cp "$SOURCE_ROOT/scripts/power_rank_parse.awk" "$collector_mod/scripts/"
cp "$SOURCE_ROOT/scripts/system_history_parse.awk" "$collector_mod/scripts/"
reset_calls
PIXEL9PRO_MODDIR="$collector_mod" PIXEL9PRO_STATE_ROOT="$collector_state" \
    sh "$SOURCE_ROOT/scripts/power_rank_collect.sh" on interactive
check_eq 'interactive collector parses and commits real production snapshots' 0 "$?"
check_eq 'interactive collector performs two bounded dumps' 2 "$(count_calls dumpsys)"
check_eq 'each interactive dump uses the timeout contract' 2 "$(count_calls timeout)"
if [ -s "$collector_mod/.power_rank/last_collect_ts" ] && [ -s "$collector_state/system_history/receipt" ]; then
    ok 'interactive collector persists attribution and native history receipts'
else
    not_ok 'interactive collector persists attribution and native history receipts'
fi

collector_mod="$TEST_ROOT/collector_timeout"
collector_state="$TEST_ROOT/state_timeout"
mkdir -p "$collector_mod/scripts"
cp "$SOURCE_ROOT/scripts/power_rank_parse.awk" "$collector_mod/scripts/"
cp "$SOURCE_ROOT/scripts/system_history_parse.awk" "$collector_mod/scripts/"
reset_calls
STANDBY_TEST_TIMEOUT_FAIL=1 PIXEL9PRO_MODDIR="$collector_mod" PIXEL9PRO_STATE_ROOT="$collector_state" \
    sh "$SOURCE_ROOT/scripts/power_rank_collect.sh" on interactive
check_eq 'collector rejects the dump deadline failure' 7 "$?"
check_absent 'timed-out dump does not advance successful capture timestamp' "$collector_mod/.power_rank/last_collect_ts"
if awk -F= '$1 == "last_result" && $2 == "failed" { failed=1 } $1 == "last_success_ts" && $2 == "0" { empty=1 } END { exit failed && empty ? 0 : 1 }' \
    "$collector_state/system_history/receipt"; then
    ok 'dump deadline commits a failed receipt instead of a zero snapshot'
else
    not_ok 'dump deadline commits a failed receipt instead of a zero snapshot'
fi

PIXEL9PRO_MODDIR="$SOURCE_ROOT"
export PIXEL9PRO_MODDIR
. "$SOURCE_ROOT/scripts/telemetry_lib.sh" || exit 2
for TL_SCREEN in off unknown; do
    reset_calls
    # Stale severity must not leak into a fresh sysfs-only observation.
    TL_THERMAL_STATUS=5
    telemetry_read_thermal
    check_eq "telemetry $TL_SCREEN makes zero Binder dumps" 0 "$(count_calls dumpsys)"
    check_eq "telemetry $TL_SCREEN omits unobserved thermal severity" '' "$TL_THERMAL_STATUS"
    check_eq "telemetry $TL_SCREEN preserves measured battery" 31200 "$TL_BATTERY"
    check_eq "telemetry $TL_SCREEN omits unavailable virtual skin" '' "$TL_SKIN"
done
reset_calls
TL_SCREEN=on
telemetry_read_thermal
if [ "$(count_calls dumpsys)" -gt 0 ]; then
    ok 'interactive telemetry is permitted to observe Thermal HAL'
else
    not_ok 'interactive telemetry is permitted to observe Thermal HAL'
fi
check_eq 'interactive telemetry reuses one HAL dump for temperature and severity' 1 "$(count_calls dumpsys)"
check_eq 'interactive telemetry keeps actual virtual skin' 39125 "$TL_SKIN"
check_eq 'interactive telemetry keeps observed severity' 2 "$TL_THERMAL_STATUS"

# The start/end helper must independently refuse standby and never publish a
# successful aggregate file after a failed dump or an empty filtered result.
attribution_dir="$TEST_ROOT/attribution"
mkdir "$attribution_dir"
for TL_SCREEN in off unknown; do
    reset_calls
    if telemetry_capture_batterystats "$attribution_dir" start; then
        not_ok "attribution $TL_SCREEN rejects standby entry"
    else
        ok "attribution $TL_SCREEN rejects standby entry"
    fi
    check_eq "attribution $TL_SCREEN never reaches Binder" 0 "$(count_calls dumpsys)"
done
TL_SCREEN=on
for phase in start end; do
    reset_calls
    if telemetry_capture_batterystats "$attribution_dir" "$phase"; then
        ok "interactive attribution $phase commits verified aggregate"
    else
        not_ok "interactive attribution $phase commits verified aggregate"
    fi
    check_eq "attribution $phase uses one deadline" 1 "$(count_calls timeout)"
    if grep -q 'UID 1000' "$attribution_dir/batterystats_${phase}.txt" \
        && ! grep -q 'unretained' "$attribution_dir/batterystats_${phase}.txt"; then
        ok "attribution $phase retains only aggregate lines"
    else
        not_ok "attribution $phase retains only aggregate lines"
    fi
done
cp "$attribution_dir/batterystats_start.txt" "$TEST_ROOT/previous_attribution"
for fault in STANDBY_TEST_TIMEOUT_FAIL STANDBY_TEST_DUMP_FAIL STANDBY_TEST_DUMP_EMPTY; do
    reset_calls
    if (export "$fault=1"; telemetry_capture_batterystats "$attribution_dir" start); then
        not_ok "attribution rejects $fault instead of pipeline false success"
    else
        ok "attribution rejects $fault instead of pipeline false success"
    fi
    if cmp -s "$attribution_dir/batterystats_start.txt" "$TEST_ROOT/previous_attribution"; then
        ok "$fault preserves the previous verified aggregate"
    else
        not_ok "$fault preserves the previous verified aggregate"
    fi
    check_absent "$fault leaves no partial aggregate" "$attribution_dir/.batterystats_start.$$"
done

awk '/^cache_has_valid_skin\(\)/ { capture=1 } capture { print } capture && /^}$/ { exit }' \
    "$SOURCE_ROOT/webroot/cgi-bin/thermal.sh" > "$TEST_ROOT/cache_validator.sh"
. "$TEST_ROOT/cache_validator.sh"
printf '%s\n' '[{"zone":"soc_therm","temp":31200},{"zone":"VIRTUAL-SKIN","temp":-1000}]' > "$TEST_ROOT/invalid_skin.json"
printf '%s\n' '[{"zone":"soc_therm","temp":-1000},{"zone":"VIRTUAL-SKIN","temp":39125}]' > "$TEST_ROOT/valid_skin.json"
printf '%s\n' '[{"temp":39125,"zone":"VIRTUAL-SKIN"},{"zone":"battery","temp":31200}]' > "$TEST_ROOT/reordered_skin.json"
if cache_has_valid_skin "$TEST_ROOT/invalid_skin.json"; then
    not_ok 'cache rejects invalid skin even after a valid unrelated sensor'
else
    ok 'cache rejects invalid skin even after a valid unrelated sensor'
fi
if cache_has_valid_skin "$TEST_ROOT/valid_skin.json"; then
    ok 'cache accepts valid skin even after an invalid unrelated sensor'
else
    not_ok 'cache accepts valid skin even after an invalid unrelated sensor'
fi
if cache_has_valid_skin "$TEST_ROOT/reordered_skin.json"; then
    ok 'cache validator is independent of object field order'
else
    not_ok 'cache validator is independent of object field order'
fi

awk '/^ensure_profile_history_baseline\(\)/ { capture=1 } capture { print } capture && /^}$/ { exit }' \
    "$SOURCE_ROOT/service.sh" > "$TEST_ROOT/profile_baseline.sh"
for baseline_fault in 0 1; do
    reset_calls
    (
        MODDIR="$SOURCE_ROOT"
        THERMAL_CACHE="$TEST_ROOT/baseline_thermal.json"
        PROFILE_FILE="$TEST_ROOT/profile"
        STANDBY_TEST_TIMEOUT_FAIL="$baseline_fault"
        export STANDBY_TEST_TIMEOUT_FAIL
        profile_history_has_owner_field() { return 1; }
        profile_state_read_profile() { printf balanced; }
        runtime_write_value() { printf '%s' "$2" > "$1"; }
        append_profile_history() { printf '%s' "$_sev" > "$TEST_ROOT/baseline_severity"; }
        log() { :; }
        . "$TEST_ROOT/profile_baseline.sh"
        ensure_profile_history_baseline
    )
    expected_severity=2
    expected_dumps=1
    [ "$baseline_fault" = 0 ] || { expected_severity=-1; expected_dumps=0; }
    check_eq "baseline fault=$baseline_fault retains actual or unknown severity" "$expected_severity" "$(cat "$TEST_ROOT/baseline_severity")"
    check_eq "baseline fault=$baseline_fault uses exactly one bounded attempt" 1 "$(count_calls timeout)"
    check_eq "baseline fault=$baseline_fault avoids a second severity dump" "$expected_dumps" "$(count_calls dumpsys)"
done

# Exercise the actual auto-charging severity query and its failure fallback.
awk '/^                    _charging_thermal_dump=/ { capture=1 } capture { print } capture && /case "\$_sev"/ { exit }' \
    "$SOURCE_ROOT/service.sh" > "$TEST_ROOT/charging_severity.sh"
if [ -s "$TEST_ROOT/charging_severity.sh" ]; then
    for charging_fault in none timeout dump; do
        reset_calls
        STANDBY_TEST_TIMEOUT_FAIL=0
        STANDBY_TEST_DUMP_FAIL=0
        [ "$charging_fault" != timeout ] || STANDBY_TEST_TIMEOUT_FAIL=1
        [ "$charging_fault" != dump ] || STANDBY_TEST_DUMP_FAIL=1
        export STANDBY_TEST_TIMEOUT_FAIL STANDBY_TEST_DUMP_FAIL
        . "$TEST_ROOT/charging_severity.sh"
        expected_severity=2
        [ "$charging_fault" = none ] || expected_severity=-1
        check_eq "charging fault=$charging_fault uses a bounded severity query" 1 "$(count_calls timeout)"
        check_eq "charging fault=$charging_fault retains actual or unknown severity" "$expected_severity" "$_sev"
    done
    unset STANDBY_TEST_TIMEOUT_FAIL STANDBY_TEST_DUMP_FAIL
else
    not_ok 'fixture can locate production charging severity query'
fi

# Replay only the source-owned observation decisions and sleep call, with the
# expensive surrounding service lifecycle omitted. This verifies the consumers
# route to the tested production functions instead of duplicating their policy.
awk '/^            _thermal_source=/ { capture=1 } capture { print } capture && /_json=\$\(build_thermal_json/ { exit }' \
    "$SOURCE_ROOT/service.sh" > "$TEST_ROOT/service_thermal.sh"
awk '/^        _power_rank_interval_s=\$\(system_history_dispatch_interval/ { capture=1 } capture { print } capture && /^        fi$/ { exit }' \
    "$SOURCE_ROOT/service.sh" > "$TEST_ROOT/service_collect.sh"
if [ -s "$TEST_ROOT/service_thermal.sh" ] && [ -s "$TEST_ROOT/service_collect.sh" ]; then
    for _screen in off unknown on; do
        reset_calls
        . "$TEST_ROOT/service_thermal.sh"
        expected_calls=0
        [ "$_screen" = on ] && expected_calls=1
        check_eq "service $_screen thermal decision routes to the correct source" "$expected_calls" "$(count_calls dumpsys)"
        reset_calls
        (
            MODDIR="$SOURCE_ROOT"
            _now=900
            _power_rank_dispatch_at=0
            DISPLAY_STATE=interactive
            system_history_dispatch_interval() { printf 900; }
            sh() { printf 'dispatch\n' >> "$STANDBY_TEST_CALLS"; }
            . "$TEST_ROOT/service_collect.sh"
            wait
        )
        check_eq "service $_screen collector dispatch uses the interactive gate" "$expected_calls" "$(count_calls dispatch)"
    done
else
    not_ok 'fixture can locate production service observation decisions'
fi

sed -n '/^_tw_interval_on=/p;/^_tw_interval_off=/p' "$SOURCE_ROOT/scripts/telemetry_worker.sh" > "$TEST_ROOT/worker_constants.sh"
awk '/^    _tw_interval=/ { capture=1 } capture { print } capture && /^    sleep / { exit }' \
    "$SOURCE_ROOT/scripts/telemetry_worker.sh" > "$TEST_ROOT/worker_sleep.sh"
if [ -s "$TEST_ROOT/worker_constants.sh" ] && [ -s "$TEST_ROOT/worker_sleep.sh" ]; then
    for _tw_screen in off unknown on; do
        (
            . "$TEST_ROOT/worker_constants.sh"
            sleep() { printf '%s\n' "$1" > "$TEST_ROOT/observed_sleep"; }
            . "$TEST_ROOT/worker_sleep.sh"
        )
        expected_sleep=900
        [ "$_tw_screen" = on ] && expected_sleep=60
        check_eq "telemetry $_tw_screen actual sleep agrees with reported cadence" "$expected_sleep" "$(cat "$TEST_ROOT/observed_sleep")"
    done
else
    not_ok 'fixture can locate production telemetry sleep decision'
fi

printf '1..%s\n' "$((PASS + FAIL))"
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
