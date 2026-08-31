#!/system/bin/sh

# Host-side contract test for the read-only standalone baseband status view.
# It never touches Android state, /data, MetaModule, or a real module tree.

if [ -x /system/bin/sh ]; then
    printf '1..0 # SKIP host-only baseband status fixture\n'
    exit 0
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE_ROOT="${1:-$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)}"
TEST_ROOT="${2:-${TMPDIR:-/tmp}/pixel9pro_baseband_status_$$}"
FIXTURE="$TEST_ROOT/module"
ACTIVE_ROOT="$TEST_ROOT/active"
UPDATE_ROOT="$TEST_ROOT/update"
MOCK_BIN="$TEST_ROOT/bin"
STATUS_SCRIPT="$SOURCE_ROOT/webroot/cgi-bin/_baseband_status.sh"
COMMON_SCRIPT="$SOURCE_ROOT/webroot/cgi-bin/_common.sh"
PASS=0
FAIL=0

ok() {
    PASS=$((PASS + 1))
    printf 'ok %s - %s\n' "$((PASS + FAIL))" "$1"
}

not_ok() {
    FAIL=$((FAIL + 1))
    printf 'not ok %s - %s\n' "$((PASS + FAIL))" "$1"
}

assert_eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1 (expected=$2 actual=$3)"; fi
}

assert_json_value() {
    _status_label="$1"
    _status_file="$2"
    _status_key="$3"
    _status_expected="$4"
    _status_actual=$(python3 - "$_status_file" "$_status_key" <<'PY'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as handle:
    value = json.load(handle)
for part in sys.argv[2].split('.'):
    value = value[part]
if isinstance(value, bool):
    print('true' if value else 'false')
elif value is None:
    print('null')
else:
    print(value)
PY
    )
    assert_eq "$_status_label" "$_status_expected" "$_status_actual"
}

assert_json_schema() {
    _status_label="$1"
    _status_file="$2"
    if python3 - "$_status_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding='utf-8') as handle:
    data = json.load(handle)

top_level = {
    'installed', 'enabled', 'runtime_verified', 'module_dir',
    'module_dir_state', 'module_state', 'source', 'root_impl', 'version',
    'version_code', 'description', 'runtime_status', 'status_schema', 'mount_observed',
    'effective_overlay_verified', 'source_contract_verified',
    'content_image_verified', 'effective_contract_verified', 'effective_extra_files_allowed',
    'migration_state', 'source_path', 'effective_path', 'content_image',
    'source_hash', 'source_contract_hash', 'effective_hash', 'effective_contract_hash',
    'content_image_hash', 'content_contract_hash', 'source_tree_hash', 'content_tree_hash',
    'clean_reinstall_required', 'pending_update',
    'pending_update_dir', 'runtime_receipt_freshness',
    'prior_receipt_freshness', 'current_runtime_check_freshness', 'boot_id',
    'errors', 'carrier_settings', 'mcfg', 'props',
}
nested = {
    'carrier_settings': {'installed', 'count', 'carrier_list_sha256'},
    'mcfg': {'installed', 'count'},
    'props': {'volte_avail_ovr', 'wfc_avail_ovr', 'vt_avail_ovr', 'apns_conf_sha256'},
}
missing = sorted(top_level - set(data))
wrong = sorted(key for key, fields in nested.items()
               if not isinstance(data.get(key), dict) or fields - set(data[key]))
if missing or wrong:
    raise SystemExit(f'missing={missing} wrong={wrong}')
PY
    then
        ok "$_status_label"
    else
        not_ok "$_status_label"
    fi
}

mkdir -p "$FIXTURE" "$ACTIVE_ROOT" "$UPDATE_ROOT" "$MOCK_BIN" || exit 2
cp "$COMMON_SCRIPT" "$FIXTURE/_common.sh" || exit 2
cp "$STATUS_SCRIPT" "$FIXTURE/_baseband_status.sh" || exit 2

cat > "$MOCK_BIN/getprop" <<'EOF'
#!/bin/sh
case "$1" in
    persist.dbg.volte_avail_ovr|persist.dbg.wfc_avail_ovr|persist.dbg.vt_avail_ovr) printf '1\n' ;;
    *) printf '\n' ;;
esac
EOF
chmod +x "$MOCK_BIN/getprop" || exit 2

