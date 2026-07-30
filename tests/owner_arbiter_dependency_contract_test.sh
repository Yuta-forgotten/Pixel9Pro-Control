#!/system/bin/sh

SOURCE_ROOT="${1:-${0%/tests/*}}"
TEST_ROOT="${2:-${TMPDIR:-/tmp}/pixel9pro_owner_dependencies_$$}"
PASS=0
FAIL=0
DEPENDENCIES='profile_state_lib.sh foreground_app_lib.sh owner_arbiter_state_lib.sh owner_arbiter_observation_lib.sh owner_arbiter_external_lib.sh owner_arbiter_cpufreq_lib.sh'
BASE_CONTRACTS='scheduler_detect_lib.sh scheduler_owner_lib.sh cpu_profile_lib.sh scheduler_boot_mode_lib.sh scheduler_transition_guard_lib.sh'

ok() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$((PASS + FAIL))" "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'not ok %s - %s\n' "$((PASS + FAIL))" "$1"; }

printf 'TAP version 13\n'
for missing in $DEPENDENCIES; do
    fixture="$TEST_ROOT/${missing%.sh}"
    mod="$fixture/mod"
    fas="$fixture/fas"
    mkdir -p "$mod/scripts" "$fas/.test_runtime" "$fas/cpufreq" || exit 2
    cp "$SOURCE_ROOT/scripts/owner_arbiter.sh" "$mod/scripts/" || exit 2
    for contract in $BASE_CONTRACTS $DEPENDENCIES; do
        [ "$contract" = "$missing" ] && continue
        cp "$SOURCE_ROOT/scripts/$contract" "$mod/scripts/" || exit 2
    done
    printf '0\n' > "$fas/uclamp_cap"
    output=$(OWNER_ARBITER_TEST_MODE=1 \
        OWNER_ARBITER_FAS_ROOT="$fas" \
        OWNER_ARBITER_CPUFREQ_ROOT="$fas/cpufreq" \
        OWNER_ARBITER_UCLAMP_CAP_PATH="$fas/uclamp_cap" \
        sh "$mod/scripts/owner_arbiter.sh" tick "$mod" on 2>&1)
    rc=$?
    case "$rc:$output" in
        65:*"missing internal contract $missing"*) ok "缺少 $missing 时 fail closed" ;;
        *) not_ok "缺少 $missing 时返回异常不明确 rc=$rc output=$output" ;;
    esac
done

printf '1..%s\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
