#!/system/bin/sh

# pixel9pro_baseband_trial installer contract
#
# APatch 11219+ and KernelSU with a MetaModule move system/ overlays into the
# active MetaModule content image. This module deliberately does not mount or
# write that image itself; it only verifies the active contract and leaves the
# move to the framework's metainstall.sh hook.

ADB_ROOT="${BASEBAND_ADB_ROOT:-/data/adb}"
BASEBAND_MODULE_ID="pixel9pro_baseband_trial"
DEVICE_MANIFEST="$MODPATH/config/baseband_devices.tsv"
MIGRATION_STATE_FILE="$MODPATH/.migration_state"
BASEBAND_BOOT_ID_PATH="${BASEBAND_BOOT_ID_PATH:-/proc/sys/kernel/random/boot_id}"
BASEBAND_MOUNTINFO_PATH="${BASEBAND_MOUNTINFO_PATH:-/proc/self/mountinfo}"
ACTIVE_METAMODULE=""
METAMODULE_STATE=""
METAMODULE_REASON=""
MIGRATION_STATE="fresh_install_pending_reboot"
MIGRATION_REASON=""

device=$(getprop ro.product.device 2>/dev/null | tr -d ' \n\r\t')
[ -n "$device" ] || device=$(getprop ro.build.product 2>/dev/null | tr -d ' \n\r\t')

installer_fail() {
    _message="$1"
    ui_print "  ✗ $_message"
    if type abort >/dev/null 2>&1; then
        abort "$_message"
    fi
    return 1
}

load_device_contract() {
    DEVICE_LABEL=""
    UECAP_POLICY=""

    [ -f "$DEVICE_MANIFEST" ] || return 1
    while IFS='|' read -r _device _label _policy _source_rel _target_name _bytes _sha256; do
        case "$_device" in ''|\#*) continue ;; esac
        [ "$_device" = "$device" ] || continue
        DEVICE_LABEL="$_label"
        UECAP_POLICY="$_policy"
        UECAP_SOURCE_REL="$_source_rel"
        UECAP_TARGET_NAME="$_target_name"
        UECAP_BYTES="$_bytes"
        UECAP_SHA256="$_sha256"
        break
    done < "$DEVICE_MANIFEST"

    [ -n "$DEVICE_LABEL" ] || return 2
    [ "$UECAP_POLICY" = "external" ] || return 1
    [ -z "$UECAP_SOURCE_REL$UECAP_TARGET_NAME$UECAP_BYTES$UECAP_SHA256" ]
}

