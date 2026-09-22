#!/system/bin/sh
set -eu

SOURCE_ROOT="${1:-$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)}"
TEST_ROOT="${2:-/tmp/pixel9pro_slot_contract_$$}"
rm -f "$TEST_ROOT"/* 2>/dev/null || true
rmdir "$TEST_ROOT" 2>/dev/null || true
mkdir -p "$TEST_ROOT"
trap 'rm -f "$TEST_ROOT"/* "$TEST_ROOT/"*/payload "$TEST_ROOT/"*/manifest 2>/dev/null || true; rmdir "$TEST_ROOT"/* "$TEST_ROOT" 2>/dev/null || true' EXIT

export PIXEL9PRO_SLOT_ROOT="$TEST_ROOT/slots"
. "$SOURCE_ROOT/scripts/slot_transaction_lib.sh"
slot_init
printf candidate > "$TEST_ROOT/source.bin"
slot_stage_file uecap "$TEST_ROOT/source.bin" system/vendor/firmware/x.binarypb staged caiman test-build vendor_fw_file
test "$(slot_pending_value uecap)" = slot-a
test -n "$(slot_pending_id uecap)"
slot_promote_pending uecap "$TEST_ROOT/target.bin"
test "$(cat "$TEST_ROOT/target.bin")" = candidate
slot_mark_verified uecap
test "$(cat "$TEST_ROOT/slots/uecap/last-good")" = slot-a
slot_stage_file uecap "$TEST_ROOT/source.bin" system/vendor/firmware/x.binarypb remove caiman test-build vendor_fw_file
slot_promote_pending uecap "$TEST_ROOT/target.bin"
test ! -e "$TEST_ROOT/target.bin"
slot_stage_file uecap "$TEST_ROOT/source.bin" system/vendor/firmware/x.binarypb staged caiman test-build vendor_fw_file
test "$(slot_pending_value uecap)" = slot-a
slot_cancel_pending uecap
test -z "$(slot_pending_value uecap)"
test -f "$TEST_ROOT/slots/uecap/slot-b/manifest"
printf '%s\n' 'PASS: A/B pending slot promotion and last-good contract'
