#!/system/bin/sh

# pixel9pro_baseband_trial runtime readback contract.
#
# This helper is observation-only. The active root implementation owns
# MetaModule/Magic Mount relocation and overlay creation; this module never
# mounts, binds, edits modules.img, or writes /data/adb/metamodule/mnt.
#
# A successful APatch/KernelSU state requires every declared file/count row to
# agree across the layers:
#   module source -> MetaModule content image -> effective paths -> receipt.
# The effective path is an OverlayFS merged view. It may legitimately contain
# lower-layer files that are not in this module, so aggregate tree equality is
# not a valid correctness condition; only declared contract rows are.
# Magisk does not require a MetaModule mount, but it still requires every
# declared effective row to pass.  The source/content/effective contract
# hashes are independent observations of different views; they are not
# required to be equal.

BASEBAND_ADB_ROOT="${BASEBAND_ADB_ROOT:-/data/adb}"
BASEBAND_MODULE_ID="${BASEBAND_MODULE_ID:-pixel9pro_baseband_trial}"
BASEBAND_MODDIR="${BASEBAND_MODDIR:-${MODDIR:-$BASEBAND_ADB_ROOT/modules/$BASEBAND_MODULE_ID}}"
BASEBAND_CONTRACT="${BASEBAND_CONTRACT_PATH:-$BASEBAND_MODDIR/config/runtime_contract.tsv}"
BASEBAND_STATUS="${BASEBAND_STATUS_PATH:-$BASEBAND_MODDIR/.runtime_status}"
BASEBAND_MIGRATION_STATE_FILE="${BASEBAND_MIGRATION_STATE_PATH:-$BASEBAND_MODDIR/.migration_state}"
BASEBAND_ROOT_IMPL="${BASEBAND_ROOT_IMPL:-}"
BASEBAND_EFFECTIVE_ROOT="${BASEBAND_EFFECTIVE_ROOT:-}"
BASEBAND_SOURCE_ROOT="${BASEBAND_SOURCE_ROOT:-}"
BASEBAND_METAMODULE_LINK="${BASEBAND_METAMODULE_LINK:-$BASEBAND_ADB_ROOT/metamodule}"
BASEBAND_MOUNTINFO_PATH="${BASEBAND_MOUNTINFO_PATH:-/proc/self/mountinfo}"
BASEBAND_BOOT_ID_PATH="${BASEBAND_BOOT_ID_PATH:-/proc/sys/kernel/random/boot_id}"
BASEBAND_LOG_TAG="pixel9pro_baseband"

baseband_trim() {
    tr -d ' \r\n\t'
}

baseband_log() {
    if command -v log >/dev/null 2>&1; then
        log -t "$BASEBAND_LOG_TAG" "$*" 2>/dev/null || true
    fi
}

baseband_sha256() {
    _bb_file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$_bb_file" 2>/dev/null | awk '{print $1}' | baseband_trim
    elif command -v busybox >/dev/null 2>&1; then
        busybox sha256sum "$_bb_file" 2>/dev/null | awk '{print $1}' | baseband_trim
    elif [ -x "$BASEBAND_ADB_ROOT/ap/bin/busybox" ]; then
        "$BASEBAND_ADB_ROOT/ap/bin/busybox" sha256sum "$_bb_file" 2>/dev/null | awk '{print $1}' | baseband_trim
    else
        return 1
    fi
}

baseband_sha256_text() {
    _bb_text="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$_bb_text" | sha256sum 2>/dev/null | awk '{print $1}' | baseband_trim
    elif command -v busybox >/dev/null 2>&1; then
        printf '%s' "$_bb_text" | busybox sha256sum 2>/dev/null | awk '{print $1}' | baseband_trim
    elif [ -x "$BASEBAND_ADB_ROOT/ap/bin/busybox" ]; then
        printf '%s' "$_bb_text" | "$BASEBAND_ADB_ROOT/ap/bin/busybox" sha256sum 2>/dev/null | awk '{print $1}' | baseband_trim
    else
        return 1
    fi
}

baseband_file_count() {
    [ -d "$1" ] || {
        printf '0\n'
        return 0
    }
    find "$1" -type f 2>/dev/null | wc -l | baseband_trim
}

baseband_contract_value() {
    _bb_key="$1"
    [ -f "$BASEBAND_CONTRACT" ] || return 1
    awk -F'|' -v wanted="$_bb_key" '$1 == wanted { print $4; exit }' "$BASEBAND_CONTRACT" 2>/dev/null | baseband_trim
}

