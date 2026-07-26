#!/system/bin/sh

SOURCE_ROOT="${1:-${0%/tests/*}}"
TEST_ROOT="${2:-${TMPDIR:-/tmp}/pixel9pro_nr_mode_$$}"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$((PASS + FAIL))" "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'not ok %s - %s\n' "$((PASS + FAIL))" "$1"; }
check_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 (expected=$2 actual=$3)"; fi
}

mkdir -p "$TEST_ROOT" || exit 2
. "$SOURCE_ROOT/scripts/runtime_defaults_lib.sh" || exit 2
. "$SOURCE_ROOT/scripts/nr_mode_lib.sh" || exit 2

MOCK_MODE_FILE="$TEST_ROOT/mode"
runtime_android_settings() {
    case "$1:$2" in
        get:global) cat "$MOCK_MODE_FILE" 2>/dev/null || printf 'null\n' ;;
        put:global)
            [ "${NR_TEST_FAIL_PUT:-0}" = "0" ] || return 1
            printf '%s' "$4" > "$MOCK_MODE_FILE"
            ;;
        *) return 1 ;;
    esac
}

printf 'TAP version 13\n'
check_eq 'reads DSDS slot 0' 33 "$(nr_mode_slot0 '33,11')"
check_eq 'replaces DSDS slot 0 only' '9,11' "$(nr_mode_replace_slot0 '33,11' 9)"
if nr_mode_is_nr_capable '33,11'; then ok 'accepts NR-capable slot 0'; else not_ok 'accepts NR-capable slot 0'; fi
if nr_mode_is_nr_capable '11,33'; then not_ok 'rejects LTE slot 0'; else ok 'rejects LTE slot 0'; fi
if nr_mode_is_valid_raw '33,11,9'; then not_ok 'rejects more than two slots'; else ok 'rejects more than two slots'; fi
if nr_mode_is_valid_raw '-1'; then not_ok 'rejects negative mode'; else ok 'rejects negative mode'; fi

printf '33,11' > "$MOCK_MODE_FILE"
if nr_mode_write_verified preferred_network_mode1 '9,11'; then ok 'verified write succeeds'; else not_ok 'verified write succeeds'; fi
check_eq 'verified write preserves slot 1' '9,11' "$(cat "$MOCK_MODE_FILE")"

printf '33,11' > "$MOCK_MODE_FILE"
NR_TEST_FAIL_PUT=1
if nr_mode_write_verified preferred_network_mode1 '9,11'; then not_ok 'failed Settings write is rejected'; else ok 'failed Settings write is rejected'; fi
check_eq 'failed Settings write preserves prior mode' '33,11' "$(cat "$MOCK_MODE_FILE")"

saved="$TEST_ROOT/saved"
if nr_mode_save_current "$saved" '33,11'; then ok 'persists verified restore mode'; else not_ok 'persists verified restore mode'; fi
check_eq 'saved restore mode retains DSDS tuple' '33,11' "$(cat "$saved")"

printf '1..%s\n' "$((PASS + FAIL))"
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
