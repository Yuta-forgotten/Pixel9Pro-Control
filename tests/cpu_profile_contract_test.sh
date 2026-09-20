#!/system/bin/sh

SOURCE_ROOT="$1"
LIB="$SOURCE_ROOT/scripts/cpu_profile_lib.sh"
PASS=0
FAIL=0
TOTAL=0

check_eq() {
    TOTAL=$((TOTAL + 1))
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
        printf 'ok %s - %s\n' "$TOTAL" "$1"
    else
        FAIL=$((FAIL + 1))
        printf 'not ok %s - %s expected=%s actual=%s\n' "$TOTAL" "$1" "$2" "$3"
    fi
}

. "$LIB" || exit 2
printf 'TAP version 13\n'

check_eq 'legacy light normalizes to balanced' balanced "$(cpu_profile_normalize_runtime light default)"
check_eq 'legacy responsive normalizes to performance' performance "$(cpu_profile_normalize_runtime responsive default)"
check_eq 'invalid profile uses fallback' default "$(cpu_profile_normalize_runtime invalid default)"
check_eq 'performance response' '12 20 80' "$(cpu_profile_response_triplet performance)"
check_eq 'balanced response' '16 64 240' "$(cpu_profile_response_triplet balanced)"
check_eq 'battery response' '16 96 320' "$(cpu_profile_response_triplet battery)"
check_eq 'default response is dynamic' '' "$(cpu_profile_response_triplet default)"
check_eq 'default full cap' 1024 "$(cpu_profile_uclamp_cap default)"
check_eq 'balanced eco cap' 0 "$(cpu_profile_uclamp_cap balanced)"
check_eq 'balanced excludes prime CPU for daily use' 0-6 "$(cpu_profile_top_app_cpus balanced)"
check_eq 'battery excludes prime CPU' 0-6 "$(cpu_profile_top_app_cpus battery)"
check_eq 'balanced L2 params' '200 100' "$(cpu_power_profile_l2_params balanced)"
check_eq 'battery L2 params' '150 80' "$(cpu_power_profile_l2_params battery)"
check_eq 'default restores stock L2 params' '1024 308' "$(cpu_profile_l2_params default)"
check_eq 'foreground is observation-only' framework "$(cpu_profile_owner foreground_cpus)"
check_eq 'top-app is best-effort' pixel_best_effort "$(cpu_profile_owner top_app_cpus)"
check_eq 'background is transaction-owned' pixel_transaction "$(cpu_profile_owner background_cpus)"
check_eq 'writeback policy is observe after one apply' apply_verify_once_then_observe "$CPU_PROFILE_WRITEBACK_POLICY"
check_eq 'health interval is 300 seconds' 300 "$CPU_PROFILE_HEALTH_INTERVAL_S"
check_eq 'discharge hot gate' 38800 "$CPU_PROFILE_AUTO_DISCHARGE_HOT_TEMP_MC"
check_eq 'discharge cool gate' 37500 "$CPU_PROFILE_AUTO_DISCHARGE_COOL_TEMP_MC"
check_eq 'charging hot gate' 39800 "$CPU_PROFILE_AUTO_CHARGING_HOT_TEMP_MC"
_contract_json=$(cpu_profile_contract_json)
case "$_contract_json" in
    \{*\}) check_eq 'JSON contract emits an object for the structured host parser' yes yes ;;
    *) check_eq 'JSON contract emits an object for the structured host parser' yes no ;;
esac

printf '1..%s\n' "$TOTAL"
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