baseband_device() {
    _bb_device="${BASEBAND_TEST_DEVICE:-}"
    [ -n "$_bb_device" ] || _bb_device=$(getprop ro.product.device 2>/dev/null | baseband_trim)
    [ -n "$_bb_device" ] || _bb_device=$(getprop ro.build.product 2>/dev/null | baseband_trim)
    printf '%s' "${_bb_device:-unknown}"
}

baseband_boot_id() {
    _bb_boot=$(cat "$BASEBAND_BOOT_ID_PATH" 2>/dev/null | baseband_trim)
    [ -n "$_bb_boot" ] || _bb_boot=$(getprop ro.boot.boot_id 2>/dev/null | baseband_trim)
    case "$_bb_boot" in
        ''|*[!A-Za-z0-9._:-]*) printf 'unknown' ;;
        *) printf '%s' "$_bb_boot" ;;
    esac
}

baseband_detect_root_impl() {
    if [ -n "$BASEBAND_ROOT_IMPL" ]; then
        printf '%s' "$BASEBAND_ROOT_IMPL"
    elif [ -f "$BASEBAND_MODDIR/.root_impl" ]; then
        cat "$BASEBAND_MODDIR/.root_impl" 2>/dev/null | baseband_trim
    elif [ -d "$BASEBAND_ADB_ROOT/ap" ]; then
        printf 'APatch'
    elif [ -d "$BASEBAND_ADB_ROOT/ksu" ]; then
        printf 'KernelSU'
    elif [ -d "$BASEBAND_ADB_ROOT/magisk" ]; then
        printf 'Magisk'
    else
        printf 'Unknown'
    fi
}

