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

check_contains() {
    TOTAL=$((TOTAL + 1))
    case "$2" in
        *"$3"*) PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$TOTAL" "$1" ;;
        *) FAIL=$((FAIL + 1)); printf 'not ok %s - %s missing=%s\n' "$TOTAL" "$1" "$3" ;;
    esac
}

. "$LIB" || exit 2
printf 'TAP version 13\n'

check_eq 'legacy light normalizes to balanced' balanced "$(cpu_profile_normalize_runtime light default)"
check_eq 'legacy responsive normalizes to performance' performance "$(cpu_profile_normalize_runtime responsive default)"
check_eq 'invalid profile uses fallback' default "$(cpu_profile_normalize_runtime invalid default)"
check_eq 'performance response' '12 20 80' "$(cpu_profile_response_triplet performance)"
check_eq 'balanced response' '16 40 200' "$(cpu_profile_response_triplet balanced)"
check_eq 'battery response' '32 96 200' "$(cpu_profile_response_triplet battery)"
check_eq 'default response is dynamic' '' "$(cpu_profile_response_triplet default)"
check_eq 'default full cap' 1024 "$(cpu_profile_uclamp_cap default)"
check_eq 'balanced eco cap' 0 "$(cpu_profile_uclamp_cap balanced)"
check_eq 'battery excludes prime CPU' 0-6 "$(cpu_profile_top_app_cpus battery)"
check_eq 'balanced L2 params' '200 100' "$(cpu_power_profile_l2_params balanced)"
check_eq 'battery L2 params' '150 80' "$(cpu_power_profile_l2_params battery)"
check_eq 'default restores stock L2 params' '1024 308' "$(cpu_profile_l2_params default)"
_contract_json=$(cpu_profile_contract_json)
check_contains 'JSON contract exposes balanced runtime values' "$_contract_json" \
    '"balanced":{"response_ms":[16,40,200],"uclamp_cap":0,"top_app_cpus":"0-7","bg_uclamp_max":200,"bg_group_throttle":100}'
check_contains 'JSON contract keeps default response dynamic' "$_contract_json" \
    '"default":{"response_ms":null,"uclamp_cap":1024,"top_app_cpus":"0-7","bg_uclamp_max":1024,"bg_group_throttle":308}'

printf '1..%s\n' "$TOTAL"
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
