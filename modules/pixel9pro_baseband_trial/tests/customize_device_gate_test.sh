#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d /tmp/pixel9pro_baseband_test.XXXXXX)

cleanup() {
    case "$TMP_ROOT" in
        /tmp/pixel9pro_baseband_test.*)
            [ ! -d "$TMP_ROOT" ] || rm -r -- "$TMP_ROOT"
            ;;
        *)
            printf 'Refusing unsafe cleanup path: %s\n' "$TMP_ROOT" >&2
            return 1
            ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_contains() {
    case "$1" in *"$2"*) return 0 ;; esac
    fail "output missing: $2"
}

prepare_fixture() {
    local name=$1
    local meta_state=${2:-active}
    local fixture="$TMP_ROOT/$name"
    local adb_root="$fixture/data/adb"
    mkdir -p "$fixture/config" "$fixture/system/product/etc/CarrierSettings" \
        "$fixture/scripts" \
        "$adb_root/modules/meta-overlayfs/mnt" "$adb_root/modules_update"
    cp "$ROOT_DIR/config/baseband_devices.tsv" "$fixture/config/baseband_devices.tsv"
    cp "$ROOT_DIR/scripts/baseband_runtime.sh" "$fixture/scripts/baseband_runtime.sh"
    printf 'fixture-source\n' > "$fixture/system/product/etc/CarrierSettings/carrier_list.pb"
    printf 'fixture-boot\n' > "$fixture/boot_id"
    printf '1 0 0:1 / /product rw,relatime - overlay overlay rw\n2 0 0:2 / /vendor rw,relatime - overlay overlay rw\n' > "$fixture/mountinfo"
    printf 'id=meta-overlayfs\nmetamodule=1\n' \
        > "$adb_root/modules/meta-overlayfs/module.prop"
    case "$meta_state" in
        active)
            ln -s "$adb_root/modules/meta-overlayfs" "$adb_root/metamodule"
            ;;
        disabled)
            : > "$adb_root/modules/meta-overlayfs/disable"
            ln -s "$adb_root/modules/meta-overlayfs" "$adb_root/metamodule"
            ;;
        marker-only)
            ;;
        direct)
            mkdir -p "$adb_root/metamodule/mnt"
            printf 'id=direct-meta\nmetamodule=1\n' > "$adb_root/metamodule/module.prop"
            ;;
        ambiguous-marker)
            mkdir -p "$adb_root/modules/second-meta/mnt"
            printf 'id=second-meta\nmetamodule=1\n' > "$adb_root/modules/second-meta/module.prop"
            ;;
        missing)
            rm -r -- "$adb_root/modules/meta-overlayfs"
            ;;
        *) fail "unknown MetaModule fixture state: $meta_state" ;;
    esac
    printf '%s\n' "$fixture"
}

