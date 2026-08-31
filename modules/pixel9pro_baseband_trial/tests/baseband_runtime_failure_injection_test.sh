#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
TMP_ROOT=$(mktemp -d /tmp/pixel9pro_baseband_runtime.XXXXXX)
cleanup() {
    case "$TMP_ROOT" in
        /tmp/pixel9pro_baseband_runtime.*) rm -r -- "$TMP_ROOT" ;;
        *) printf 'Refusing unsafe cleanup path: %s\n' "$TMP_ROOT" >&2; return 1 ;;
    esac
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
status_value() { grep "^$2=" "$1" | head -n 1 | cut -d= -f2-; }
assert_eq() { [ "$2" = "$3" ] || fail "$1: expected=$2 actual=$3"; }
make_mountinfo() {
    : > "$1"
    [ "$2" = yes ] && printf '1 0 0:1 / /product rw,relatime - overlay overlay rw\n' >> "$1"
    [ "$3" = yes ] && printf '2 0 0:2 / /vendor rw,relatime - overlay overlay rw\n' >> "$1"
    [ "$4" = yes ] && printf '3 0 0:3 / /system rw,relatime - overlay overlay rw\n' >> "$1"
    return 0
}
prepare_fixture() {
    local name=$1 root_impl=$2 device=$3
    local fixture="$TMP_ROOT/$name"
    local meta="$fixture/data/adb/modules/meta-overlayfs"
    local content="$meta/mnt/pixel9pro_baseband_trial"
    mkdir -p "$fixture/module" "$fixture/data/adb/modules" "$meta/mnt" "$fixture/effective" "$fixture/config"
    # Keep this fixture intentionally small.  The real 3210 CarrierSettings /
    # 5 MCFG counts are covered by Test-BasebandModule.ps1 and the builder;
    # this test exercises the source -> content image -> effective path
    # contract and its failure modes.
    mkdir -p "$fixture/source/product/etc/CarrierSettings" \
        "$fixture/source/product/etc" \
        "$fixture/source/vendor/rfs/msm/mpss/readonly/vendor/mbn/mcfg_sw/generic/China" \
        "$content/system/product/etc/CarrierSettings" \
        "$content/system/product/etc" \
        "$content/system/vendor/rfs/msm/mpss/readonly/vendor/mbn/mcfg_sw/generic/China" \
        "$fixture/effective/product/etc/CarrierSettings" \
        "$fixture/effective/product/etc" \
        "$fixture/effective/vendor/rfs/msm/mpss/readonly/vendor/mbn/mcfg_sw/generic/China"
    printf 'carrier-list\n' > "$fixture/source/product/etc/CarrierSettings/carrier_list.pb"
    printf 'carrier-extra\n' > "$fixture/source/product/etc/CarrierSettings/extra.pb"
    printf '<apns-conf />\n' > "$fixture/source/product/etc/apns-conf.xml"
    printf 'mcfg\n' > "$fixture/source/vendor/rfs/msm/mpss/readonly/vendor/mbn/mcfg_sw/generic/China/mcfg_sw.mbn"
    cp -a "$fixture/source/product/." "$content/system/product/"
    cp -a "$fixture/source/vendor/." "$content/system/vendor/"
    cp -a "$fixture/source/product/." "$fixture/effective/product/"
    cp -a "$fixture/source/vendor/." "$fixture/effective/vendor/"
    local carrier_hash
    carrier_hash=$(sha256sum "$fixture/source/product/etc/CarrierSettings/carrier_list.pb" | awk '{print $1}')
    local apn_hash
    apn_hash=$(sha256sum "$fixture/source/product/etc/apns-conf.xml" | awk '{print $1}')
    {
        printf 'carrier_settings|/product/etc/CarrierSettings|min_file_count|2\n'
        printf 'carrier_list|/product/etc/CarrierSettings/carrier_list.pb|sha256|%s\n' "$carrier_hash"
        printf 'apn|/product/etc/apns-conf.xml|sha256|%s\n' "$apn_hash"
        printf 'china_mcfg|/vendor/rfs/msm/mpss/readonly/vendor/mbn/mcfg_sw/generic/China|min_file_count|1\n'
    } > "$fixture/config/runtime_contract.tsv"
    printf 'id=meta-overlayfs\nmetamodule=1\n' > "$meta/module.prop"
    ln -s "$meta" "$fixture/data/adb/metamodule"
    printf 'boot-%s\n' "$name" > "$fixture/boot_id"
    make_mountinfo "$fixture/mountinfo" yes yes no
    printf '%s\n' "$fixture"
}

