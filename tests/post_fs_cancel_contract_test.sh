#!/bin/sh
set -eu

SOURCE_ROOT="${1:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
TEST_ROOT="${2:-${TMPDIR:-/tmp}/pixel9pro_post_fs_cancel_$$}"
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$((PASS + FAIL))" "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'not ok %s - %s\n' "$((PASS + FAIL))" "$1"; }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 (expected=$2 actual=$3)"; fi; }

rm -rf "$TEST_ROOT" 2>/dev/null || true
mkdir -p "$TEST_ROOT/module/system/vendor/etc" "$TEST_ROOT/module/scripts" "$TEST_ROOT/bin" || exit 2
cp "$SOURCE_ROOT/scripts/slot_transaction_lib.sh" "$TEST_ROOT/module/scripts/"
cp "$SOURCE_ROOT/scripts/thermal_profile.sh" "$TEST_ROOT/module/scripts/"
cp "$SOURCE_ROOT/post-fs-data.sh" "$TEST_ROOT/module/"
cat > "$TEST_ROOT/bin/log" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TEST_ROOT/bin/log"
export PATH="$TEST_ROOT/bin:$PATH"

prepare_pending() {
    _case_root="$1"
    rm -rf "$_case_root" 2>/dev/null || true
    mkdir -p "$_case_root/module/system/vendor/etc" "$_case_root/module/scripts" "$_case_root/bin"
    cp "$SOURCE_ROOT/scripts/slot_transaction_lib.sh" "$_case_root/module/scripts/"
    cp "$SOURCE_ROOT/scripts/thermal_profile.sh" "$_case_root/module/scripts/"
    cp "$SOURCE_ROOT/post-fs-data.sh" "$_case_root/module/"
    cp "$TEST_ROOT/bin/log" "$_case_root/bin/"
    export PATH="$_case_root/bin:$PATH"
    export PIXEL9PRO_MODDIR="$_case_root/module"
    export PIXEL9PRO_SLOT_ROOT="$_case_root/slots"
    printf 'old-config' > "$_case_root/module/system/vendor/etc/thermal_info_config.json"
    printf custom > "$_case_root/module/.thermal_policy"
    printf 4 > "$_case_root/module/.thermal_offset"
    . "$SOURCE_ROOT/scripts/slot_transaction_lib.sh"
    slot_init
    slot_atomic_write "$PIXEL9PRO_SLOT_ROOT/thermal/active" slot-a
    mkdir -p "$PIXEL9PRO_SLOT_ROOT/thermal/slot-a"
    printf 'component=thermal\nslot=slot-a\nmode=staged\nhash=old\n' > "$PIXEL9PRO_SLOT_ROOT/thermal/slot-a/manifest"
    printf 'new-config' > "$_case_root/new-config"
    slot_stage_file thermal "$_case_root/new-config" system/vendor/etc/thermal_info_config.json staged caiman test-build vendor_configs_file
    _pending_id=$(slot_pending_id thermal)
    slot_atomic_write "$PIXEL9PRO_SLOT_ROOT/thermal/previous_state" \
        "$(printf 'phase=cancel_requested\npolicy=custom\noffset=4\nboot_id=test-boot\npending_id=%s' "$_pending_id")"
}

CASE_MATCH="$TEST_ROOT/match"
prepare_pending "$CASE_MATCH"
sh "$CASE_MATCH/module/post-fs-data.sh"
assert_eq 'matching cancel marker removes pending slot' '' "$(cat "$CASE_MATCH/slots/thermal/pending" 2>/dev/null || true)"
assert_eq 'matching cancel marker restores policy' custom "$(cat "$CASE_MATCH/module/.thermal_policy")"
assert_eq 'matching cancel marker restores offset' 4 "$(cat "$CASE_MATCH/module/.thermal_offset")"
if [ ! -e "$CASE_MATCH/slots/thermal/previous_state" ]; then ok 'matching cancel marker is consumed'; else not_ok 'matching cancel marker is consumed'; fi

CASE_MISMATCH="$TEST_ROOT/mismatch"
prepare_pending "$CASE_MISMATCH"
slot_atomic_write "$CASE_MISMATCH/slots/thermal/previous_state" \
    "$(printf '%s\n' 'phase=cancel_requested' 'policy=custom' 'offset=4' 'boot_id=test-boot' 'pending_id=thermal:slot-b:wrong:hash')"
sh "$CASE_MISMATCH/module/post-fs-data.sh"
if [ -n "$(cat "$CASE_MISMATCH/slots/thermal/pending" 2>/dev/null || true)" ] \
    && [ -e "$CASE_MISMATCH/slots/thermal/previous_state" ]; then
    ok 'mismatched cancel marker preserves pending transaction'
else
    not_ok 'mismatched cancel marker preserves pending transaction'
fi
assert_eq 'mismatched cancel marker does not promote source' old-config "$(cat "$CASE_MISMATCH/module/system/vendor/etc/thermal_info_config.json")"

CASE_INVALID="$TEST_ROOT/invalid"
prepare_pending "$CASE_INVALID"
slot_atomic_write "$CASE_INVALID/slots/thermal/previous_state" \
    "$(printf 'phase=cancel_requested\npolicy=invalid\noffset=garbage\nboot_id=test-boot\npending_id=%s' "$(slot_pending_id thermal)")"
sh "$CASE_INVALID/module/post-fs-data.sh"
if [ -n "$(cat "$CASE_INVALID/slots/thermal/pending" 2>/dev/null || true)" ] \
    && [ -e "$CASE_INVALID/slots/thermal/previous_state" ]; then
    ok 'invalid cancel marker remains fail-closed'
else
    not_ok 'invalid cancel marker remains fail-closed'
fi
assert_eq 'invalid cancel marker does not overwrite policy' custom "$(cat "$CASE_INVALID/module/.thermal_policy")"

printf '1..%s\n' "$((PASS + FAIL))"
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