baseband_resolve_link() {
    _bb_link="$1"
    _bb_raw=$(readlink "$_bb_link" 2>/dev/null)
    [ -n "$_bb_raw" ] || return 1
    case "$_bb_raw" in
        /*) printf '%s' "$_bb_raw" ;;
        *) printf '%s/%s' "${_bb_link%/*}" "$_bb_raw" ;;
    esac
}

baseband_active_metamodule() {
    _bb_target=$(baseband_resolve_link "$BASEBAND_METAMODULE_LINK" 2>/dev/null) || return 1
    [ -d "$_bb_target" ] || return 1
    [ ! -e "$_bb_target/disable" ] || return 1
    [ -f "$_bb_target/module.prop" ] || return 1
    _bb_marker=$(sed -n 's/^metamodule=//p' "$_bb_target/module.prop" 2>/dev/null | head -n 1 | baseband_trim)
    [ "$_bb_marker" = "1" ] || return 1
    [ -d "$_bb_target/mnt" ] || return 1
    printf '%s' "$_bb_target"
}

baseband_content_root() {
    _bb_meta=$(baseband_active_metamodule 2>/dev/null) || return 1
    _bb_root="$_bb_meta/mnt/$BASEBAND_MODULE_ID"
    [ -d "$_bb_root" ] || return 1
    [ "$(baseband_file_count "$_bb_root")" -gt 0 ] 2>/dev/null || return 1
    baseband_content_layout_valid "$_bb_root" || return 1
    printf '%s' "$_bb_root"
}

baseband_source_root() {
    _bb_root="$1"
    if [ -d "$_bb_root/product" ] || [ -d "$_bb_root/vendor" ]; then
        printf '%s' "$_bb_root"
    else
        printf '%s' "$_bb_root/system"
    fi
}

baseband_payload_tree_root() {
    _bb_root="$1"
    if [ -d "$_bb_root/product" ] || [ -d "$_bb_root/vendor" ]; then
        printf '%s' "$_bb_root"
    elif [ -d "$_bb_root/system/product" ] || [ -d "$_bb_root/system/vendor" ]; then
        printf '%s' "$_bb_root/system"
    else
        return 1
    fi
}

baseband_content_tree_root() {
    _bb_root="$1"
    # APatch/MetaModule may expose direct product/vendor trees and retain an
    # empty compatibility system/ directory beside them.
    if [ -d "$_bb_root/product" ] || [ -d "$_bb_root/vendor" ]; then
        printf '%s' "$_bb_root"
    elif [ -d "$_bb_root/system" ]; then
        printf '%s' "$_bb_root/system"
    else
        printf '%s' "$_bb_root"
    fi
}

baseband_content_layout_valid() {
    _bb_root="$1"
    [ -d "$_bb_root" ] || return 1
    if [ -d "$_bb_root/product" ] || [ -d "$_bb_root/vendor" ]; then
        # Current APatch/MetaModule relocation can expose direct partition
        # trees plus an empty compatibility system/ directory.
        find "$_bb_root" -mindepth 1 -maxdepth 1 ! -name system ! -name product ! -name vendor -print -quit 2>/dev/null | grep -q . && return 1
        _bb_product_file=$(find "$_bb_root/product" -type f -print -quit 2>/dev/null)
        _bb_vendor_file=$(find "$_bb_root/vendor" -type f -print -quit 2>/dev/null)
        [ -n "$_bb_product_file$_bb_vendor_file" ] || return 1
    elif [ -d "$_bb_root/system" ]; then
        find "$_bb_root" -mindepth 1 -maxdepth 1 ! -name system -print -quit 2>/dev/null | grep -q . && return 1
        [ "$(find "$_bb_root/system" -type f -print -quit 2>/dev/null)" ] || return 1
    else
        return 1
    fi
    return 0
}

baseband_source_path() {
    case "$1" in
        /*) printf '%s%s' "$BASEBAND_SOURCE_ROOT" "$1" ;;
        *) return 1 ;;
    esac
}

baseband_effective_path() {
    case "$1" in
        /*)
            if [ -n "$BASEBAND_EFFECTIVE_ROOT" ]; then
                printf '%s%s' "$BASEBAND_EFFECTIVE_ROOT" "$1"
            else
                printf '%s' "$1"
            fi
            ;;
        *) return 1 ;;
    esac
}

baseband_content_path() {
    _bb_root="$1"
    case "$2" in
        /*)
            _bb_prefix=$(baseband_content_tree_root "$_bb_root")
            _bb_candidate="$_bb_prefix$2"
            if [ -e "$_bb_candidate" ]; then
                printf '%s' "$_bb_candidate"
                return 0
            fi
            if [ "$_bb_prefix" = "$_bb_root" ]; then
                _bb_candidate="$_bb_root/system$2"
                if [ -e "$_bb_candidate" ]; then
                    printf '%s' "$_bb_candidate"
                    return 0
                fi
            fi
            ;;
    esac
    return 1
}

baseband_tree_hash() {
    _bb_root="$1"
    [ -d "$_bb_root" ] || return 1
    _bb_manifest=$(find "$_bb_root" -type f 2>/dev/null | sort | while IFS= read -r _bb_file; do
        case "$_bb_file" in
            "$_bb_root"/*) _bb_rel=${_bb_file#"$_bb_root"/} ;;
            *) _bb_rel=$_bb_file ;;
        esac
        _bb_digest=$(baseband_sha256 "$_bb_file" 2>/dev/null || printf missing)
        printf '%s|%s\n' "$_bb_rel" "$_bb_digest"
    done)
    baseband_sha256_text "$_bb_manifest"
}

baseband_payload_tree_hash() {
    _bb_root=$(baseband_payload_tree_root "$1" 2>/dev/null) || return 1
    _bb_manifest=$(for _bb_partition in product vendor; do
        _bb_partition_root="$_bb_root/$_bb_partition"
        [ -d "$_bb_partition_root" ] || continue
        find "$_bb_partition_root" -type f 2>/dev/null | while IFS= read -r _bb_file; do
            case "$_bb_file" in
                "$_bb_root"/*) _bb_rel=${_bb_file#"$_bb_root"/} ;;
                *) _bb_rel=$_bb_file ;;
            esac
            _bb_digest=$(baseband_sha256 "$_bb_file" 2>/dev/null || printf missing)
            printf '%s|%s\n' "$_bb_rel" "$_bb_digest"
        done
    done | sort)
    [ -n "$_bb_manifest" ] || return 1
    baseband_sha256_text "$_bb_manifest"
}

baseband_mountpoint_overlay() {
    _bb_mountpoint="$1"
    [ -r "$BASEBAND_MOUNTINFO_PATH" ] || return 1
    awk -v wanted="$_bb_mountpoint" '$5 == wanted && $0 ~ / - overlay / { found=1 } END { exit(found ? 0 : 1) }' \
        "$BASEBAND_MOUNTINFO_PATH" 2>/dev/null
}

baseband_mount_observed() {
    case "$1" in
        Magisk)
            printf 'not_required_magisk'
            return 0
            ;;
        APatch|KernelSU)
            _bb_product=0
            _bb_vendor=0
            baseband_mountpoint_overlay /product && _bb_product=1
            baseband_mountpoint_overlay /vendor && _bb_vendor=1
            if [ "$_bb_product" -eq 1 ] && [ "$_bb_vendor" -eq 1 ]; then
                printf 'yes'
            else
                printf 'no'
            fi
            return 0
            ;;
        *)
            printf 'unknown'
            return 1
            ;;
    esac
}

baseband_append_error() {
    if [ -n "$BB_ERRORS" ]; then
        BB_ERRORS="$BB_ERRORS,$1"
    else
        BB_ERRORS="$1"
    fi
    BB_STATUS=FAIL
}

baseband_write_status() {
    # A directory at the receipt path can make `mv tmp directory` return 0
    # while leaving the actual receipt absent.  Treat that shape as a write
    # failure instead of publishing a false success state.
    [ ! -d "$BASEBAND_STATUS" ] || return 1
    _bb_tmp="${BASEBAND_STATUS}.tmp.$$"
    if ! {
        printf 'schema=3\n'
        printf 'status=%s\n' "$BB_STATUS"
        printf 'phase=%s\n' "$BB_PHASE"
        printf 'device=%s\n' "$BB_DEVICE"
        printf 'root_impl=%s\n' "$BB_ROOT_IMPL"
        printf 'module_dir=%s\n' "$BASEBAND_MODDIR"
        printf 'content_image=%s\n' "${BB_CONTENT_ROOT:-missing}"
        printf 'source_path=%s\n' "$BB_SOURCE_PATH"
        printf 'effective_path=%s\n' "$BB_EFFECTIVE_PATH"
        printf 'source_hash=%s\n' "${BB_SOURCE_HASH:-unknown}"
        printf 'source_contract_hash=%s\n' "${BB_SOURCE_CONTRACT_HASH:-unknown}"
        printf 'effective_hash=%s\n' "${BB_EFFECTIVE_HASH:-unknown}"
        printf 'effective_contract_hash=%s\n' "${BB_EFFECTIVE_CONTRACT_HASH:-unknown}"
        printf 'effective_contract_verified=%s\n' "${BB_EFFECTIVE_CONTRACT_VERIFIED:-no}"
        printf 'effective_extra_files_allowed=%s\n' "${BB_EFFECTIVE_EXTRA_FILES_ALLOWED:-yes}"
        printf 'content_contract_hash=%s\n' "${BB_CONTENT_CONTRACT_HASH:-unknown}"
        printf 'content_image_hash=%s\n' "${BB_CONTENT_IMAGE_HASH:-unknown}"
        printf 'source_tree_hash=%s\n' "${BB_SOURCE_TREE_HASH:-unknown}"
        printf 'content_tree_hash=%s\n' "${BB_CONTENT_TREE_HASH:-unknown}"
        printf 'source_contract_verified=%s\n' "$BB_SOURCE_CONTRACT_VERIFIED"
        printf 'content_image_verified=%s\n' "$BB_CONTENT_IMAGE_VERIFIED"
        printf 'mount_observed=%s\n' "$BB_MOUNT_OBSERVED"
        printf 'effective_overlay_verified=%s\n' "$BB_EFFECTIVE_OVERLAY_VERIFIED"
        printf 'prior_receipt_freshness=%s\n' "$BB_PRIOR_RECEIPT_FRESHNESS"
        printf 'current_runtime_check_freshness=%s\n' "$BB_CURRENT_RUNTIME_CHECK_FRESHNESS"
        printf 'runtime_receipt_freshness=%s\n' "$BB_RECEIPT_FRESHNESS"
        printf 'boot_id=%s\n' "$BB_BOOT_ID"
        printf 'migration_state=%s\n' "$BB_MIGRATION_STATE"
        printf 'clean_reinstall_required=%s\n' "$BB_CLEAN_REINSTALL_REQUIRED"
        printf 'carrier_settings_files=%s\n' "${BB_CARRIER_COUNT:-0}"
        printf 'china_mcfg_files=%s\n' "${BB_MCFG_COUNT:-0}"
        printf 'carrier_list_sha256=%s\n' "${BB_CARRIER_HASH:-missing}"
        printf 'apns_conf_sha256=%s\n' "${BB_APN_HASH:-missing}"
        printf 'errors=%s\n' "${BB_ERRORS:-none}"
        printf 'timestamp=%s\n' "$(date +%s 2>/dev/null || printf unknown)"
    } > "$_bb_tmp" 2>/dev/null; then
        rm -f "$_bb_tmp" 2>/dev/null || true
        return 1
    fi
    if ! mv -f "$_bb_tmp" "$BASEBAND_STATUS" 2>/dev/null; then
        rm -f "$_bb_tmp" 2>/dev/null || true
        return 1
    fi
    return 0
}

baseband_write_migration_state() {
    # Keep the standalone migration marker aligned with the verified runtime
    # receipt. The installer writes the pre-reboot state; post-mount/service
    # must atomically publish the final observed state instead of leaving a
    # stale pending marker beside a PASS receipt.
    [ -n "$BASEBAND_MIGRATION_STATE_FILE" ] || return 1
    [ ! -d "$BASEBAND_MIGRATION_STATE_FILE" ] || return 1
    _bb_migration_tmp="${BASEBAND_MIGRATION_STATE_FILE}.tmp.$$"
    if ! printf '%s\n' "$1" > "$_bb_migration_tmp" 2>/dev/null; then
        rm -f "$_bb_migration_tmp" 2>/dev/null || true
        return 1
    fi
    if ! mv -f "$_bb_migration_tmp" "$BASEBAND_MIGRATION_STATE_FILE" 2>/dev/null; then
        rm -f "$_bb_migration_tmp" 2>/dev/null || true
        return 1
    fi
    return 0
}

baseband_runtime_check() {
    BB_PHASE="${1:-runtime}"
    BB_STATUS=PASS
    BB_ERRORS=""
    BB_DEVICE=$(baseband_device)
    BB_ROOT_IMPL=$(baseband_detect_root_impl)
    BB_BOOT_ID=$(baseband_boot_id)
    BB_SOURCE_PATH="$BASEBAND_SOURCE_ROOT"
    BB_EFFECTIVE_PATH="/product,/vendor"
    BB_SOURCE_HASH=unknown
    BB_SOURCE_CONTRACT_HASH=unknown
    BB_EFFECTIVE_HASH=unknown
    BB_CONTENT_CONTRACT_HASH=unknown
    BB_EFFECTIVE_CONTRACT_HASH=unknown
    BB_EFFECTIVE_CONTRACT_VERIFIED=no
    BB_EFFECTIVE_EXTRA_FILES_ALLOWED=yes
    BB_CONTENT_IMAGE_HASH=unknown
    BB_SOURCE_TREE_HASH=not_collected
    BB_CONTENT_TREE_HASH=not_collected
    BB_SOURCE_CONTRACT_VERIFIED=no
    BB_CONTENT_IMAGE_VERIFIED=not_required_magisk
    BB_MOUNT_OBSERVED=unknown
    BB_EFFECTIVE_OVERLAY_VERIFIED=no
    BB_PRIOR_RECEIPT_FRESHNESS=missing
    BB_CURRENT_RUNTIME_CHECK_FRESHNESS=pending
    BB_RECEIPT_FRESHNESS=not_written
    BB_MIGRATION_STATE=$(cat "$BASEBAND_MIGRATION_STATE_FILE" 2>/dev/null | baseband_trim)
    BB_CLEAN_REINSTALL_REQUIRED=no
    BB_CARRIER_COUNT=0
    BB_MCFG_COUNT=0
    BB_CARRIER_HASH=missing
    BB_APN_HASH=missing

    if [ -z "$BASEBAND_SOURCE_ROOT" ]; then
        BASEBAND_SOURCE_ROOT=$(baseband_source_root "$BASEBAND_MODDIR")
    fi
    BB_SOURCE_PATH="$BASEBAND_SOURCE_ROOT"
    # A complete tree hash is diagnostic-only and is deliberately not collected
    # on-device.  It is expensive for the 3210-file CarrierSettings tree and
    # cannot represent the merged OverlayFS view correctly.

    case "$BB_DEVICE" in caiman|komodo) ;; *) baseband_append_error device ;; esac
    case "$BB_ROOT_IMPL" in APatch|KernelSU|Magisk) ;; *) baseband_append_error root_impl ;; esac
    [ -f "$BASEBAND_CONTRACT" ] || baseband_append_error contract_missing

    BB_CONTENT_ROOT=""
    case "$BB_ROOT_IMPL" in
        APatch|KernelSU)
            BB_CONTENT_IMAGE_VERIFIED=no
            BB_CONTENT_ROOT=$(baseband_content_root 2>/dev/null) || baseband_append_error content_image_missing
            ;;
    esac
    # Content image integrity is checked through its declared rows below.  A
    # full image/tree hash is not a correctness gate for a relocated module.
    BB_CONTENT_IMAGE_HASH=not_collected

    _bb_source_rows=""
    _bb_effective_rows=""
    _bb_content_rows=""
    _bb_source_ok=1
    _bb_content_ok=1
    _bb_effective_ok=1
    if [ -f "$BASEBAND_CONTRACT" ]; then
        while IFS='|' read -r _bb_key _bb_path _bb_kind _bb_expected; do
            case "$_bb_key" in ''|\#*) continue ;; esac
            _bb_source=$(baseband_source_path "$_bb_path" 2>/dev/null) || {
                _bb_source_ok=0
                baseband_append_error "${_bb_key}_source_path"
                continue
            }
            _bb_effective=$(baseband_effective_path "$_bb_path" 2>/dev/null) || {
                _bb_effective_ok=0
                baseband_append_error "${_bb_key}_effective_path"
                continue
            }
            _bb_content=""
            [ -n "$BB_CONTENT_ROOT" ] && _bb_content=$(baseband_content_path "$BB_CONTENT_ROOT" "$_bb_path" 2>/dev/null || true)

            case "$_bb_kind" in
                sha256)
                    _bb_source_hash=$(baseband_sha256 "$_bb_source" 2>/dev/null || printf missing)
                    _bb_effective_hash=$(baseband_sha256 "$_bb_effective" 2>/dev/null || printf missing)
                    [ "$_bb_source_hash" = "$_bb_expected" ] || {
                        _bb_source_ok=0
                        baseband_append_error "${_bb_key}_source_hash"
                    }
                    [ "$_bb_effective_hash" = "$_bb_expected" ] || {
                        _bb_effective_ok=0
                        baseband_append_error "${_bb_key}_effective_hash"
                    }
                    _bb_source_rows="$_bb_source_rows$_bb_key=sha256=$_bb_source_hash
"
                    _bb_effective_rows="$_bb_effective_rows$_bb_key=sha256=$_bb_effective_hash
"
                    if [ -n "$BB_CONTENT_ROOT" ]; then
                        _bb_content_hash=$(baseband_sha256 "$_bb_content" 2>/dev/null || printf missing)
                        [ -n "$_bb_content" ] && [ "$_bb_content_hash" = "$_bb_expected" ] || {
                            _bb_content_ok=0
                            baseband_append_error "${_bb_key}_content_hash"
                        }
                        _bb_content_rows="$_bb_content_rows$_bb_key=sha256=$_bb_content_hash
"
                    fi
                    [ "$_bb_key" = carrier_list ] && BB_CARRIER_HASH="$_bb_effective_hash"
                    [ "$_bb_key" = apn ] && BB_APN_HASH="$_bb_effective_hash"
                    ;;
                exists)
                    [ "$_bb_expected" = 1 ] && [ -e "$_bb_source" ] || {
                        _bb_source_ok=0
                        baseband_append_error "${_bb_key}_source_missing"
                    }
                    [ "$_bb_expected" = 1 ] && [ -e "$_bb_effective" ] || {
                        _bb_effective_ok=0
                        baseband_append_error "${_bb_key}_effective_missing"
                    }
                    if [ -n "$BB_CONTENT_ROOT" ]; then
                        [ -n "$_bb_content" ] || {
                            _bb_content_ok=0
                            baseband_append_error "${_bb_key}_content_missing"
                        }
                    fi
                    _bb_source_rows="$_bb_source_rows$_bb_key=exists=$( [ -e "$_bb_source" ] && printf yes || printf no )
"
                    _bb_effective_rows="$_bb_effective_rows$_bb_key=exists=$( [ -e "$_bb_effective" ] && printf yes || printf no )
"
                    if [ -n "$BB_CONTENT_ROOT" ]; then
                        _bb_content_rows="$_bb_content_rows$_bb_key=exists=$( [ -n "$_bb_content" ] && [ -e "$_bb_content" ] && printf yes || printf no )
"
                    fi
                    ;;
                min_file_count)
                    _bb_source_count=$(baseband_file_count "$_bb_source")
                    _bb_effective_count=$(baseband_file_count "$_bb_effective")
                    case "$_bb_expected" in ''|*[!0-9]*)
                        _bb_source_ok=0
                        baseband_append_error "${_bb_key}_contract"
                        ;;
                    esac
                    [ "$_bb_source_count" -ge "$_bb_expected" ] 2>/dev/null || {
                        _bb_source_ok=0
                        baseband_append_error "${_bb_key}_source_count"
                    }
                    [ "$_bb_effective_count" -ge "$_bb_expected" ] 2>/dev/null || {
                        _bb_effective_ok=0
                        baseband_append_error "${_bb_key}_effective_count"
                    }
                    if [ -n "$BB_CONTENT_ROOT" ]; then
                        _bb_content_count=$(baseband_file_count "$_bb_content")
                        [ "$_bb_content_count" -ge "$_bb_expected" ] 2>/dev/null || {
                            _bb_content_ok=0
                            baseband_append_error "${_bb_key}_content_count"
                        }
                    fi
                    _bb_source_rows="$_bb_source_rows$_bb_key=count=$_bb_source_count
"
                    _bb_effective_rows="$_bb_effective_rows$_bb_key=count=$_bb_effective_count
"
                    if [ -n "$BB_CONTENT_ROOT" ]; then
                        _bb_content_rows="$_bb_content_rows$_bb_key=count=$_bb_content_count
"
                    fi
                    [ "$_bb_key" = carrier_settings ] && BB_CARRIER_COUNT="$_bb_effective_count"
                    [ "$_bb_key" = china_mcfg ] && BB_MCFG_COUNT="$_bb_effective_count"
                    ;;
                *)
                    _bb_source_ok=0
                    _bb_effective_ok=0
                    _bb_content_ok=0
                    baseband_append_error "${_bb_key}_kind"
                    ;;
            esac
        done < "$BASEBAND_CONTRACT"
    fi

    BB_SOURCE_CONTRACT_HASH=$(baseband_sha256_text "$_bb_source_rows" 2>/dev/null || printf unknown)
    BB_CONTENT_CONTRACT_HASH=$(baseband_sha256_text "$_bb_content_rows" 2>/dev/null || printf unknown)
    BB_EFFECTIVE_CONTRACT_HASH=$(baseband_sha256_text "$_bb_effective_rows" 2>/dev/null || printf unknown)
    # Compatibility aliases retained for older Control consumers.  They now
    # identify the corresponding contract layer instead of an aggregate tree.
    BB_SOURCE_HASH="$BB_SOURCE_CONTRACT_HASH"
    BB_EFFECTIVE_HASH="$BB_EFFECTIVE_CONTRACT_HASH"
    [ "$_bb_source_ok" -eq 1 ] && BB_SOURCE_CONTRACT_VERIFIED=yes
    if [ -n "$BB_CONTENT_ROOT" ]; then
        [ "$_bb_content_ok" -eq 1 ] && BB_CONTENT_IMAGE_VERIFIED=yes
    fi
    [ "$_bb_effective_ok" -eq 1 ] && BB_EFFECTIVE_CONTRACT_VERIFIED=yes

    BB_MOUNT_OBSERVED=$(baseband_mount_observed "$BB_ROOT_IMPL" 2>/dev/null || printf unknown)
    case "$BB_ROOT_IMPL:$BB_MOUNT_OBSERVED" in
        APatch:no|KernelSU:no) baseband_append_error mount_not_observed ;;
        APatch:unknown|KernelSU:unknown) baseband_append_error mount_unknown ;;
        Unknown:*) baseband_append_error mount_root_unknown ;;
    esac

    # The old file is diagnostic only. A readable current boot ID is not proof
    # that the old receipt belongs to this boot or that its checks passed.
    _bb_prior_schema=$(sed -n 's/^schema=//p' "$BASEBAND_STATUS" 2>/dev/null | head -n 1 | baseband_trim)
    _bb_prior_boot=$(sed -n 's/^boot_id=//p' "$BASEBAND_STATUS" 2>/dev/null | head -n 1 | baseband_trim)
    _bb_prior_status=$(sed -n 's/^status=//p' "$BASEBAND_STATUS" 2>/dev/null | head -n 1 | baseband_trim)
    _bb_prior_effective=$(sed -n 's/^effective_overlay_verified=//p' "$BASEBAND_STATUS" 2>/dev/null | head -n 1 | baseband_trim)
    _bb_prior_receipt=$(sed -n 's/^runtime_receipt_freshness=//p' "$BASEBAND_STATUS" 2>/dev/null | head -n 1 | baseband_trim)
    if [ ! -f "$BASEBAND_STATUS" ]; then
        BB_PRIOR_RECEIPT_FRESHNESS=missing
    elif [ "$BB_BOOT_ID" = unknown ] || [ -z "$BB_BOOT_ID" ]; then
        BB_PRIOR_RECEIPT_FRESHNESS=unverifiable_boot
        baseband_append_error boot_id_unknown
    elif [ "$_bb_prior_boot" != "$BB_BOOT_ID" ]; then
        BB_PRIOR_RECEIPT_FRESHNESS=cross_boot
    elif [ "$_bb_prior_schema" != 3 ] || [ "$_bb_prior_status" != PASS ] \
        || [ "$_bb_prior_effective" != yes ] || [ "$_bb_prior_receipt" != current_check ]; then
        BB_PRIOR_RECEIPT_FRESHNESS=stale_or_unverified
    else
        BB_PRIOR_RECEIPT_FRESHNESS=current_boot_verified
    fi
    if [ "$BB_BOOT_ID" = unknown ] || [ -z "$BB_BOOT_ID" ]; then
        baseband_append_error boot_id_unknown
    fi

    if [ "$BB_SOURCE_CONTRACT_VERIFIED" = yes ] \
        && { [ "$BB_ROOT_IMPL" = Magisk ] || [ "$BB_CONTENT_IMAGE_VERIFIED" = yes ]; } \
        && [ "$BB_EFFECTIVE_CONTRACT_VERIFIED" = yes ] \
        && [ "$BB_MOUNT_OBSERVED" != no ] && [ "$BB_MOUNT_OBSERVED" != unknown ] \
        && [ "$BB_STATUS" = PASS ]; then
        BB_EFFECTIVE_OVERLAY_VERIFIED=yes
        BB_MIGRATION_STATE=effective_overlay_verified
        BB_CLEAN_REINSTALL_REQUIRED=no
    else
        BB_EFFECTIVE_OVERLAY_VERIFIED=no
        BB_CLEAN_REINSTALL_REQUIRED=yes
        BB_MIGRATION_STATE=clean_reinstall_required
    fi

    _bb_migration_state_write_ok=1
    if ! baseband_write_migration_state "$BB_MIGRATION_STATE"; then
        _bb_migration_state_write_ok=0
        BB_STATUS=FAIL
        BB_EFFECTIVE_OVERLAY_VERIFIED=no
        BB_CLEAN_REINSTALL_REQUIRED=yes
        BB_MIGRATION_STATE=clean_reinstall_required
        baseband_append_error migration_state_write_failed
    fi

    # These markers describe the receipt that is about to be committed. They
    # are not inferred from the readable boot ID or from the previous file.
    BB_CURRENT_RUNTIME_CHECK_FRESHNESS=current_check
    BB_RECEIPT_FRESHNESS=current_check
    if [ "$_bb_migration_state_write_ok" -ne 1 ]; then
        BB_CURRENT_RUNTIME_CHECK_FRESHNESS=write_failed
        BB_RECEIPT_FRESHNESS=not_written
    fi
    if ! baseband_write_status; then
        BB_STATUS=FAIL
        BB_EFFECTIVE_OVERLAY_VERIFIED=no
        BB_CLEAN_REINSTALL_REQUIRED=yes
        BB_CURRENT_RUNTIME_CHECK_FRESHNESS=write_failed
        BB_RECEIPT_FRESHNESS=not_written
        baseband_append_error status_write_failed
    fi
    baseband_log "phase=$BB_PHASE status=$BB_STATUS device=$BB_DEVICE root=$BB_ROOT_IMPL content=${BB_CONTENT_ROOT:-missing} mount=$BB_MOUNT_OBSERVED effective=$BB_EFFECTIVE_OVERLAY_VERIFIED prior_receipt=$BB_PRIOR_RECEIPT_FRESHNESS current_receipt=$BB_CURRENT_RUNTIME_CHECK_FRESHNESS errors=${BB_ERRORS:-none}"
    [ "$BB_STATUS" = PASS ] && [ "$BB_EFFECTIVE_OVERLAY_VERIFIED" = yes ]
}