prepare_direct_layout_fixture() {
    local name=$1
    local fixture
    fixture=$(prepare_fixture "$name" APatch caiman)
    rm -r -- "$fixture/data/adb/modules/meta-overlayfs/mnt/pixel9pro_baseband_trial/system"
    mkdir -p "$fixture/module/product/etc/CarrierSettings" \
        "$fixture/module/vendor/rfs/msm/mpss/readonly/vendor/mbn/mcfg_sw/generic/China" \
        "$fixture/module/system" \
        "$fixture/data/adb/modules/meta-overlayfs/mnt/pixel9pro_baseband_trial/product/etc/CarrierSettings" \
        "$fixture/data/adb/modules/meta-overlayfs/mnt/pixel9pro_baseband_trial/vendor/rfs/msm/mpss/readonly/vendor/mbn/mcfg_sw/generic/China"
    printf 'carrier-list\n' > "$fixture/module/product/etc/CarrierSettings/carrier_list.pb"
    printf 'carrier-extra\n' > "$fixture/module/product/etc/CarrierSettings/extra.pb"
    printf '<apns-conf />\n' > "$fixture/module/product/etc/apns-conf.xml"
    printf 'mcfg\n' > "$fixture/module/vendor/rfs/msm/mpss/readonly/vendor/mbn/mcfg_sw/generic/China/mcfg_sw.mbn"
    cp -a "$fixture/module/product/." "$fixture/data/adb/modules/meta-overlayfs/mnt/pixel9pro_baseband_trial/product/"
    cp -a "$fixture/module/vendor/." "$fixture/data/adb/modules/meta-overlayfs/mnt/pixel9pro_baseband_trial/vendor/"
    cp -a "$fixture/module/product/." "$fixture/effective/product/"
    cp -a "$fixture/module/vendor/." "$fixture/effective/vendor/"
    printf 'stock-lower-only\n' > "$fixture/effective/product/etc/CarrierSettings/stock-lower-only.pb"
    printf '%s' "$fixture/module" > "$fixture/source_root"
    printf '%s' "$fixture"
}
run_check() {
    local fixture=$1 root_impl=$2 device=$3
    set +e
    (
        export BASEBAND_ADB_ROOT="$fixture/data/adb"
        export BASEBAND_MODDIR="$fixture/module"
        export BASEBAND_CONTRACT_PATH="$fixture/config/runtime_contract.tsv"
        export BASEBAND_STATUS="$fixture/module/.runtime_status"
        export BASEBAND_SOURCE_ROOT="$( [ -f "$fixture/source_root" ] && cat "$fixture/source_root" || printf '%s' "$fixture/source" )"
        export BASEBAND_EFFECTIVE_ROOT="$fixture/effective"
        export BASEBAND_METAMODULE_LINK="$fixture/data/adb/metamodule"
        export BASEBAND_MOUNTINFO_PATH="$fixture/mountinfo"
        export BASEBAND_BOOT_ID_PATH="$fixture/boot_id"
        export BASEBAND_ROOT_IMPL="$root_impl"
        export BASEBAND_TEST_DEVICE="$device"
        . "$ROOT_DIR/scripts/baseband_runtime.sh"
        baseband_runtime_check failure_injection
    )
    RUN_RC=$?
    set -e
}
expect_fail() {
    run_check "$2" "$3" "$4"
    [ "$RUN_RC" -ne 0 ] || fail "$1 unexpectedly passed"
    assert_eq "$1 status" FAIL "$(status_value "$2/module/.runtime_status" status)"
    assert_eq "$1 migration state" clean_reinstall_required "$(cat "$2/module/.migration_state")"
}
expect_pass() {
    run_check "$2" "$3" "$4"
    [ "$RUN_RC" -eq 0 ] || fail "$1 rejected: rc=$RUN_RC"
    assert_eq "$1 status" PASS "$(status_value "$2/module/.runtime_status" status)"
    assert_eq "$1 overlay" yes "$(status_value "$2/module/.runtime_status" effective_overlay_verified)"
    assert_eq "$1 receipt" current_check "$(status_value "$2/module/.runtime_status" runtime_receipt_freshness)"
    assert_eq "$1 migration state" effective_overlay_verified "$(cat "$2/module/.migration_state")"
}