prepare_verified_upgrade() {
    local fixture=$1
    local adb_root="$fixture/data/adb"
    local old="$adb_root/modules/pixel9pro_baseband_trial"
    local content="$adb_root/modules/meta-overlayfs/mnt/pixel9pro_baseband_trial"
    mkdir -p "$old/system/product/etc/CarrierSettings" \
        "$old/system/product/etc" \
        "$old/system/vendor/rfs/msm/mpss/readonly/vendor/mbn/mcfg_sw/generic/China" \
        "$old/config" \
        "$content/system/product/etc/CarrierSettings" \
        "$content/system/product/etc" \
        "$content/system/vendor/rfs/msm/mpss/readonly/vendor/mbn/mcfg_sw/generic/China" \
        "$fixture/effective/product/etc/CarrierSettings" \
        "$fixture/effective/product/etc" \
        "$fixture/effective/vendor/rfs/msm/mpss/readonly/vendor/mbn/mcfg_sw/generic/China"
    printf 'old-source\n' > "$old/system/product/etc/CarrierSettings/carrier_list.pb"
    printf '<apns-conf />\n' > "$old/system/product/etc/apns-conf.xml"
    printf 'mcfg\n' > "$old/system/vendor/rfs/msm/mpss/readonly/vendor/mbn/mcfg_sw/generic/China/mcfg_sw.mbn"
    cp -a "$old/system/." "$content/system/"
    cp -a "$old/system/." "$fixture/effective/"
    local carrier_hash
    carrier_hash=$(sha256sum "$old/system/product/etc/CarrierSettings/carrier_list.pb" | awk '{print $1}')
    local apn_hash
    apn_hash=$(sha256sum "$old/system/product/etc/apns-conf.xml" | awk '{print $1}')
    {
        printf '%s\n' '# minimal fixture contract'
        printf 'carrier_settings|/product/etc/CarrierSettings|min_file_count|1\n'
        printf 'carrier_list|/product/etc/CarrierSettings/carrier_list.pb|sha256|%s\n' "$carrier_hash"
        printf 'apn|/product/etc/apns-conf.xml|sha256|%s\n' "$apn_hash"
        printf 'china_mcfg|/vendor/rfs/msm/mpss/readonly/vendor/mbn/mcfg_sw/generic/China|min_file_count|1\n'
    } > "$old/config/runtime_contract.tsv"
    printf 'id=pixel9pro_baseband_trial\nversion=v1.0.1\nversionCode=101\n' > "$old/module.prop"
    (
        export BASEBAND_ADB_ROOT="$adb_root"
        export BASEBAND_MODULE_ID=pixel9pro_baseband_trial
        export BASEBAND_MODDIR="$old"
        export BASEBAND_CONTRACT_PATH="$old/config/runtime_contract.tsv"
        export BASEBAND_STATUS="$old/.runtime_status"
        export BASEBAND_SOURCE_ROOT="$old/system"
        export BASEBAND_EFFECTIVE_ROOT="$fixture/effective"
        export BASEBAND_METAMODULE_LINK="$adb_root/metamodule"
        export BASEBAND_MOUNTINFO_PATH="$fixture/mountinfo"
        export BASEBAND_BOOT_ID_PATH="$fixture/boot_id"
        export BASEBAND_ROOT_IMPL=APatch
        export BASEBAND_TEST_DEVICE=caiman
        . "$ROOT_DIR/scripts/baseband_runtime.sh"
        baseband_runtime_check fixture_upgrade
    ) || fail "could not create verified old runtime receipt"
    [ "$(grep '^status=' "$old/.runtime_status" | cut -d= -f2-)" = PASS ] || fail "fixture old receipt is not PASS"
}

prepare_verified_direct_upgrade() {
    local fixture=$1
    local adb_root="$fixture/data/adb"
    local old="$adb_root/modules/pixel9pro_baseband_trial"
    local content="$adb_root/modules/meta-overlayfs/mnt/pixel9pro_baseband_trial"
    mkdir -p "$old/product/etc/CarrierSettings" \
        "$old/product/etc" \
        "$old/vendor/rfs/msm/mpss/readonly/vendor/mbn/mcfg_sw/generic/China" \
        "$old/system" \
        "$old/config" \
        "$content/product/etc/CarrierSettings" \
        "$content/product/etc" \
        "$content/vendor/rfs/msm/mpss/readonly/vendor/mbn/mcfg_sw/generic/China" \
        "$content/system" \
        "$fixture/effective/product/etc/CarrierSettings" \
        "$fixture/effective/product/etc" \
        "$fixture/effective/vendor/rfs/msm/mpss/readonly/vendor/mbn/mcfg_sw/generic/China"
    printf 'old-source\n' > "$old/product/etc/CarrierSettings/carrier_list.pb"
    printf '<apns-conf />\n' > "$old/product/etc/apns-conf.xml"
    printf 'mcfg\n' > "$old/vendor/rfs/msm/mpss/readonly/vendor/mbn/mcfg_sw/generic/China/mcfg_sw.mbn"
    cp -a "$old/product/." "$content/product/"
    cp -a "$old/vendor/." "$content/vendor/"
    cp -a "$old/product/." "$fixture/effective/product/"
    cp -a "$old/vendor/." "$fixture/effective/vendor/"
    local carrier_hash
    carrier_hash=$(sha256sum "$old/product/etc/CarrierSettings/carrier_list.pb" | awk '{print $1}')
    local apn_hash
    apn_hash=$(sha256sum "$old/product/etc/apns-conf.xml" | awk '{print $1}')
    {
        printf '%s\n' '# minimal direct-layout fixture contract'
        printf 'carrier_settings|/product/etc/CarrierSettings|min_file_count|1\n'
        printf 'carrier_list|/product/etc/CarrierSettings/carrier_list.pb|sha256|%s\n' "$carrier_hash"
        printf 'apn|/product/etc/apns-conf.xml|sha256|%s\n' "$apn_hash"
        printf 'china_mcfg|/vendor/rfs/msm/mpss/readonly/vendor/mbn/mcfg_sw/generic/China|min_file_count|1\n'
    } > "$old/config/runtime_contract.tsv"
    printf 'id=pixel9pro_baseband_trial\nversion=v1.0.1\nversionCode=101\n' > "$old/module.prop"
    (
        export BASEBAND_ADB_ROOT="$adb_root"
        export BASEBAND_MODULE_ID=pixel9pro_baseband_trial
        export BASEBAND_MODDIR="$old"
        export BASEBAND_CONTRACT_PATH="$old/config/runtime_contract.tsv"
        export BASEBAND_STATUS="$old/.runtime_status"
        export BASEBAND_EFFECTIVE_ROOT="$fixture/effective"
        export BASEBAND_METAMODULE_LINK="$adb_root/metamodule"
        export BASEBAND_MOUNTINFO_PATH="$fixture/mountinfo"
        export BASEBAND_BOOT_ID_PATH="$fixture/boot_id"
        export BASEBAND_ROOT_IMPL=APatch
        export BASEBAND_TEST_DEVICE=caiman
        . "$ROOT_DIR/scripts/baseband_runtime.sh"
        baseband_runtime_check fixture_direct_upgrade
    ) || fail "could not create verified direct-layout old runtime receipt"
    [ "$(grep '^status=' "$old/.runtime_status" | cut -d= -f2-)" = PASS ] || fail "direct-layout fixture old receipt is not PASS"
}

