#!/system/bin/sh

SOURCE_ROOT="${1:-${0%/tests/*}}"
TEST_ROOT="${2:-${TMPDIR:-/tmp}/pixel9pro_foreground_app_$$}"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$((PASS + FAIL))" "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'not ok %s - %s\n' "$((PASS + FAIL))" "$1"; }
assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 expected=$2 actual=$3"; fi
}

WINDOW_DUMP=""
ACTIVITY_DUMP=""
dumpsys() {
    case "$1:$2" in
        window:) printf '%s\n' "$WINDOW_DUMP" ;;
        activity:top) printf '%s\n' "$ACTIVITY_DUMP" ;;
        *) return 1 ;;
    esac
}

. "$SOURCE_ROOT/scripts/foreground_app_lib.sh" || exit 2
mkdir -p "$TEST_ROOT" || exit 2
printf 'TAP version 13\n'

WINDOW_DUMP='mCurrentFocus=Window{1 u0 com.example.secondary/.Main}
mFocusedApp=ActivityRecord{2 u0 com.example.primary/.Game t1}
NotificationShade'
ACTIVITY_DUMP='  ACTIVITY com.example.fallback/.Main 1 pid=1'
assert_eq '优先采用 mFocusedApp' com.example.primary "$(foreground_package_name)"

WINDOW_DUMP='mFocusedApp=ActivityRecord{overlay only}
mCurrentFocus=Window{1 u0 com.example.current/.Main}'
assert_eq '跳过无法解析的瞬态 overlay' com.example.current "$(foreground_package_name)"

WINDOW_DUMP='NotificationShade'
ACTIVITY_DUMP='  ACTIVITY com.example.fallback/.Main 1 pid=1'
assert_eq 'WindowManager 无结果时回退 ActivityTaskManager' com.example.fallback "$(foreground_package_name)"

COUNTER="$TEST_ROOT/counter"
OWNER_ARBITER_TEST_MODE=1
OWNER_ARBITER_TEST_FOCUS_PKG=com.example.fixture
OWNER_ARBITER_TEST_FOREGROUND_COUNTER_PATH="$COUNTER"
assert_eq '测试模式返回注入包名' com.example.fixture "$(foreground_package_name)"
assert_eq '测试模式记录调用次数' 1 "$(cat "$COUNTER" 2>/dev/null)"
rm -f "$COUNTER"

printf '1..%s\n' "$((PASS + FAIL))"
[ "$FAIL" -eq 0 ]