make_module() {
    _status_root="$1"
    _status_version="$2"
    mkdir -p "$_status_root/pixel9pro_baseband_trial" || exit 2
    cat > "$_status_root/pixel9pro_baseband_trial/module.prop" <<EOF
id=pixel9pro_baseband_trial
version=$_status_version
versionCode=112
description=fixture baseband
EOF
}

write_receipt() {
    _status_path="$1"
    _status_status="$2"
    _status_effective="$3"
    _status_freshness="$4"
    _status_clean="$5"
    _status_errors="$6"
    cat > "$_status_path" <<EOF
schema=3
status=$_status_status
root_impl=APatch
module_dir=/active/pixel9pro_baseband_trial
content_image=/metamodule/content.img
source_path=/active/pixel9pro_baseband_trial/system
effective_path=/product,/vendor
source_hash=source-hash
source_contract_hash=source-contract-hash
effective_hash=effective-hash
effective_contract_hash=effective-contract-hash
content_image_hash=content-hash
content_contract_hash=content-contract-hash
source_tree_hash=tree-hash
content_tree_hash=tree-hash
source_contract_verified=yes
content_image_verified=yes
effective_contract_verified=yes
effective_extra_files_allowed=yes
mount_observed=yes
effective_overlay_verified=$_status_effective
migration_state=effective_overlay_verified
runtime_receipt_freshness=$_status_freshness
prior_receipt_freshness=current_boot_verified
current_runtime_check_freshness=$_status_freshness
boot_id=test-boot
clean_reinstall_required=$_status_clean
carrier_settings_files=3210
china_mcfg_files=5
carrier_list_sha256=carrier-hash
apns_conf_sha256=apn-hash
errors=$_status_errors
EOF
}

run_status() {
    _status_output="$TEST_ROOT/current.json"
    env PATH="$MOCK_BIN:$PATH" \
        MODDIR="$FIXTURE" \
        PIXEL9PRO_MODDIR="$FIXTURE" \
        BASEBAND_STATUS_ACTIVE_ROOT="$ACTIVE_ROOT" \
        BASEBAND_STATUS_UPDATE_ROOT="$UPDATE_ROOT" \
        sh -c '. "$1/_common.sh"; . "$1/_baseband_status.sh"; baseband_status_emit_json' sh "$FIXTURE" > "$_status_output" || return 1
    python3 - "$_status_output" <<'PY'
import json
import sys
with open(sys.argv[1], encoding='utf-8') as handle:
    json.load(handle)
PY
}

command -v python3 >/dev/null 2>&1 || {
    printf 'baseband status contract test requires python3 JSON parser\n' >&2
    exit 2
}

run_status || exit 2
assert_json_schema 'missing module keeps a stable JSON schema' "$TEST_ROOT/current.json"
assert_json_value 'missing module is not installed' "$TEST_ROOT/current.json" installed false
assert_json_value 'missing module does not request clean reinstall' "$TEST_ROOT/current.json" clean_reinstall_required false
assert_json_value 'missing module reports no pending update' "$TEST_ROOT/current.json" pending_update false
assert_json_value 'missing module error is explicit' "$TEST_ROOT/current.json" errors module_missing

make_module "$ACTIVE_ROOT" v1.1.0-active
make_module "$UPDATE_ROOT" v1.1.0-pending
run_status || exit 2
assert_json_schema 'active module keeps a stable JSON schema' "$TEST_ROOT/current.json"
assert_json_value 'active module wins over pending update' "$TEST_ROOT/current.json" source active
assert_json_value 'active module directory state is explicit' "$TEST_ROOT/current.json" module_dir_state active
assert_json_value 'pending update is reported separately' "$TEST_ROOT/current.json" pending_update true
assert_json_value 'pending update path is exposed' "$TEST_ROOT/current.json" pending_update_dir "$UPDATE_ROOT/pixel9pro_baseband_trial"
assert_json_value 'pending update does not replace active version' "$TEST_ROOT/current.json" version v1.1.0-active
assert_json_value 'missing active receipt requests clean reinstall' "$TEST_ROOT/current.json" clean_reinstall_required true
assert_json_value 'missing active receipt is not runtime verified' "$TEST_ROOT/current.json" runtime_verified false
assert_json_value 'missing active receipt has explicit error' "$TEST_ROOT/current.json" errors runtime_receipt_missing