run_installer_body() {
    local test_device=$1
    local root_impl=$2
    local install_path=${3:-$RUN_FIXTURE}
    set +e
    RUN_OUTPUT=$(
        (
            MODPATH="$install_path"
            TEST_DEVICE="$test_device"
            BASEBAND_ADB_ROOT="$RUN_FIXTURE/data/adb"
            BASEBAND_BOOT_ID_PATH="$RUN_FIXTURE/boot_id"
            BASEBAND_MOUNTINFO_PATH="$RUN_FIXTURE/mountinfo"
            BASEBAND_EFFECTIVE_ROOT="$RUN_FIXTURE/effective"
            export MODPATH TEST_DEVICE BASEBAND_ADB_ROOT BASEBAND_BOOT_ID_PATH BASEBAND_MOUNTINFO_PATH BASEBAND_EFFECTIVE_ROOT
            unset APATCH APATCH_VER_CODE KSU KSU_VER_CODE MAGISK_VER_CODE MAGISK_VER
            case "$root_impl" in
                APatch) mkdir -p "$BASEBAND_ADB_ROOT/ap"; APATCH=true; export APATCH ;;
                KernelSU) mkdir -p "$BASEBAND_ADB_ROOT/ksu"; KSU=true; export KSU ;;
                Magisk) mkdir -p "$BASEBAND_ADB_ROOT/magisk"; MAGISK_VER_CODE=27000; export MAGISK_VER_CODE ;;
                Unknown) ;;
                *) exit 98 ;;
            esac
            getprop() {
                case "$1" in
                    ro.product.device|ro.build.product) printf '%s\n' "$TEST_DEVICE" ;;
                    *) printf '\n' ;;
                esac
            }
            ui_print() { printf '%s\n' "$*"; }
            set_perm_recursive() { :; }
            . "$ROOT_DIR/customize.sh"
        ) 2>&1
    )
    RUN_RC=$?
    set -e
}

run_installer() {
    local name=$1
    local test_device=$2
    local root_impl=$3
    local corrupt=${4:-0}
    local meta_state=${5:-active}
    RUN_FIXTURE=$(prepare_fixture "$name" "$meta_state")
    [ "$corrupt" = "0" ] || fail "legacy UECap payload fixture is no longer applicable"
    run_installer_body "$test_device" "$root_impl"
}

run_installer caiman_apatch caiman APatch
[ "$RUN_RC" -eq 0 ] || fail "caiman/APatch rejected: $RUN_OUTPUT"
assert_contains "$RUN_OUTPUT" "Pixel 9 Pro (caiman)"
assert_contains "$RUN_OUTPUT" "pixel9pro_control"
assert_contains "$RUN_OUTPUT" "MetaModule"
find "$RUN_FIXTURE" -type f -name '*.binarypb' -print -quit | grep -q . && fail "caiman installer staged UECap payload"