resolve_metamodule_target() {
    _link="$ADB_ROOT/metamodule"
    _target=""
    _raw=""

    [ -L "$_link" ] || {
        METAMODULE_REASON="active /data/adb/metamodule link is missing"
        return 1
    }

    _raw=$(readlink "$_link" 2>/dev/null)
    [ -n "$_raw" ] || {
        METAMODULE_REASON="active /data/adb/metamodule symlink is unreadable"
        return 1
    }
    case "$_raw" in
        /*) _target="$_raw" ;;
        *) _target="$(dirname "$_link")/$_raw" ;;
    esac

    [ -d "$_target" ] || {
        METAMODULE_REASON="active MetaModule target is not a directory"
        return 1
    }
    [ -f "$_target/module.prop" ] || {
        METAMODULE_REASON="active MetaModule module.prop is missing"
        return 1
    }
    _marker=$(sed -n 's/^metamodule=//p' "$_target/module.prop" 2>/dev/null | head -n 1 | tr -d ' \n\r\t')
    [ "$_marker" = "1" ] || {
        METAMODULE_REASON="active target does not declare metamodule=1"
        return 1
    }
    [ ! -e "$_target/disable" ] || {
        METAMODULE_REASON="active MetaModule is disabled"
        return 1
    }
    [ -d "$_target/mnt" ] || {
        METAMODULE_REASON="active MetaModule content directory is missing"
        return 1
    }

    ACTIVE_METAMODULE="$_target"
    METAMODULE_STATE="active"
    return 0
}

find_declared_metamodule() {
    # Compatibility fallback for older KernelSU layouts without the symlink.
    # No product/module name is assumed; exactly one enabled marker is required.
    _found=""
    for _base in "$ADB_ROOT/modules" "$ADB_ROOT/modules_update"; do
        [ -d "$_base" ] || continue
        for _dir in "$_base"/*; do
            [ -d "$_dir" ] || continue
            [ -f "$_dir/module.prop" ] || continue
            _marker=$(sed -n 's/^metamodule=//p' "$_dir/module.prop" 2>/dev/null | head -n 1 | tr -d ' \n\r\t')
            [ "$_marker" = "1" ] || continue
            [ ! -e "$_dir/disable" ] || continue
            [ -d "$_dir/mnt" ] || continue
            if [ -n "$_found" ] && [ "$_found" != "$_dir" ]; then
                METAMODULE_REASON="multiple enabled modules declare metamodule=1"
                return 1
            fi
            _found="$_dir"
        done
    done
    [ -n "$_found" ] || return 1
    ACTIVE_METAMODULE="$_found"
    METAMODULE_STATE="marker-only"
    return 0
}

detect_active_metamodule() {
    ACTIVE_METAMODULE=""
    METAMODULE_STATE=""
    METAMODULE_REASON=""
    if resolve_metamodule_target; then
        return 0
    fi
    find_declared_metamodule && return 0
    [ -n "$METAMODULE_REASON" ] || METAMODULE_REASON="no enabled module declares metamodule=1"
    return 1
}

load_runtime_helpers() {
    # Reuse the runtime contract's tree/layout/mount helpers during the
    # install-time migration decision.  Sourcing this file has no side effect;
    # the runtime check itself is only called after reboot by post-mount/service.
    [ -f "$MODPATH/scripts/baseband_runtime.sh" ] || {
        MIGRATION_REASON="新版模块缺少共享 runtime contract helper"
        return 1
    }
    BASEBAND_ADB_ROOT="$ADB_ROOT"
    BASEBAND_MODULE_ID="$BASEBAND_MODULE_ID"
    BASEBAND_METAMODULE_LINK="$ADB_ROOT/metamodule"
    BASEBAND_MOUNTINFO_PATH="$BASEBAND_MOUNTINFO_PATH"
    . "$MODPATH/scripts/baseband_runtime.sh"
}

migration_receipt_value() {
    _receipt="$1"
    _key="$2"
    _default="${3:-}"
    _value=""
    [ -f "$_receipt" ] && _value=$(sed -n "s/^${_key}=//p" "$_receipt" 2>/dev/null | head -n 1 | tr -d ' \n\r\t')
    [ -n "$_value" ] && printf '%s' "$_value" || printf '%s' "$_default"
}

migration_current_boot_id() {
    _boot=$(cat "$BASEBAND_BOOT_ID_PATH" 2>/dev/null | tr -d ' \n\r\t')
    [ -n "$_boot" ] || _boot=$(getprop ro.boot.boot_id 2>/dev/null | tr -d ' \n\r\t')
    case "$_boot" in
        ''|*[!A-Za-z0-9._:-]*) printf 'unknown' ;;
        *) printf '%s' "$_boot" ;;
    esac
}

migration_contract_rows() {
    _root_kind="$1"
    _contract="$2"
    _rows=""
    _nl=$(printf '\nx')
    _nl=${_nl%x}
    [ -f "$_contract" ] || return 1
    while IFS='|' read -r _key _path _kind _expected; do
        case "$_key" in ''|\#*) continue ;; esac
        _file=""
        case "$_root_kind" in
            source) _file="$_MIGRATION_SOURCE_ROOT$_path" ;;
            effective) _file=$(baseband_effective_path "$_path" 2>/dev/null) || return 1 ;;
            content) _file=$(baseband_content_path "$_MIGRATION_CONTENT_ROOT" "$_path" 2>/dev/null || true) ;;
            *) return 1 ;;
        esac
        case "$_kind" in
            sha256)
                _value=$(baseband_sha256 "$_file" 2>/dev/null || printf missing)
                _rows="${_rows}${_key}=sha256=${_value}${_nl}"
                ;;
            exists)
                [ "$_expected" = 1 ] && [ -e "$_file" ] && _value=yes || _value=no
                _rows="${_rows}${_key}=exists=${_value}${_nl}"
                ;;
            min_file_count)
                _value=$(baseband_file_count "$_file")
                _rows="${_rows}${_key}=count=${_value}${_nl}"
                ;;
            *) return 1 ;;
        esac
    done < "$_contract"
    printf '%s' "$_rows"
}

module_path_equal() {
    _left="${1%/}"
    _right="${2%/}"
    [ -n "$_left" ] && [ -n "$_right" ] && [ "$_left" = "$_right" ]
}

module_dir_is_empty() {
    [ -d "$1" ] || return 1
    [ -z "$(find "$1" -mindepth 1 -print -quit 2>/dev/null)" ]
}

baseband_migration_receipt_check() {
    _old_module="$1"
    _receipt="$_old_module/.runtime_status"
    _current_boot=$(migration_current_boot_id)
    _receipt_boot=$(migration_receipt_value "$_receipt" boot_id unknown)
    [ -f "$_receipt" ] || {
        MIGRATION_REASON="旧模块 runtime receipt 缺失"
        return 1
    }
    [ "$(migration_receipt_value "$_receipt" schema unknown)" = 3 ] || {
        MIGRATION_REASON="旧模块使用旧版或未知 runtime receipt schema；必须先卸载旧版普通基带模块、重启，再安装新版"
        return 1
    }
    [ "$_current_boot" != unknown ] && [ "$_receipt_boot" = "$_current_boot" ] || {
        MIGRATION_REASON="旧模块 runtime receipt 不属于当前 boot"
        return 1
    }
    [ "$(migration_receipt_value "$_receipt" status missing)" = PASS ] \
        && [ "$(migration_receipt_value "$_receipt" effective_overlay_verified no)" = yes ] \
        && [ "$(migration_receipt_value "$_receipt" source_contract_verified no)" = yes ] \
        && [ "$(migration_receipt_value "$_receipt" current_runtime_check_freshness missing)" = current_check ] \
        && [ "$(migration_receipt_value "$_receipt" runtime_receipt_freshness missing)" = current_check ] \
        && [ "$(migration_receipt_value "$_receipt" clean_reinstall_required yes)" = no ] || {
        MIGRATION_REASON="旧模块没有当前 boot 的完整有效 Overlay 复读收据"
        return 1
    }
    _migration_source_root=$(baseband_source_root "$_old_module" 2>/dev/null || true)
    [ -d "$_migration_source_root" ] || {
        MIGRATION_REASON="旧模块 active source root 缺失"
        return 1
    }
    [ "$(migration_receipt_value "$_receipt" module_dir missing)" = "$_old_module" ] \
        && [ "$(migration_receipt_value "$_receipt" source_path missing)" = "$_migration_source_root" ] || {
        MIGRATION_REASON="旧模块 runtime receipt 的 source/module 路径与 active module 不一致"
        return 1
    }
    _source_contract_hash=$(migration_receipt_value "$_receipt" source_contract_hash unknown)
    [ "$_source_contract_hash" = unknown ] && _source_contract_hash=$(migration_receipt_value "$_receipt" source_hash unknown)
    _content_contract_hash=$(migration_receipt_value "$_receipt" content_contract_hash unknown)
    _effective_contract_hash=$(migration_receipt_value "$_receipt" effective_contract_hash unknown)
    _effective_verified=$(migration_receipt_value "$_receipt" effective_contract_verified no)
    case "$_source_contract_hash:$_content_contract_hash:$_effective_contract_hash" in
        *unknown*|*missing*)
            MIGRATION_REASON="旧模块 source/content/effective contract hash 不完整"
            return 1
            ;;
    esac
    [ "$_effective_verified" = yes ] || {
        MIGRATION_REASON="旧模块 effective declared contract 未验证"
        return 1
    }
    [ "$(find "$_migration_source_root/product" -type f 2>/dev/null | head -n 1)$(find "$_migration_source_root/vendor" -type f 2>/dev/null | head -n 1)" ] || {
        MIGRATION_REASON="旧模块 active source tree 缺失或为空"
        return 1
    }
    [ -n "$ACTIVE_METAMODULE" ] || {
        MIGRATION_REASON="活动 MetaModule 未确认"
        return 1
    }
    _content_root="$ACTIVE_METAMODULE/mnt/$BASEBAND_MODULE_ID"
    baseband_content_layout_valid "$_content_root" || {
        MIGRATION_REASON="旧模块 MetaModule content image 结构无效或为空"
        return 1
    }
    _content_tree_root=$(baseband_content_tree_root "$_content_root")
    [ "$(find "$_content_tree_root" -type f 2>/dev/null | head -n 1)" ] || {
        MIGRATION_REASON="旧模块 MetaModule content image 为空"
        return 1
    }
    [ "$(migration_receipt_value "$_receipt" content_image missing)" = "$_content_root" ] || {
        MIGRATION_REASON="旧模块 runtime receipt 的 content image 路径不一致"
        return 1
    }
    # Do not require full tree/image hashes here.  Relocation may add a
    # compatibility directory and effective OverlayFS may merge stock files;
    # the declared rows are the migration proof.
    _MIGRATION_SOURCE_ROOT="$_migration_source_root"
    _MIGRATION_CONTENT_ROOT="$_content_root"
    _old_contract="$_old_module/config/runtime_contract.tsv"
    _actual_source_rows=$(migration_contract_rows source "$_old_contract" 2>/dev/null; printf '_')
    _actual_source_rows=${_actual_source_rows%_}
    _actual_effective_rows=$(migration_contract_rows effective "$_old_contract" 2>/dev/null; printf '_')
    _actual_effective_rows=${_actual_effective_rows%_}
    _actual_content_rows=$(migration_contract_rows content "$_old_contract" 2>/dev/null; printf '_')
    _actual_content_rows=${_actual_content_rows%_}
    _actual_source_contract_hash=$(baseband_sha256_text "$_actual_source_rows" 2>/dev/null || printf unknown)
    _actual_effective_contract_hash=$(baseband_sha256_text "$_actual_effective_rows" 2>/dev/null || printf unknown)
    _actual_content_contract_hash=$(baseband_sha256_text "$_actual_content_rows" 2>/dev/null || printf unknown)
    [ "$_actual_source_contract_hash" = "$_source_contract_hash" ] \
        && [ "$_actual_effective_contract_hash" = "$_effective_contract_hash" ] \
        && [ "$_actual_content_contract_hash" = "$_content_contract_hash" ] || {
        MIGRATION_REASON="旧模块各层 declared contract hash 与 receipt 不一致"
        return 1
    }
    case "$ROOT_IMPL" in
        APatch|KernelSU)
            [ "$(migration_receipt_value "$_receipt" root_impl unknown)" = "$ROOT_IMPL" ] \
                && [ "$(migration_receipt_value "$_receipt" content_image_verified no)" = yes ] \
                && [ "$(migration_receipt_value "$_receipt" mount_observed no)" = yes ] \
                && [ "$(baseband_mount_observed "$ROOT_IMPL" 2>/dev/null || printf unknown)" = yes ] || {
                MIGRATION_REASON="旧模块 MetaModule/mount 当前状态无法确认"
                return 1
            }
            ;;
        Magisk)
            return 1
            ;;
    esac
    return 0
}

baseband_migration_check() {
    # A Manager update is not a module migration. A normal module update may
    # keep the active ordinary module while the current package is staged in
    # modules_update. Any second, unrelated pending copy or an uncertain
    # active/content/receipt state requires clean reinstall.
    MIGRATION_STATE="fresh_install_pending_reboot"
    MIGRATION_REASON=""
    _old_module=""
    _active_module="$ADB_ROOT/modules/$BASEBAND_MODULE_ID"
    _pending_module="$ADB_ROOT/modules_update/$BASEBAND_MODULE_ID"
    if [ -d "$_pending_module" ] && ! module_path_equal "$_pending_module" "$MODPATH"; then
        if ! module_dir_is_empty "$_pending_module"; then
            MIGRATION_STATE="clean_reinstall_required"
            MIGRATION_REASON="active module 与另一个 pending update 同时存在"
            return 1
        fi
    fi
    if [ -d "$_active_module" ] && ! module_path_equal "$_active_module" "$MODPATH"; then
        if ! module_dir_is_empty "$_active_module"; then
            _old_module="$_active_module"
        fi
    elif [ -d "$_pending_module" ] && ! module_path_equal "$_pending_module" "$MODPATH"; then
        if ! module_dir_is_empty "$_pending_module"; then
            MIGRATION_STATE="clean_reinstall_required"
            MIGRATION_REASON="只有 pending module，没有可确认的 active source"
            return 1
        fi
    fi
    [ -n "$_old_module" ] || return 0

    [ -f "$_old_module/module.prop" ] \
        && [ "$(sed -n 's/^id=//p' "$_old_module/module.prop" 2>/dev/null | head -n 1 | tr -d ' \n\r\t')" = "$BASEBAND_MODULE_ID" ] \
        && [ ! -e "$_old_module/disable" ] && [ ! -e "$_old_module/remove" ] \
        && [ ! -e "$_old_module/skip_mount" ] || {
        MIGRATION_STATE="clean_reinstall_required"
        MIGRATION_REASON="旧模块不是可直接升级的 enabled ordinary module"
        return 1
    }
    if baseband_migration_receipt_check "$_old_module"; then
        MIGRATION_STATE="verified_overlay"
        return 0
    fi

    MIGRATION_STATE="clean_reinstall_required"
    [ -n "$MIGRATION_REASON" ] || MIGRATION_REASON="旧模块迁移状态无法确认"
    return 1
}

detect_root_impl() {
    if [ "${APATCH:-}" = "true" ] || [ -n "${APATCH_VER_CODE:-}" ] || [ -d "$ADB_ROOT/ap" ]; then
        echo "APatch"
    elif [ "${KSU:-}" = "true" ] || [ -n "${KSU_VER_CODE:-}" ] || [ -d "$ADB_ROOT/ksu" ]; then
        echo "KernelSU"
    elif [ -n "${MAGISK_VER_CODE:-}" ] || [ -n "${MAGISK_VER:-}" ] || [ -d "$ADB_ROOT/magisk" ]; then
        echo "Magisk"
    else
        echo "Unknown"
    fi
}

load_device_contract
_contract_rc=$?
if [ "$_contract_rc" -ne 0 ]; then
    if [ "$_contract_rc" -eq 2 ]; then
        installer_fail "不支持的设备: ${device:-unknown}；仅允许 Pixel 9 Pro (caiman) / Pro XL (komodo)" || return 1
    fi
    installer_fail "设备适配 manifest 缺失或格式非法" || return 1
fi

ROOT_IMPL=$(detect_root_impl)
if [ "$ROOT_IMPL" = "Unknown" ]; then
    installer_fail "无法识别 APatch / KernelSU / Magisk 安装环境" || return 1
fi

# A system/ overlay is present in this module. APatch 11224 and KernelSU
# require an enabled MetaModule to carry it; do not claim a successful install
# when the active content backend is absent. Magisk keeps its own Magic Mount
# path and is handled separately below.
if [ -d "$MODPATH/system" ] && { [ "$ROOT_IMPL" = "APatch" ] || [ "$ROOT_IMPL" = "KernelSU" ]; }; then
    if ! detect_active_metamodule; then
        installer_fail "$ROOT_IMPL 需要已启用的 MetaModule（活动 /data/adb/metamodule；metamodule=1）；$METAMODULE_REASON" || return 1
    fi
    if [ "$ROOT_IMPL" = "APatch" ] && [ "$METAMODULE_STATE" != "active" ]; then
        installer_fail "APatch 11224 需要活动 /data/adb/metamodule symlink，不能使用 marker-only 回退" || return 1
    fi
    if ! load_runtime_helpers; then
        installer_fail "$MIGRATION_REASON" || return 1
    fi
fi

if [ -d "$MODPATH/system" ] && { [ "$ROOT_IMPL" = "APatch" ] || [ "$ROOT_IMPL" = "KernelSU" ]; }; then
    if ! baseband_migration_check; then
        installer_fail "$MIGRATION_REASON；请在 Manager 中卸载旧版普通基带模块，重启后再安装新版（不要卸载 APatch Manager）" || return 1
    fi
    if ! printf '%s' "$MIGRATION_STATE" > "$MIGRATION_STATE_FILE" 2>/dev/null; then
        installer_fail "无法写入 MetaModule 迁移状态" || return 1
    fi
fi

UECAP_STATUS="由 pixel9pro_control 管理；本模块不携带 UECap payload"

set_perm_recursive "$MODPATH" 0 0 0755 0644

ui_print ""
ui_print "  ▸ Pixel 9 Pro / XL 基带配置模块"
ui_print ""
ui_print "  Root ............... $ROOT_IMPL"
ui_print "  Device ............. $DEVICE_LABEL ($device)"
ui_print "  VoLTE .............. 启用"
ui_print "  Wi-Fi Calling ...... 启用"
ui_print "  CarrierSettings .... 全球运营商配置"
ui_print "  China MCFG ......... 移动/联通/电信/广电"
ui_print "  UECap .............. $UECAP_STATUS"
if [ "$ROOT_IMPL" = "APatch" ] || [ "$ROOT_IMPL" = "KernelSU" ]; then
    ui_print "  MetaModule ......... $ACTIVE_METAMODULE ($METAMODULE_STATE)"
fi
ui_print ""
ui_print "  ✓ $device 不携带 UECap，避免与 pixel9pro_control 冲突"
if [ "$ROOT_IMPL" = "Magisk" ]; then
    ui_print "  ✓ Magisk 下保留 CarrierSettings / MCFG / IMS props"
fi
ui_print "  ✓ system/ overlay 将由当前 root 框架的挂载后端处理"
ui_print "  ✓ 重启后由 post-mount/service 复读实际生效路径"
ui_print ""