write_receipt "$ACTIVE_ROOT/pixel9pro_baseband_trial/.runtime_status" PASS yes current_check no none
run_status || exit 2
assert_json_value 'PASS receipt marks runtime verified' "$TEST_ROOT/current.json" runtime_verified true
assert_json_value 'PASS receipt keeps active source' "$TEST_ROOT/current.json" source active
assert_json_value 'PASS receipt does not request clean reinstall' "$TEST_ROOT/current.json" clean_reinstall_required false
assert_json_value 'PASS receipt exposes source hash' "$TEST_ROOT/current.json" source_hash source-hash
assert_json_value 'PASS receipt exposes source contract hash' "$TEST_ROOT/current.json" source_contract_hash source-contract-hash
assert_json_value 'PASS receipt exposes effective hash' "$TEST_ROOT/current.json" effective_hash effective-hash
assert_json_value 'PASS receipt exposes effective contract hash' "$TEST_ROOT/current.json" effective_contract_hash effective-contract-hash
assert_json_value 'PASS receipt exposes content image hash' "$TEST_ROOT/current.json" content_image_hash content-hash
assert_json_value 'PASS receipt exposes content contract hash' "$TEST_ROOT/current.json" content_contract_hash content-contract-hash
assert_json_value 'PASS receipt exposes schema 3' "$TEST_ROOT/current.json" status_schema 3
assert_json_value 'PASS receipt exposes carrier count' "$TEST_ROOT/current.json" carrier_settings.count 3210
assert_json_value 'PASS receipt exposes MCFG count' "$TEST_ROOT/current.json" mcfg.count 5

write_receipt "$ACTIVE_ROOT/pixel9pro_baseband_trial/.runtime_status" FAIL no stale_after_failure yes effective_overlay_failed
run_status || exit 2
assert_json_value 'FAIL receipt is not runtime verified' "$TEST_ROOT/current.json" runtime_verified false
assert_json_value 'FAIL receipt requests clean reinstall' "$TEST_ROOT/current.json" clean_reinstall_required true
assert_json_value 'FAIL receipt preserves error summary' "$TEST_ROOT/current.json" errors effective_overlay_failed

write_receipt "$ACTIVE_ROOT/pixel9pro_baseband_trial/.runtime_status" PASS yes current_check no none
sed -i 's/^schema=3$/schema=2/' "$ACTIVE_ROOT/pixel9pro_baseband_trial/.runtime_status"
run_status || exit 2
assert_json_value 'legacy receipt schema is not runtime verified' "$TEST_ROOT/current.json" runtime_verified false
assert_json_value 'legacy receipt schema requests clean reinstall' "$TEST_ROOT/current.json" clean_reinstall_required true
assert_json_value 'legacy receipt schema is explicit' "$TEST_ROOT/current.json" runtime_status LEGACY_RECEIPT
assert_json_value 'legacy receipt schema error is explicit' "$TEST_ROOT/current.json" errors legacy_receipt_schema

rm -f "$ACTIVE_ROOT/pixel9pro_baseband_trial/.runtime_status"
mkdir "$ACTIVE_ROOT/pixel9pro_baseband_trial/.runtime_status" || exit 2
run_status || exit 2
assert_json_value 'receipt directory is not runtime verified' "$TEST_ROOT/current.json" runtime_verified false
assert_json_value 'receipt directory requests clean reinstall' "$TEST_ROOT/current.json" clean_reinstall_required true
assert_json_value 'receipt directory has explicit error' "$TEST_ROOT/current.json" errors status_receipt_is_directory

rm -r "$ACTIVE_ROOT/pixel9pro_baseband_trial" || exit 2
run_status || exit 2
assert_json_value 'pending-only module is reported as pending' "$TEST_ROOT/current.json" source pending_update
assert_json_value 'pending-only module is not runtime verified' "$TEST_ROOT/current.json" runtime_verified false
assert_json_value 'pending-only module does not request clean reinstall' "$TEST_ROOT/current.json" clean_reinstall_required false
assert_json_value 'pending-only module reports pending status' "$TEST_ROOT/current.json" runtime_status PENDING_UPDATE

printf 'PASS: baseband status schema and active/pending/receipt matrix (%s cases)\n' "$((PASS + FAIL))"
printf '1..%s\n' "$((PASS + FAIL))"
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