run_installer fresh_install_target caiman APatch
FRESH_INSTALL_PATH="$RUN_FIXTURE/data/adb/modules/pixel9pro_baseband_trial"
mkdir -p "$FRESH_INSTALL_PATH"
cp -a "$RUN_FIXTURE/config" "$FRESH_INSTALL_PATH/"
cp -a "$RUN_FIXTURE/scripts" "$FRESH_INSTALL_PATH/"
cp -a "$RUN_FIXTURE/system" "$FRESH_INSTALL_PATH/"
printf 'id=pixel9pro_baseband_trial\nversion=v1.1.0-rc3\nversionCode=112\n' > "$FRESH_INSTALL_PATH/module.prop"
run_installer_body caiman APatch "$FRESH_INSTALL_PATH/"
[ "$RUN_RC" -eq 0 ] || fail "fresh install target with trailing slash was rejected: $RUN_OUTPUT"
[ "$(cat "$FRESH_INSTALL_PATH/.migration_state")" = fresh_install_pending_reboot ] || fail "fresh install did not publish pending reboot state"

run_installer fresh_install_empty_residue caiman APatch
RESIDUE_PATH="$RUN_FIXTURE/data/adb/modules/pixel9pro_baseband_trial"
STAGING_PATH="$RUN_FIXTURE/staging/pixel9pro_baseband_trial"
mkdir -p "$RESIDUE_PATH" "$STAGING_PATH"
cp -a "$RUN_FIXTURE/config" "$STAGING_PATH/"
cp -a "$RUN_FIXTURE/scripts" "$STAGING_PATH/"
cp -a "$RUN_FIXTURE/system" "$STAGING_PATH/"
printf 'id=pixel9pro_baseband_trial\nversion=v1.1.0-rc3\nversionCode=112\n' > "$STAGING_PATH/module.prop"
run_installer_body caiman APatch "$STAGING_PATH"
[ "$RUN_RC" -eq 0 ] || fail "fresh install with empty failed-install residue was rejected: $RUN_OUTPUT"
[ "$(cat "$STAGING_PATH/.migration_state")" = fresh_install_pending_reboot ] || fail "empty residue install did not publish pending reboot state"

run_installer nonempty_invalid_active caiman APatch
INVALID_ACTIVE="$RUN_FIXTURE/data/adb/modules/pixel9pro_baseband_trial"
INVALID_STAGING="$RUN_FIXTURE/staging/pixel9pro_baseband_trial"
mkdir -p "$INVALID_ACTIVE"
printf 'unexpected\n' > "$INVALID_ACTIVE/unexpected"
mkdir -p "$INVALID_STAGING"
cp -a "$RUN_FIXTURE/config" "$INVALID_STAGING/"
cp -a "$RUN_FIXTURE/scripts" "$INVALID_STAGING/"
cp -a "$RUN_FIXTURE/system" "$INVALID_STAGING/"
printf 'id=pixel9pro_baseband_trial\nversion=v1.1.0-rc3\nversionCode=112\n' > "$INVALID_STAGING/module.prop"
run_installer_body caiman APatch "$INVALID_STAGING"
[ "$RUN_RC" -ne 0 ] || fail "non-empty invalid active residue was accepted"
assert_contains "$RUN_OUTPUT" "旧模块不是可直接升级的 enabled ordinary module"

run_installer direct_upgrade_verified caiman APatch
prepare_verified_upgrade "$RUN_FIXTURE"
run_installer_body caiman APatch
[ "$RUN_RC" -eq 0 ] || fail "verified direct upgrade rejected: $RUN_OUTPUT"
[ "$(cat "$RUN_FIXTURE/.migration_state")" = verified_overlay ] || fail "verified direct upgrade did not publish verified_overlay"

run_installer direct_upgrade_verified_layout caiman APatch
prepare_verified_direct_upgrade "$RUN_FIXTURE"
run_installer_body caiman APatch
[ "$RUN_RC" -eq 0 ] || fail "verified direct-layout upgrade rejected: $RUN_OUTPUT"
[ "$(cat "$RUN_FIXTURE/.migration_state")" = verified_overlay ] || fail "verified direct-layout upgrade did not publish verified_overlay"

run_installer direct_upgrade_cross_boot caiman APatch
prepare_verified_upgrade "$RUN_FIXTURE"
printf 'other-boot\n' > "$RUN_FIXTURE/boot_id"
run_installer_body caiman APatch
[ "$RUN_RC" -ne 0 ] || fail "cross-boot direct upgrade was accepted"
assert_contains "$RUN_OUTPUT" "卸载旧版普通基带模块"

