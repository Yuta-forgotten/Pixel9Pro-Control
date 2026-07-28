#!/system/bin/sh

SOURCE_ROOT="${1:-/sdcard/Download/Pixel9Pro-Control-TestLab/candidate/control}"
PASS=0
FAIL=0
TOTAL=0

ok() { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$TOTAL" "$1"; }
not_ok() { TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); printf 'not ok %s - %s\n' "$TOTAL" "$1"; }
assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 expected=$2 actual=$3"; fi
}

. "$SOURCE_ROOT/scripts/display_state_lib.sh" || exit 2
printf 'TAP version 13\n'

display_state_classify true Awake enabled
assert_eq 'interactive screen wins over DRM' interactive "$DISPLAY_STATE"
assert_eq 'interactive flag is yes' yes "$DISPLAY_STATE_INTERACTIVE"

display_state_classify false Dozing enabled
assert_eq 'AOD is classified as doze' doze "$DISPLAY_STATE"
assert_eq 'AOD is noninteractive' no "$DISPLAY_STATE_INTERACTIVE"

display_state_classify false Asleep disabled
assert_eq 'asleep display is off' off "$DISPLAY_STATE"

display_state_classify false '' enabled
assert_eq 'deviceidle false plus enabled encoder is doze' doze "$DISPLAY_STATE"

if display_state_classify '' '' enabled; then
    not_ok 'DRM enabled alone must not prove interactive'
else
    ok 'DRM enabled alone must not prove interactive'
fi
assert_eq 'ambiguous enabled encoder stays unknown' unknown "$DISPLAY_STATE"

display_state_classify '' '' disabled
assert_eq 'DRM disabled is a safe off fallback' off "$DISPLAY_STATE"

DISPLAY_STATE_TEST_MODE=1
DISPLAY_STATE_TEST_SCREEN=false
DISPLAY_STATE_TEST_WAKEFULNESS=Dozing
DISPLAY_STATE_TEST_DRM=enabled
display_state_read
assert_eq 'test reader preserves AOD classification' doze "$DISPLAY_STATE"
assert_eq 'legacy AOD screen is off' off "$(display_state_legacy_screen)"

printf '1..%s\n' "$TOTAL"
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
