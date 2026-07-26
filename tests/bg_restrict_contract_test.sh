#!/system/bin/sh

MOD="${1:-${0%/tests/*}}"
TEST_ROOT="${2:-/sdcard/Download/Pixel9Pro-Control-TestLab/runtime/bg_restrict_contract}"
MODDIR="$TEST_ROOT/module"
BG_ENABLED_FILE="$MODDIR/.bg_restrict_enabled"
BG_LIST_FILE="$MODDIR/.bg_restrict_list"
BG_BASELINE_FILE="$MODDIR/.bg_restrict_baseline"
BG_STOP_STATE_FILE="$MODDIR/.bg_restrict_stop_state"

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$((PASS + FAIL))" "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'not ok %s - %s\n' "$((PASS + FAIL))" "$1"; }

assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 (expected=$2 actual=$3)"; fi
}

assert_file() {
    if [ -e "$2" ]; then ok "$1"; else not_ok "$1"; fi
}

assert_empty_file() {
    if [ ! -s "$2" ]; then ok "$1"; else not_ok "$1"; fi
}

MOCK_BUCKET=active
MOCK_OP_BG=allow
MOCK_OP_ANY=allow
MOCK_FAIL_BUCKET_SET=0
MOCK_FAIL_BG_SET=0
MOCK_FAIL_ANY_SET=0

am() {
    case "$1:$2" in
        get-standby-bucket:*) printf '%s\n' "$MOCK_BUCKET" ;;
        set-standby-bucket:*)
            [ "$MOCK_FAIL_BUCKET_SET" -eq 0 ] || return 1
            MOCK_BUCKET="$3"
            ;;
        *) return 1 ;;
    esac
}

cmd() {
    [ "$1" = "appops" ] || return 1
    case "$2" in
        get)
            case "$4" in
                RUN_IN_BACKGROUND) printf '%s: %s\n' "$4" "$MOCK_OP_BG" ;;
                RUN_ANY_IN_BACKGROUND) printf '%s: %s\n' "$4" "$MOCK_OP_ANY" ;;
                *) return 1 ;;
            esac
            ;;
        set)
            case "$4" in
                RUN_IN_BACKGROUND)
                    [ "$MOCK_FAIL_BG_SET" -eq 0 ] || return 1
                    MOCK_OP_BG="$5"
                    ;;
                RUN_ANY_IN_BACKGROUND)
                    [ "$MOCK_FAIL_ANY_SET" -eq 0 ] || return 1
                    MOCK_OP_ANY="$5"
                    ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

mkdir -p "$MODDIR" || exit 2
. "$MOD/scripts/bg_restrict_lib.sh" || exit 2

PKG=com.example.app
printf '%s\n' "$PKG|block_all|5" > "$BG_LIST_FILE"

if bg_apply_policy "$PKG" block_all; then ok 'block_all applies'; else not_ok 'block_all applies'; fi
assert_eq 'restricted bucket applied' restricted "$MOCK_BUCKET"
assert_eq 'RUN_IN_BACKGROUND ignored' ignore "$MOCK_OP_BG"
assert_eq 'RUN_ANY_IN_BACKGROUND ignored' ignore "$MOCK_OP_ANY"
assert_file 'baseline retained after apply' "$BG_BASELINE_FILE"

MOCK_FAIL_ANY_SET=1
if bg_remove_restrict "$PKG"; then not_ok 'failed restore returns nonzero'; else ok 'failed restore returns nonzero'; fi
assert_file 'failed restore keeps baseline' "$BG_BASELINE_FILE"

MOCK_FAIL_ANY_SET=0
if bg_remove_restrict "$PKG"; then ok 'baseline restore succeeds'; else not_ok 'baseline restore succeeds'; fi
assert_eq 'bucket restored' active "$MOCK_BUCKET"
assert_eq 'RUN_IN_BACKGROUND restored' allow "$MOCK_OP_BG"
assert_eq 'RUN_ANY_IN_BACKGROUND restored' allow "$MOCK_OP_ANY"
assert_empty_file 'successful restore removes baseline entry' "$BG_BASELINE_FILE"

MOCK_FAIL_BG_SET=1
if bg_apply_all; then not_ok 'aggregate apply reports command failure'; else ok 'aggregate apply reports command failure'; fi
assert_file 'failed aggregate apply keeps rollback baseline' "$BG_BASELINE_FILE"

printf '1..%s\n' "$((PASS + FAIL))"
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