fixture=$(prepare_fixture apatch_pass APatch caiman)
printf 'CASE apatch_pass\n' >&2
expect_pass 'APatch complete source/content/effective contract' "$fixture" APatch caiman
assert_eq 'first prior receipt' missing "$(status_value "$fixture/module/.runtime_status" prior_receipt_freshness)"
assert_eq 'full overlay mount' yes "$(status_value "$fixture/module/.runtime_status" mount_observed)"

fixture=$(prepare_direct_layout_fixture direct_layout_pass)
printf 'CASE direct_layout_pass\n' >&2
expect_pass 'APatch direct product/vendor payload with empty system compatibility dir' "$fixture" APatch caiman
assert_eq 'direct source contract verified' yes "$(status_value "$fixture/module/.runtime_status" source_contract_verified)"
assert_eq 'direct content contract verified' yes "$(status_value "$fixture/module/.runtime_status" content_image_verified)"
assert_eq 'direct effective extra files allowed' yes "$(status_value "$fixture/module/.runtime_status" effective_extra_files_allowed)"
assert_eq 'direct effective count includes lower-layer extra' 3 "$(status_value "$fixture/module/.runtime_status" carrier_settings_files)"
assert_eq 'direct full tree hashes are diagnostic only' not_collected "$(status_value "$fixture/module/.runtime_status" source_tree_hash)"

fixture=$(prepare_fixture cross_boot APatch caiman)
printf 'CASE cross_boot\n' >&2
printf 'schema=2\nstatus=PASS\neffective_overlay_verified=yes\nruntime_receipt_freshness=current_check\nboot_id=old-boot\n' > "$fixture/module/.runtime_status"
expect_pass 'cross-boot prior receipt is replaced' "$fixture" APatch caiman
assert_eq 'cross-boot prior receipt' cross_boot "$(status_value "$fixture/module/.runtime_status" prior_receipt_freshness)"

fixture=$(prepare_fixture no_metamodule APatch caiman)
printf 'CASE no_metamodule\n' >&2
rm -f "$fixture/data/adb/metamodule"
expect_fail 'missing MetaModule' "$fixture" APatch caiman

fixture=$(prepare_fixture disabled_metamodule APatch caiman)
printf 'CASE disabled_metamodule\n' >&2
: > "$fixture/data/adb/modules/meta-overlayfs/disable"
expect_fail 'disabled MetaModule' "$fixture" APatch caiman

fixture=$(prepare_fixture empty_content APatch caiman)
printf 'CASE empty_content\n' >&2
rm -r -- "$fixture/data/adb/modules/meta-overlayfs/mnt/pixel9pro_baseband_trial"
mkdir -p "$fixture/data/adb/modules/meta-overlayfs/mnt/pixel9pro_baseband_trial"
expect_fail 'empty content image' "$fixture" APatch caiman

fixture=$(prepare_fixture unrelated_content APatch caiman)
printf 'CASE unrelated_content\n' >&2
printf 'unrelated\n' > "$fixture/data/adb/modules/meta-overlayfs/mnt/pixel9pro_baseband_trial/marker"
expect_fail 'unrelated content sibling' "$fixture" APatch caiman