run_installer direct_upgrade_legacy_schema caiman APatch
prepare_verified_upgrade "$RUN_FIXTURE"
sed -i 's/^schema=3$/schema=2/' "$RUN_FIXTURE/data/adb/modules/pixel9pro_baseband_trial/.runtime_status"
run_installer_body caiman APatch
[ "$RUN_RC" -ne 0 ] || fail "legacy schema direct upgrade was accepted"
assert_contains "$RUN_OUTPUT" "旧版或未知 runtime receipt schema"

run_installer pending_conflict caiman APatch
prepare_verified_upgrade "$RUN_FIXTURE"
mkdir -p "$RUN_FIXTURE/data/adb/modules_update/pixel9pro_baseband_trial"
printf 'id=pixel9pro_baseband_trial\n' > "$RUN_FIXTURE/data/adb/modules_update/pixel9pro_baseband_trial/module.prop"
run_installer_body caiman APatch
[ "$RUN_RC" -ne 0 ] || fail "active/pending conflict was accepted"
assert_contains "$RUN_OUTPUT" "active module 与另一个 pending update 同时存在"

run_installer komodo_apatch komodo APatch
[ "$RUN_RC" -eq 0 ] || fail "komodo/APatch rejected: $RUN_OUTPUT"
find "$RUN_FIXTURE" -type f -name '*.binarypb' -print -quit | grep -q . && fail "komodo installer staged UECap payload"
assert_contains "$RUN_OUTPUT" "不携带 UECap"

run_installer komodo_ksu komodo KernelSU
[ "$RUN_RC" -eq 0 ] || fail "komodo/KernelSU rejected: $RUN_OUTPUT"
find "$RUN_FIXTURE" -type f -name '*.binarypb' -print -quit | grep -q . && fail "komodo/KernelSU staged UECap payload"
assert_contains "$RUN_OUTPUT" "MetaModule"

run_installer ksu_without_metamodule komodo KernelSU 0 missing
[ "$RUN_RC" -ne 0 ] || fail "KernelSU without MetaModule was accepted"
assert_contains "$RUN_OUTPUT" "需要已启用的 MetaModule"

run_installer ksu_marker_only komodo KernelSU 0 marker-only
[ "$RUN_RC" -eq 0 ] || fail "KernelSU marker-only MetaModule rejected: $RUN_OUTPUT"
assert_contains "$RUN_OUTPUT" "marker-only"

run_installer apatch_marker_only komodo APatch 0 marker-only
[ "$RUN_RC" -ne 0 ] || fail "APatch accepted marker-only MetaModule"
assert_contains "$RUN_OUTPUT" "需要活动 /data/adb/metamodule symlink"

run_installer apatch_direct_path komodo APatch 0 direct
[ "$RUN_RC" -ne 0 ] || fail "APatch accepted a non-symlink /data/adb/metamodule path"
assert_contains "$RUN_OUTPUT" "需要活动 /data/adb/metamodule symlink"

run_installer ksu_ambiguous_marker komodo KernelSU 0 ambiguous-marker
[ "$RUN_RC" -ne 0 ] || fail "KernelSU accepted ambiguous marker-only MetaModules"
assert_contains "$RUN_OUTPUT" "multiple enabled modules declare metamodule=1"

run_installer magisk_without_metamodule komodo Magisk 0 missing
[ "$RUN_RC" -eq 0 ] || fail "Magisk rejected without MetaModule: $RUN_OUTPUT"
find "$RUN_FIXTURE" -type f -name '*.binarypb' -print -quit | grep -q . && fail "Magisk installer staged UECap payload"
assert_contains "$RUN_OUTPUT" "CarrierSettings"

run_installer unsupported tokay APatch 0 missing
[ "$RUN_RC" -ne 0 ] || fail "unsupported device was accepted"
assert_contains "$RUN_OUTPUT" "仅允许 Pixel 9 Pro (caiman) / Pro XL (komodo)"

run_installer unknown_root komodo Unknown 0 missing
[ "$RUN_RC" -ne 0 ] || fail "unknown root was accepted"
assert_contains "$RUN_OUTPUT" "无法识别 APatch / KernelSU / Magisk"

run_installer disabled_metamodule komodo APatch 0 disabled
[ "$RUN_RC" -ne 0 ] || fail "disabled MetaModule was accepted"
assert_contains "$RUN_OUTPUT" "需要已启用的 MetaModule"

printf 'PASS: customize device/root/metamodule/no-UECap/migration gate (17 cases)\n'