fixture=$(prepare_fixture content_hash_mismatch APatch caiman)
printf 'CASE content_hash_mismatch\n' >&2
printf 'changed\n' >> "$fixture/data/adb/metamodule/mnt/pixel9pro_baseband_trial/system/product/etc/apns-conf.xml"
expect_fail 'exact APN content hash mismatch' "$fixture" APatch caiman

fixture=$(prepare_fixture content_carrier_hash_mismatch APatch caiman)
printf 'CASE content_carrier_hash_mismatch\n' >&2
printf 'changed\n' >> "$fixture/data/adb/metamodule/mnt/pixel9pro_baseband_trial/system/product/etc/CarrierSettings/carrier_list.pb"
expect_fail 'exact carrier content hash mismatch' "$fixture" APatch caiman

fixture=$(prepare_fixture source_missing APatch caiman)
printf 'CASE source_missing\n' >&2
rm -f "$fixture/source/product/etc/apns-conf.xml"
expect_fail 'source contract missing' "$fixture" APatch caiman

fixture=$(prepare_fixture source_carrier_hash_mismatch APatch caiman)
printf 'CASE source_carrier_hash_mismatch\n' >&2
printf 'changed\n' >> "$fixture/source/product/etc/CarrierSettings/carrier_list.pb"
expect_fail 'exact carrier source hash mismatch' "$fixture" APatch caiman

fixture=$(prepare_fixture effective_hash_mismatch APatch caiman)
printf 'CASE effective_hash_mismatch\n' >&2
printf 'changed\n' >> "$fixture/effective/product/etc/CarrierSettings/carrier_list.pb"
expect_fail 'exact carrier effective hash mismatch' "$fixture" APatch caiman

fixture=$(prepare_fixture effective_apn_hash_mismatch APatch caiman)
printf 'CASE effective_apn_hash_mismatch\n' >&2
printf 'changed\n' >> "$fixture/effective/product/etc/apns-conf.xml"
expect_fail 'exact APN effective hash mismatch' "$fixture" APatch caiman

fixture=$(prepare_fixture product_only APatch caiman)
printf 'CASE product_only\n' >&2
make_mountinfo "$fixture/mountinfo" yes no no
expect_fail 'only product overlay' "$fixture" APatch caiman

fixture=$(prepare_fixture unrelated_overlay APatch caiman)
printf 'CASE unrelated_overlay\n' >&2
make_mountinfo "$fixture/mountinfo" no no yes
expect_fail 'unrelated overlay' "$fixture" APatch caiman

fixture=$(prepare_fixture missing_mountinfo APatch caiman)
printf 'CASE missing_mountinfo\n' >&2
rm -f "$fixture/mountinfo"
expect_fail 'mountinfo missing' "$fixture" APatch caiman

fixture=$(prepare_fixture unknown_device APatch tokay)
printf 'CASE unknown_device\n' >&2
expect_fail 'unknown device' "$fixture" APatch tokay

fixture=$(prepare_fixture unknown_root Unknown caiman)
printf 'CASE unknown_root\n' >&2
expect_fail 'unknown root' "$fixture" Unknown caiman

fixture=$(prepare_fixture magisk_pass Magisk caiman)
printf 'CASE magisk_pass\n' >&2
rm -f "$fixture/data/adb/metamodule"
expect_pass 'Magisk effective paths without MetaModule' "$fixture" Magisk caiman
assert_eq 'Magisk mount semantics' not_required_magisk "$(status_value "$fixture/module/.runtime_status" mount_observed)"
assert_eq 'Magisk content semantics' not_required_magisk "$(status_value "$fixture/module/.runtime_status" content_image_verified)"

fixture=$(prepare_fixture status_write_failure APatch caiman)
printf 'CASE status_write_failure\n' >&2
mkdir -p "$fixture/module/.runtime_status"
run_check "$fixture" APatch caiman
[ "$RUN_RC" -ne 0 ] || fail 'status write failure unexpectedly passed'
[ -d "$fixture/module/.runtime_status" ] || fail 'status write failure changed the receipt directory'

printf 'PASS: baseband runtime source/content/effective/receipt failure injection (21 cases)\n'
