#!/system/bin/sh

# Manual UECap tier contract. APatch/KernelSU stages one validated payload into
# the active MetaModule content image and records the effective tier; Magisk
# keeps the legacy bind backend disabled. Device dispatch is read from
# config/uecap_devices.tsv so caiman and komodo can never cross the PLATFORM
# filename boundary.

MODDIR="${PIXEL9PRO_MODDIR:-${MODDIR:-${0%/*}}}"
UECAP_MODE_FILE="${PIXEL9PRO_UECAP_MODE_FILE:-$MODDIR/.uecap_mode}"
UECAP_MANUAL_MODE_FILE="${PIXEL9PRO_UECAP_MANUAL_MODE_FILE:-$MODDIR/.uecap_manual_mode}"
UECAP_POLICY_FILE="${PIXEL9PRO_UECAP_POLICY_FILE:-$MODDIR/.uecap_policy}"
UECAP_REASON_FILE="${PIXEL9PRO_UECAP_REASON_FILE:-$MODDIR/.uecap_reason}"
UECAP_SWITCH_FILE="${PIXEL9PRO_UECAP_SWITCH_FILE:-$MODDIR/.uecap_last_switch}"
UECAP_RECEIPT_FILE="${PIXEL9PRO_UECAP_RECEIPT_FILE:-$MODDIR/.uecap_runtime_receipt}"
UECAP_LOGDIR="${PIXEL9PRO_UECAP_LOGDIR:-$MODDIR/.logs}"
UECAP_LOGFILE="${PIXEL9PRO_UECAP_LOGFILE:-$UECAP_LOGDIR/pixel9pro_uecap.log}"
UECAP_TARGET_OVERRIDE="${PIXEL9PRO_UECAP_TARGET:-}"
UECAP_SPECIAL_OVERRIDE="${PIXEL9PRO_UECAP_SPECIAL:-}"
UECAP_BALANCED_OVERRIDE="${PIXEL9PRO_UECAP_BALANCED:-}"
UECAP_UNIVERSAL_OVERRIDE="${PIXEL9PRO_UECAP_UNIVERSAL:-}"
UECAP_CANDIDATE_OVERRIDE="${PIXEL9PRO_UECAP_CANDIDATE:-}"
UECAP_TARGET="${UECAP_TARGET_OVERRIDE:-/vendor/firmware/uecapconfig/PLATFORM_9055801516233416490.binarypb}"
UECAP_SPECIAL="${UECAP_SPECIAL_OVERRIDE:-$MODDIR/payloads/uecap/caiman/PLATFORM_9055801516233416490.special.binarypb}"
UECAP_BALANCED="${UECAP_BALANCED_OVERRIDE:-$MODDIR/payloads/uecap/caiman/PLATFORM_9055801516233416490.balanced.binarypb}"
UECAP_UNIVERSAL="${UECAP_UNIVERSAL_OVERRIDE:-$MODDIR/payloads/uecap/caiman/PLATFORM_9055801516233416490.universal.binarypb}"
UECAP_CANDIDATE="${UECAP_CANDIDATE_OVERRIDE:-$MODDIR/payloads/uecap/komodo/PLATFORM_6287228797510365516.candidate.binarypb}"
UECAP_MODE_ORDER="balanced special universal"
UECAP_DEFAULT_MODE="balanced"
UECAP_RELOAD_DISPATCHED=false
UECAP_RELOAD_RESULT="not_run"
UECAP_APPLY_RESULT="idle"
UECAP_STATE_ROLLBACK_RESULT="not_needed"
UECAP_DEVICE_CONTRACT="${PIXEL9PRO_UECAP_CONTRACT:-$MODDIR/config/uecap_devices.tsv}"
UECAP_PAYLOAD_CONTRACT="${PIXEL9PRO_UECAP_PAYLOAD_CONTRACT:-$MODDIR/config/uecap_payloads.tsv}"
UECAP_METAMODULE_LINK="${PIXEL9PRO_METAMODULE_LINK:-/data/adb/metamodule}"
UECAP_STOCK_BASELINE_FILE="${PIXEL9PRO_UECAP_STOCK_BASELINE_FILE:-$MODDIR/.uecap_stock_baseline_hash}"
UECAP_BACKEND="dynamic_bind"
UECAP_STAGE_RESULT="not_run"
UECAP_MOUNT_OBSERVED="unknown"
UECAP_CONTEXT_VERIFIED="unknown"
UECAP_STOCK_BASELINE_HASH=""
UECAP_READBACK_RESULT="not_run"
UECAP_READBACK_MODE="unknown"
UECAP_READBACK_SOURCE_HASH=""
UECAP_READBACK_CONTENT_HASH=""
UECAP_READBACK_EFFECTIVE_HASH=""
UECAP_READBACK_CONTENT_PATH="none"
UECAP_READBACK_CONTENT_CONTEXT="none"
UECAP_READBACK_EFFECTIVE_CONTEXT="unknown"
UECAP_HYBRID_CONFIG="/data/adb/hybrid-mount/config.toml"
UECAP_DEVICE="unknown"
UECAP_DEVICE_LABEL="unknown"
UECAP_DEVICE_POLICY="unknown"
UECAP_TARGET_NAME="PLATFORM_9055801516233416490.binarypb"
UECAP_DEVICE_SOURCE_DIR="$MODDIR/system/vendor/firmware/uecapconfig"
UECAP_CONTRACT_RESULT="unknown"
UECAP_ROOT_IMPL="unknown"
UECAP_RUNTIME_POLICY="disabled"
UECAP_STATUS_REASON="uecap_contract_unavailable"
UECAP_DESIRED_PROFILE="unknown"
UECAP_BOUND_PROFILE="unknown"
UECAP_MODEM_LOADED_PROFILE="unknown"
UECAP_RADIO_OBSERVED_STATE="UNKNOWN"
UECAP_FUNCTIONAL_STATE="unknown"
UECAP_RECEIPT_FRESHNESS="unknown"
UECAP_RADIO_SNAPSHOT_RESULT="not_run"
UECAP_NSA_STATUS="not_applicable"
UECAP_NSA_REASON="no_confirmed_nsa_cell"

if [ -r "$MODDIR/scripts/slot_transaction_lib.sh" ]; then
    . "$MODDIR/scripts/slot_transaction_lib.sh" 2>/dev/null || true
fi

if ! command -v audit_log_event >/dev/null 2>&1 \
    && [ -r "$MODDIR/scripts/audit_log_lib.sh" ]; then
    . "$MODDIR/scripts/audit_log_lib.sh" 2>/dev/null \
        && audit_log_init "$MODDIR" >/dev/null 2>&1 \
        || true
fi

uecap_detect_device() {
    if [ -n "${PIXEL9PRO_UECAP_DEVICE:-}" ]; then
        printf '%s' "$PIXEL9PRO_UECAP_DEVICE"
        return 0
    fi
    _uecap_device=$(getprop ro.product.device 2>/dev/null | tr -d ' \n\r\t')
    [ -n "$_uecap_device" ] || _uecap_device=$(getprop ro.build.product 2>/dev/null | tr -d ' \n\r\t')
    printf '%s' "${_uecap_device:-unknown}"
}

uecap_load_device_contract() {
    _uecap_device_contract="$1"
    _uecap_device_value="$2"
    [ -r "$_uecap_device_contract" ] || return 1
    UECAP_DEVICE="unknown"
    UECAP_DEVICE_LABEL="unknown"
    UECAP_DEVICE_POLICY="unknown"
    UECAP_TARGET_NAME=""
    UECAP_DEVICE_SOURCE_DIR=""
    _uecap_modes=""
    _uecap_default="disabled"
    while IFS='|' read -r _d _label _policy _target _source _modes _default; do
        case "$_d" in ''|\#*) continue ;; esac
        [ "$_d" = "$_uecap_device_value" ] || continue
        UECAP_DEVICE="$_d"
        UECAP_DEVICE_LABEL="$_label"
        UECAP_DEVICE_POLICY="$_policy"
        UECAP_TARGET_NAME="$_target"
        UECAP_DEVICE_SOURCE_DIR="$_source"
        _uecap_modes="$_modes"
        _uecap_default="$_default"
        break
    done < "$_uecap_device_contract"
    [ "$UECAP_DEVICE" != "unknown" ] || return 2
    case "$UECAP_DEVICE_POLICY" in managed_profiles|single_candidate) ;; *) return 1 ;; esac
    case "$UECAP_TARGET_NAME" in PLATFORM_*.binarypb) ;; *) return 1 ;; esac
    case "$_uecap_device_value:$UECAP_TARGET_NAME" in
        caiman:PLATFORM_9055801516233416490.binarypb|komodo:PLATFORM_6287228797510365516.binarypb) ;;
        *) return 1 ;;
    esac
    [ -n "$_uecap_modes" ] || return 1
    UECAP_MODE_ORDER=$(printf '%s' "$_uecap_modes" | tr ',' ' ')
    UECAP_DEFAULT_MODE="$_uecap_default"
    case "$UECAP_DEVICE_SOURCE_DIR" in ''|/*|*..*|*\\*) return 1 ;; esac
    UECAP_TARGET="${UECAP_TARGET_OVERRIDE:-/vendor/firmware/uecapconfig/$UECAP_TARGET_NAME}"
    _uecap_target_stem=${UECAP_TARGET_NAME%.binarypb}
    UECAP_SPECIAL="${UECAP_SPECIAL_OVERRIDE:-$MODDIR/$UECAP_DEVICE_SOURCE_DIR/${_uecap_target_stem}.special.binarypb}"
    UECAP_BALANCED="${UECAP_BALANCED_OVERRIDE:-$MODDIR/$UECAP_DEVICE_SOURCE_DIR/${_uecap_target_stem}.balanced.binarypb}"
    UECAP_UNIVERSAL="${UECAP_UNIVERSAL_OVERRIDE:-$MODDIR/$UECAP_DEVICE_SOURCE_DIR/${_uecap_target_stem}.universal.binarypb}"
    UECAP_CANDIDATE="${UECAP_CANDIDATE_OVERRIDE:-$MODDIR/$UECAP_DEVICE_SOURCE_DIR/${_uecap_target_stem}.candidate.binarypb}"
    uecap_is_valid_mode "$UECAP_DEFAULT_MODE" 2>/dev/null
}

uecap_refresh_device_contract() {
    _uecap_current_device=$(uecap_detect_device)
    UECAP_CONTRACT_RESULT="invalid"
    UECAP_DEVICE="unknown"
    UECAP_DEVICE_LABEL="unknown"
    UECAP_DEVICE_POLICY="unknown"
    UECAP_TARGET_NAME="unknown.binarypb"
    UECAP_DEVICE_SOURCE_DIR=""
    UECAP_MODE_ORDER=""
    UECAP_DEFAULT_MODE="disabled"
    UECAP_TARGET="${UECAP_TARGET_OVERRIDE:-}"
    UECAP_SPECIAL="${UECAP_SPECIAL_OVERRIDE:-}"
    UECAP_BALANCED="${UECAP_BALANCED_OVERRIDE:-}"
    UECAP_UNIVERSAL="${UECAP_UNIVERSAL_OVERRIDE:-}"
    UECAP_CANDIDATE="${UECAP_CANDIDATE_OVERRIDE:-}"
    uecap_load_device_contract "$UECAP_DEVICE_CONTRACT" "$_uecap_current_device"
    _uecap_contract_rc=$?
    case "$_uecap_contract_rc" in
        0) UECAP_CONTRACT_RESULT="valid" ;;
        2) UECAP_CONTRACT_RESULT="unsupported_device" ;;
        *) UECAP_CONTRACT_RESULT="invalid" ;;
    esac
    return "$_uecap_contract_rc"
}

uecap_detect_root_impl() {
    if [ "${APATCH:-}" = "true" ] || [ -n "${APATCH_VER_CODE:-}" ] || [ -d /data/adb/ap ]; then
        printf 'apatch'
    elif [ "${KSU:-}" = "true" ] || [ -n "${KSU_VER_CODE:-}" ] || [ -d /data/adb/ksu ]; then
        printf 'kernelsu'
    elif [ -n "${MAGISK_VER_CODE:-}" ] || [ -n "${MAGISK_VER:-}" ] || [ -d /data/adb/magisk ]; then
        printf 'magisk'
    else
        printf 'unknown'
    fi
}

uecap_active_metamodule() {
    _uecap_meta_link="$UECAP_METAMODULE_LINK"
    [ -L "$_uecap_meta_link" ] || return 1
    _uecap_meta_target=$(readlink -f "$_uecap_meta_link" 2>/dev/null)
    [ -n "$_uecap_meta_target" ] && [ -d "$_uecap_meta_target" ] || return 1
    case "$(sed -n 's/^metamodule=//p' "$_uecap_meta_target/module.prop" 2>/dev/null \
        | head -n 1 | tr -d ' \n\r\t')" in
        1|true) ;;
        *) return 1 ;;
    esac
    [ ! -e "$_uecap_meta_target/skip_mount" ] || return 1
    [ ! -e "$_uecap_meta_target/disable" ] && [ ! -e "$_uecap_meta_target/remove" ]
}

uecap_metamodule_declared() {
    _uecap_meta_link="$UECAP_METAMODULE_LINK"
    [ -L "$_uecap_meta_link" ] || return 1
    _uecap_meta_target=$(readlink -f "$_uecap_meta_link" 2>/dev/null)
    [ -n "$_uecap_meta_target" ] && [ -d "$_uecap_meta_target" ] || return 1
    case "$(sed -n 's/^metamodule=//p' "$_uecap_meta_target/module.prop" 2>/dev/null \
        | head -n 1 | tr -d ' \n\r\t')" in
        1|true) ;;
        *) return 1 ;;
    esac
    [ ! -e "$_uecap_meta_target/skip_mount" ]
}

uecap_hybrid_mount_active() {
    uecap_active_metamodule || return 1
    _uecap_hybrid_target=$(readlink -f "$UECAP_METAMODULE_LINK" 2>/dev/null) || return 1
    _uecap_hybrid_id=$(sed -n 's/^id=//p' "$_uecap_hybrid_target/module.prop" 2>/dev/null | head -n 1 | tr -d ' \n\r\t')
    _uecap_hybrid_name=$(sed -n 's/^name=//p' "$_uecap_hybrid_target/module.prop" 2>/dev/null | head -n 1 | tr -d '\r')
    case "$_uecap_hybrid_id:$_uecap_hybrid_name" in
        hybrid_mount:*|hybrid-mount:*|*:Hybrid\ Mount*) ;;
        *) [ -x "$_uecap_hybrid_target/hybrid-mount" ] || [ -r "$UECAP_HYBRID_CONFIG" ] || return 1 ;;
    esac
    [ -r "$UECAP_HYBRID_CONFIG" ] || return 1
    return 0
}

uecap_refresh_runtime_policy() {
    UECAP_ROOT_IMPL=$(uecap_detect_root_impl)
    UECAP_RUNTIME_POLICY="disabled"
    if [ "$UECAP_ROOT_IMPL" = apatch ] || [ "$UECAP_ROOT_IMPL" = kernelsu ]; then
        if uecap_hybrid_mount_active; then
            UECAP_BACKEND="hybrid_mount"
        elif uecap_active_metamodule; then
            UECAP_BACKEND="metamodule_content"
        else
            UECAP_BACKEND="metamodule_unavailable"
            UECAP_STATUS_REASON="metamodule_required"
            return 0
        fi
    else
        UECAP_BACKEND="dynamic_bind"
    fi
    case "$UECAP_CONTRACT_RESULT:$UECAP_DEVICE_POLICY:$UECAP_ROOT_IMPL" in
        valid:managed_profiles:magisk|valid:single_candidate:magisk)
            UECAP_RUNTIME_POLICY="disabled"
            UECAP_STATUS_REASON="magisk_uecap_unavailable"
            ;;
        valid:managed_profiles:apatch|valid:managed_profiles:kernelsu)
            UECAP_RUNTIME_POLICY="managed_profiles"
            UECAP_STATUS_REASON="managed_runtime"
            ;;
        valid:single_candidate:apatch|valid:single_candidate:kernelsu)
            UECAP_RUNTIME_POLICY="single_candidate"
            UECAP_STATUS_REASON="candidate_runtime"
            ;;
        valid:managed_profiles:*|valid:single_candidate:*)
            UECAP_RUNTIME_POLICY="disabled"
            UECAP_STATUS_REASON="unknown_root_backend"
            ;;
        unsupported_device:*)
            UECAP_RUNTIME_POLICY="disabled"
            UECAP_STATUS_REASON="uecap_device_not_in_contract"
            ;;
        *)
            UECAP_RUNTIME_POLICY="disabled"
            UECAP_STATUS_REASON="uecap_contract_invalid"
            ;;
    esac
}

uecap_log_line() {
    if command -v audit_log_event >/dev/null 2>&1; then
        audit_log_event uecap mutation info "$(audit_log_token "$1")" 0 >/dev/null 2>&1 || true
        return 0
    fi
    mkdir -p "${UECAP_LOGFILE%/*}" 2>/dev/null || return 1
    chmod 700 "${UECAP_LOGFILE%/*}" 2>/dev/null || return 1
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$(printf '%s' "$1" | tr '\r\n' '__')" >> "$UECAP_LOGFILE" \
        && chmod 600 "$UECAP_LOGFILE" 2>/dev/null
}

uecap_hash() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

uecap_payload_override() {
    [ "${PIXEL9PRO_UECAP_TEST_MODE:-0}" = 1 ] || return 1
    case "$1" in
        balanced) [ -n "$UECAP_BALANCED_OVERRIDE" ] && printf '%s' "$UECAP_BALANCED_OVERRIDE" ;;
        special) [ -n "$UECAP_SPECIAL_OVERRIDE" ] && printf '%s' "$UECAP_SPECIAL_OVERRIDE" ;;
        universal) [ -n "$UECAP_UNIVERSAL_OVERRIDE" ] && printf '%s' "$UECAP_UNIVERSAL_OVERRIDE" ;;
        candidate) [ -n "$UECAP_CANDIDATE_OVERRIDE" ] && printf '%s' "$UECAP_CANDIDATE_OVERRIDE" ;;
        *) return 1 ;;
    esac
}

uecap_payload_source() {
    _uecap_payload_mode="$1"
    [ "$_uecap_payload_mode" != stock ] || return 1
    _uecap_override=$(uecap_payload_override "$_uecap_payload_mode" 2>/dev/null)
    if [ -n "$_uecap_override" ]; then
        [ -f "$_uecap_override" ] || return 1
        printf '%s' "$_uecap_override"
        return 0
    fi
    [ -r "$UECAP_PAYLOAD_CONTRACT" ] || return 1
    while IFS='|' read -r _p_device _p_mode _p_source _p_target _p_bytes _p_sha _p_state _p_build; do
        case "$_p_device" in ''|\#*) continue ;; esac
        [ "$_p_device" = "$UECAP_DEVICE" ] && [ "$_p_mode" = "$_uecap_payload_mode" ] || continue
        [ "$_p_target" = "$UECAP_TARGET_NAME" ] || return 1
        case "$_p_source" in "$UECAP_DEVICE_SOURCE_DIR"/*) ;; *) return 1 ;; esac
        case "$_p_source" in /*|*..*|*\\*) return 1 ;; esac
        case "$_p_bytes" in ''|*[!0-9]*) return 1 ;; esac
        case "$_p_sha" in ''|*[!0-9a-f]*) return 1 ;; esac
        case "$_p_state" in verified|candidate) ;; *) return 1 ;; esac
        [ -n "$_p_build" ] || return 1
        _p_full="$MODDIR/$_p_source"
        [ -f "$_p_full" ] || return 1
        [ "$(wc -c < "$_p_full" 2>/dev/null | tr -d ' ')" = "$_p_bytes" ] || return 1
        [ "$(uecap_hash "$_p_full")" = "$_p_sha" ] || return 1
        printf '%s' "$_p_full"
        return 0
    done < "$UECAP_PAYLOAD_CONTRACT"
    return 1
}

uecap_payload_metadata() {
    _uecap_meta_mode="$1"
    UECAP_PAYLOAD_STATE=stock
    UECAP_PAYLOAD_BUILD=system
    UECAP_PAYLOAD_BYTES=0
    UECAP_PAYLOAD_SHA=""
    [ "$_uecap_meta_mode" != stock ] || return 0
    while IFS='|' read -r _m_device _m_mode _m_source _m_target _m_bytes _m_sha _m_state _m_build; do
        case "$_m_device" in ''|\#*) continue ;; esac
        [ "$_m_device" = "$UECAP_DEVICE" ] && [ "$_m_mode" = "$_uecap_meta_mode" ] || continue
        UECAP_PAYLOAD_STATE="$_m_state"
        UECAP_PAYLOAD_BUILD="$_m_build"
        UECAP_PAYLOAD_BYTES="$_m_bytes"
        UECAP_PAYLOAD_SHA="$_m_sha"
        return 0
    done < "$UECAP_PAYLOAD_CONTRACT"
    return 1
}

uecap_mount_bind() {
    _uecap_mount_bin="/system/bin/mount"
    [ "${PIXEL9PRO_UECAP_TEST_MODE:-0}" = "1" ] \
        && _uecap_mount_bin="${PIXEL9PRO_UECAP_MOUNT_BIN:-mount}"
    "$_uecap_mount_bin" --bind "$1" "$2" >/dev/null 2>&1
}

uecap_unmount() {
    _uecap_umount_bin="/system/bin/umount"
    [ "${PIXEL9PRO_UECAP_TEST_MODE:-0}" = "1" ] \
        && _uecap_umount_bin="${PIXEL9PRO_UECAP_UMOUNT_BIN:-umount}"
    "$_uecap_umount_bin" "$1" >/dev/null 2>&1
}

uecap_target_is_mounted() {
    _uecap_mount_list_bin="/system/bin/mount"
    [ "${PIXEL9PRO_UECAP_TEST_MODE:-0}" = "1" ] \
        && _uecap_mount_list_bin="${PIXEL9PRO_UECAP_MOUNT_BIN:-mount}"
    "$_uecap_mount_list_bin" 2>/dev/null | grep -F " on $UECAP_TARGET " >/dev/null 2>&1
}

uecap_is_valid_mode() {
    _uecap_candidate_mode="$1"
    for _uecap_allowed_mode in $UECAP_MODE_ORDER; do
        [ "$_uecap_candidate_mode" = "$_uecap_allowed_mode" ] && return 0
    done
    return 1
}

uecap_is_available() {
    [ "$UECAP_CONTRACT_RESULT" = "valid" ] \
        && { [ "$UECAP_RUNTIME_POLICY" = "managed_profiles" ] \
            || [ "$UECAP_RUNTIME_POLICY" = "single_candidate" ]; } \
        && [ -n "$UECAP_MODE_ORDER" ]
}

uecap_mode_label() {
    if uecap_is_valid_mode "$1"; then
        echo "$1"
    else
        echo "unknown"
    fi
}

uecap_current_mode() {
    uecap_is_available || { echo "disabled"; return 0; }
    _uecap_current=$(cat "$UECAP_MODE_FILE" 2>/dev/null | tr -d ' \n\r')
    if uecap_is_valid_mode "$_uecap_current"; then
        echo "$_uecap_current"
    else
        echo "$UECAP_DEFAULT_MODE"
    fi
}

uecap_current_manual_mode() {
    uecap_is_available || { echo "disabled"; return 0; }
    _uecap_manual=$(cat "$UECAP_MANUAL_MODE_FILE" 2>/dev/null | tr -d ' \n\r')
    if uecap_is_valid_mode "$_uecap_manual"; then
        echo "$_uecap_manual"
    else
        echo "$UECAP_DEFAULT_MODE"
    fi
}

uecap_current_policy() {
    case "$UECAP_RUNTIME_POLICY" in
        managed_profiles) printf 'managed_profiles' ;;
        single_candidate) printf 'single_candidate' ;;
        *) printf 'disabled' ;;
    esac
}

uecap_current_reason() {
    if uecap_is_available; then
        _uecap_reason_value=$(cat "$UECAP_REASON_FILE" 2>/dev/null | tr -d '\n\r')
        printf '%s' "${_uecap_reason_value:-$UECAP_STATUS_REASON}"
    else
        printf '%s' "$UECAP_STATUS_REASON"
    fi
}

uecap_disabled_message() {
    case "${UECAP_STATUS_REASON:-}" in
        candidate_runtime)
            printf '%s' 'Pixel 9 Pro XL 默认保持 stock；只有用户明确选择 candidate 才绑定 XL 单文件。'
            ;;
        magisk_uecap_unavailable)
            printf '%s' 'Magisk 下不启用 managed UECap 覆盖；独立基带模块仍可单独提供 CarrierSettings、MCFG、APN 与 IMS。'
            ;;
        metamodule_dynamic_bind_unsafe)
            printf '%s' '活动 MetaModule 下禁止 Control 在 post-mount 后动态 bind /vendor；UECap 保持 stock，等待独立 overlay 模块。'
            ;;
        metamodule_required)
            printf '%s' 'APatch/KernelSU 需要活动 MetaModule 承载 UECap content image；当前仅保留 stock/read-only。'
            ;;
        *)
            printf '%s' '当前安装环境不提供 managed UECap 配置切换。'
            ;;
    esac
}

uecap_meta_target() {
    uecap_active_metamodule || return 1
    readlink -f "$UECAP_METAMODULE_LINK" 2>/dev/null
}

uecap_meta_content_root() {
    _uecap_content_target=$(uecap_meta_target) || return 1
    _uecap_content_module=${MODDIR##*/}
    case "$_uecap_content_module" in
        ''|.|..|*/*) return 1 ;;
    esac
    printf '%s/mnt/%s' "$_uecap_content_target" "$_uecap_content_module"
}

uecap_meta_content_path() {
    _uecap_content_root=$(uecap_meta_content_root) || return 1
    _uecap_content_relative="$1"
    case "$_uecap_content_relative" in
        /*|*..*|*\\*) return 1 ;;
    esac
    _uecap_content_direct="$_uecap_content_root/$_uecap_content_relative"
    _uecap_content_legacy="$_uecap_content_root/system/$_uecap_content_relative"
    if [ -e "$_uecap_content_direct" ] || [ -L "$_uecap_content_direct" ]; then
        printf '%s' "$_uecap_content_direct"
    elif [ -e "$_uecap_content_legacy" ] || [ -L "$_uecap_content_legacy" ]; then
        printf '%s' "$_uecap_content_legacy"
    else
        printf '%s' "$_uecap_content_direct"
    fi
}

uecap_meta_content_exists() {
    _uecap_meta_target=$(uecap_meta_target) || return 1
    _uecap_meta_mnt="$_uecap_meta_target/mnt"
    mountpoint -q "$_uecap_meta_mnt" 2>/dev/null || return 1
    [ -d "$_uecap_meta_mnt/${MODDIR##*/}" ]
}

uecap_meta_vendor_overlay_has_module() {
    _uecap_overlay_root=$(uecap_meta_content_root) || return 1
    _uecap_overlay_direct="$_uecap_overlay_root/vendor"
    _uecap_overlay_legacy="$_uecap_overlay_root/system/vendor"
    _uecap_overlay_link="$_uecap_meta_link/mnt/${MODDIR##*/}/vendor"
    _uecap_overlay_link_legacy="$_uecap_meta_link/mnt/${MODDIR##*/}/system/vendor"
    _uecap_overlay_mounts=$(grep -F " /vendor " /proc/self/mountinfo 2>/dev/null \
        | grep -F " - overlay " 2>/dev/null) || return 1
    printf '%s\n' "$_uecap_overlay_mounts" \
        | grep -F "lowerdir=$_uecap_overlay_direct" >/dev/null 2>&1 && return 0
    printf '%s\n' "$_uecap_overlay_mounts" \
        | grep -F "lowerdir=$_uecap_overlay_link" >/dev/null 2>&1 && return 0
    printf '%s\n' "$_uecap_overlay_mounts" \
        | grep -F "lowerdir=$_uecap_overlay_link_legacy" >/dev/null 2>&1 && return 0
    printf '%s\n' "$_uecap_overlay_mounts" \
        | grep -F "lowerdir=$_uecap_overlay_legacy" >/dev/null 2>&1
}

uecap_hybrid_mount_observed() {
    _uecap_hybrid_lower_source="/data/adb/modules/${MODDIR##*/}/system/vendor"
    _uecap_hybrid_lower_source_alias="/data/adb/modules/${MODDIR##*/}/vendor"
    _uecap_hybrid_suffix="/${MODDIR##*/}/system/vendor"
    _uecap_hybrid_suffix_alias="/${MODDIR##*/}/vendor"
    _uecap_hybrid_target="/vendor/firmware/uecapconfig/$UECAP_TARGET_NAME"
    _uecap_hybrid_mounts=$(grep -F " /vendor " /proc/self/mountinfo 2>/dev/null || true)
    printf '%s\n' "$_uecap_hybrid_mounts" | grep -F "lowerdir=$_uecap_hybrid_lower_source" >/dev/null 2>&1 && return 0
    printf '%s\n' "$_uecap_hybrid_mounts" | grep -F "lowerdir=$_uecap_hybrid_lower_source_alias" >/dev/null 2>&1 && return 0
    printf '%s\n' "$_uecap_hybrid_mounts" | grep -F "$_uecap_hybrid_suffix" >/dev/null 2>&1 && return 0
    printf '%s\n' "$_uecap_hybrid_mounts" | grep -F "$_uecap_hybrid_suffix_alias" >/dev/null 2>&1 && return 0
    grep -F " $_uecap_hybrid_target " /proc/self/mountinfo >/dev/null 2>&1 && return 0
    # Hybrid Mount may hide its randomized staging path in a private mount
    # namespace. Its committed state is the authoritative module mapping.
    _uecap_hybrid_state="${PIXEL9PRO_UECAP_HYBRID_STATE_FILE:-/data/adb/hybrid-mount/run/state.json}"
    _uecap_hybrid_scan="${PIXEL9PRO_UECAP_HYBRID_SCAN_FILE:-/data/adb/hybrid-mount/scan.ret}"
    [ -r "$_uecap_hybrid_state" ] \
        && [ -r "$_uecap_hybrid_scan" ] \
        && grep -F '"failed_mounts": 0' "$_uecap_hybrid_state" >/dev/null 2>&1 \
        && grep -E '"/vendor(/|")' "$_uecap_hybrid_state" >/dev/null 2>&1 \
        && awk '/"id": "pixel9pro_control"/{hit=1} hit{print} hit && /\}/{exit}' "$_uecap_hybrid_scan" \
            | grep -F '"is_mounted": true' >/dev/null 2>&1
}

uecap_hybrid_readback_mode() {
    _uecap_readback_mode="$1"
    UECAP_READBACK_RESULT=failed
    UECAP_READBACK_MODE="$_uecap_readback_mode"
    UECAP_READBACK_SOURCE_HASH=""
    UECAP_READBACK_CONTENT_HASH=""
    UECAP_READBACK_EFFECTIVE_HASH=""
    UECAP_READBACK_CONTENT_PATH=none
    UECAP_READBACK_CONTENT_CONTEXT=none
    UECAP_READBACK_EFFECTIVE_CONTEXT=unknown
    UECAP_CONTEXT_VERIFIED=false
    [ "$UECAP_BACKEND" = hybrid_mount ] || return 1
    uecap_is_valid_mode "$_uecap_readback_mode" || return 1
    _uecap_hybrid_effective_hash=$(uecap_hash "$UECAP_TARGET")
    _uecap_hybrid_effective_context=$(ls -Zd "$UECAP_TARGET" 2>/dev/null | awk '{print $1}')
    [ -n "$_uecap_hybrid_effective_hash" ] \
        && [ "$_uecap_hybrid_effective_context" = u:object_r:vendor_fw_file:s0 ] || return 1
    UECAP_READBACK_EFFECTIVE_HASH="$_uecap_hybrid_effective_hash"
    UECAP_READBACK_EFFECTIVE_CONTEXT="$_uecap_hybrid_effective_context"
    if [ "$_uecap_readback_mode" = stock ]; then
        _uecap_hybrid_baseline=$(cat "$UECAP_STOCK_BASELINE_FILE" 2>/dev/null | tr -d ' \n\r\t')
        [ "$UECAP_READBACK_EFFECTIVE_HASH" = "$_uecap_hybrid_baseline" ] || return 1
        UECAP_MOUNT_OBSERVED=stock
        UECAP_READBACK_SOURCE_HASH="$_uecap_hybrid_baseline"
        UECAP_READBACK_CONTENT_HASH=none
        UECAP_READBACK_CONTENT_PATH=none
        UECAP_READBACK_CONTENT_CONTEXT=none
        UECAP_CONTENT_IMAGE=none
    else
        _uecap_hybrid_source="$MODDIR/system/vendor/firmware/uecapconfig/$UECAP_TARGET_NAME"
        _uecap_hybrid_source_hash=$(uecap_hash "$(uecap_resolve_source "$_uecap_readback_mode")")
        _uecap_hybrid_source_context=$(ls -Zd "$_uecap_hybrid_source" 2>/dev/null | awk '{print $1}')
        [ -n "$_uecap_hybrid_source_hash" ] \
            && [ "$(uecap_hash "$_uecap_hybrid_source")" = "$_uecap_hybrid_source_hash" ] \
            && [ "$_uecap_hybrid_source_context" = u:object_r:vendor_fw_file:s0 ] \
            && [ "$_uecap_hybrid_source_hash" = "$UECAP_READBACK_EFFECTIVE_HASH" ] || return 1
        uecap_hybrid_mount_observed || return 1
        UECAP_READBACK_SOURCE_HASH="$_uecap_hybrid_source_hash"
        UECAP_READBACK_CONTENT_HASH="$_uecap_hybrid_source_hash"
        UECAP_READBACK_CONTENT_PATH="$_uecap_hybrid_source"
        UECAP_READBACK_CONTENT_CONTEXT="$_uecap_hybrid_source_context"
        UECAP_CONTENT_IMAGE="$_uecap_hybrid_source"
        UECAP_MOUNT_OBSERVED=hybrid_mount
    fi
    UECAP_CONTEXT_VERIFIED=true
    UECAP_READBACK_RESULT=verified
    rm -f "$MODDIR/.uecap_reboot_required" 2>/dev/null || true
    return 0
}

uecap_meta_readback_mode() {
    _uecap_readback_mode="$1"
    UECAP_READBACK_RESULT=failed
    UECAP_READBACK_MODE="$_uecap_readback_mode"
    UECAP_READBACK_SOURCE_HASH=""
    UECAP_READBACK_CONTENT_HASH=""
    UECAP_READBACK_EFFECTIVE_HASH=""
    UECAP_READBACK_CONTENT_PATH=none
    UECAP_READBACK_CONTENT_CONTEXT=none
    UECAP_READBACK_EFFECTIVE_CONTEXT=unknown
    UECAP_CONTEXT_VERIFIED=false
    if [ "$UECAP_BACKEND" = hybrid_mount ]; then
        uecap_hybrid_readback_mode "$_uecap_readback_mode"
        return $?
    fi
    [ "$UECAP_BACKEND" = metamodule_content ] || return 1
    uecap_is_valid_mode "$_uecap_readback_mode" || return 1

    _uecap_readback_target_hash=$(uecap_hash "$UECAP_TARGET")
    _uecap_readback_target_context=$(ls -Zd "$UECAP_TARGET" 2>/dev/null | awk '{print $1}')
    [ -n "$_uecap_readback_target_hash" ] \
        && [ "$_uecap_readback_target_context" = u:object_r:vendor_fw_file:s0 ] || return 1
    UECAP_READBACK_EFFECTIVE_HASH="$_uecap_readback_target_hash"
    UECAP_READBACK_EFFECTIVE_CONTEXT="$_uecap_readback_target_context"

    _uecap_readback_root=$(uecap_meta_content_root) || return 1
    _uecap_readback_direct="$_uecap_readback_root/vendor/firmware/uecapconfig/$UECAP_TARGET_NAME"
    _uecap_readback_legacy="$_uecap_readback_root/system/vendor/firmware/uecapconfig/$UECAP_TARGET_NAME"
    _uecap_readback_content=$(uecap_meta_content_path \
        "vendor/firmware/uecapconfig/$UECAP_TARGET_NAME") || return 1

    if [ "$_uecap_readback_mode" = stock ]; then
        _uecap_readback_baseline=$(cat "$UECAP_STOCK_BASELINE_FILE" 2>/dev/null | tr -d ' \n\r\t')
        case "$_uecap_readback_baseline" in
            ''|*[!0-9a-fA-F]*) return 1 ;;
        esac
        [ "$_uecap_readback_target_hash" = "$_uecap_readback_baseline" ] || return 1
        ! uecap_target_is_mounted || return 1
        [ ! -e "$_uecap_readback_direct" ] && [ ! -L "$_uecap_readback_direct" ] \
            && [ ! -e "$_uecap_readback_legacy" ] && [ ! -L "$_uecap_readback_legacy" ] || return 1
        UECAP_READBACK_CONTENT_PATH=none
        UECAP_READBACK_CONTENT_HASH=none
        UECAP_READBACK_CONTENT_CONTEXT=none
        UECAP_MOUNT_OBSERVED=stock_unmounted
    else
        _uecap_readback_source=$(uecap_resolve_source "$_uecap_readback_mode") || return 1
        _uecap_readback_source_hash=$(uecap_hash "$_uecap_readback_source")
        _uecap_readback_stage="$MODDIR/system/vendor/firmware/uecapconfig/$UECAP_TARGET_NAME"
        _uecap_readback_stage_context=$(ls -Zd "$_uecap_readback_stage" 2>/dev/null | awk '{print $1}')
        [ -n "$_uecap_readback_source_hash" ] \
            && [ "$_uecap_readback_stage_context" = u:object_r:vendor_fw_file:s0 ] \
            && [ "$(uecap_hash "$_uecap_readback_stage")" = "$_uecap_readback_source_hash" ] || return 1
        [ -f "$_uecap_readback_content" ] || return 1
        _uecap_readback_content_hash=$(uecap_hash "$_uecap_readback_content")
        _uecap_readback_content_context=$(ls -Zd "$_uecap_readback_content" 2>/dev/null | awk '{print $1}')
        [ "$_uecap_readback_content_hash" = "$_uecap_readback_source_hash" ] \
            && [ "$_uecap_readback_content_hash" = "$_uecap_readback_target_hash" ] \
            && [ "$_uecap_readback_content_context" = u:object_r:vendor_fw_file:s0 ] || return 1
        if [ -f "$_uecap_readback_direct" ] && [ -f "$_uecap_readback_legacy" ]; then
            [ "$(uecap_hash "$_uecap_readback_direct")" = "$_uecap_readback_content_hash" ] \
                && [ "$(uecap_hash "$_uecap_readback_legacy")" = "$_uecap_readback_content_hash" ] || return 1
        fi
        uecap_meta_vendor_overlay_has_module || return 1
        UECAP_READBACK_SOURCE_HASH="$_uecap_readback_source_hash"
        UECAP_READBACK_CONTENT_HASH="$_uecap_readback_content_hash"
        UECAP_READBACK_CONTENT_PATH="$_uecap_readback_content"
        UECAP_READBACK_CONTENT_CONTEXT="$_uecap_readback_content_context"
        UECAP_MOUNT_OBSERVED=content_image
    fi
    [ "$_uecap_readback_mode" = stock ] \
        && UECAP_READBACK_SOURCE_HASH="$_uecap_readback_target_hash"
    UECAP_READBACK_EFFECTIVE_HASH="$_uecap_readback_target_hash"
    UECAP_CONTENT_IMAGE="$UECAP_READBACK_CONTENT_PATH"
    UECAP_CONTEXT_VERIFIED=true
    UECAP_READBACK_RESULT=verified
    return 0
}

uecap_hybrid_stage_mode() {
    _uecap_hybrid_stage_mode="$1"
    _uecap_hybrid_stage_root="$MODDIR/system/vendor/firmware/uecapconfig"
    _uecap_hybrid_stage_target="$_uecap_hybrid_stage_root/$UECAP_TARGET_NAME"
    case "$_uecap_hybrid_stage_mode" in
        disabled|stock)
            _uecap_hybrid_baseline=$(uecap_hash "$UECAP_TARGET")
            _uecap_hybrid_context=$(ls -Zd "$UECAP_TARGET" 2>/dev/null | awk '{print $1}')
            [ -n "$_uecap_hybrid_baseline" ] \
                && [ "$_uecap_hybrid_context" = u:object_r:vendor_fw_file:s0 ] || return 1
            slot_stage_file uecap "$_uecap_hybrid_stage_target" \
                "system/vendor/firmware/uecapconfig/$UECAP_TARGET_NAME" remove \
                "$UECAP_DEVICE" "$(getprop ro.build.fingerprint 2>/dev/null)" vendor_fw_file \
                || return 1
            uecap_atomic_write "$UECAP_STOCK_BASELINE_FILE" "$_uecap_hybrid_baseline" || return 1
            uecap_atomic_write "$MODDIR/.uecap_content_image" metadata_staging || return 1
            uecap_atomic_write "$MODDIR/.uecap_backend" hybrid_mount || return 1
            UECAP_CONTENT_IMAGE=metadata_staging
            UECAP_STAGE_RESULT=stock
            return 0
            ;;
    esac
    _uecap_hybrid_stage_source=$(uecap_resolve_source "$_uecap_hybrid_stage_mode") || return 1
    [ -f "$_uecap_hybrid_stage_source" ] || return 1
    slot_stage_file uecap "$_uecap_hybrid_stage_source" \
        "system/vendor/firmware/uecapconfig/$UECAP_TARGET_NAME" staged \
        "$UECAP_DEVICE" "$(getprop ro.build.fingerprint 2>/dev/null)" \
        u:object_r:vendor_fw_file:s0 || return 1
    uecap_atomic_write "$MODDIR/.uecap_content_image" metadata_staging || return 1
    uecap_atomic_write "$MODDIR/.uecap_backend" hybrid_mount || return 1
    UECAP_CONTENT_IMAGE="$_uecap_hybrid_stage_target"
    UECAP_STAGE_RESULT=staged
    return 0
}

uecap_stage_mode() {
    _uecap_stage_mode="$1"
    UECAP_STAGE_RESULT="failed"
    if [ "$UECAP_BACKEND" = hybrid_mount ]; then
        uecap_hybrid_stage_mode "$_uecap_stage_mode"
        return $?
    fi
    [ "$UECAP_BACKEND" = metamodule_content ] || {
        UECAP_STAGE_RESULT="not_metamodule"
        return 0
    }
    uecap_meta_target >/dev/null || return 1
    if uecap_meta_content_exists; then
        UECAP_STAGE_RESULT="clean_reinstall_required"
        return 2
    fi
    _uecap_stage_root="$MODDIR/system/vendor/firmware/uecapconfig"
    case "$_uecap_stage_mode" in
        disabled|stock)
            _uecap_stage_target="$_uecap_stage_root/$UECAP_TARGET_NAME"
            rm -f "$_uecap_stage_target" 2>/dev/null || return 1
            _uecap_stage_baseline_hash=$(uecap_hash "$UECAP_TARGET")
            _uecap_stage_context=$(ls -Zd "$UECAP_TARGET" 2>/dev/null | awk '{print $1}')
            [ -n "$_uecap_stage_baseline_hash" ] \
                && [ "$_uecap_stage_context" = u:object_r:vendor_fw_file:s0 ] \
                && ! uecap_target_is_mounted || return 1
            uecap_atomic_write "$UECAP_STOCK_BASELINE_FILE" "$_uecap_stage_baseline_hash" || return 1
            uecap_atomic_write "$MODDIR/.uecap_content_image" none || return 1
            uecap_atomic_write "$MODDIR/.uecap_backend" metamodule_content || return 1
            UECAP_STOCK_BASELINE_HASH="$_uecap_stage_baseline_hash"
            UECAP_CONTENT_IMAGE=none
            UECAP_STAGE_RESULT="stock"
            return 0
            ;;
    esac
    _uecap_stage_source=$(uecap_resolve_source "$_uecap_stage_mode") || return 1
    [ -f "$_uecap_stage_source" ] || return 1
    mkdir -p "$_uecap_stage_root" || return 1
    chcon --reference=/vendor "$MODDIR/system/vendor" 2>/dev/null || return 1
    chcon --reference=/vendor/firmware "$MODDIR/system/vendor/firmware" 2>/dev/null || return 1
    chcon --reference=/vendor/firmware/uecapconfig "$_uecap_stage_root" 2>/dev/null || return 1
    _uecap_stage_target="$_uecap_stage_root/$UECAP_TARGET_NAME"
    cp -f "$_uecap_stage_source" "$_uecap_stage_target" || return 1
    chmod 0644 "$_uecap_stage_target" 2>/dev/null || return 1
    if [ -e "$UECAP_TARGET" ]; then
        chcon --reference="$UECAP_TARGET" "$_uecap_stage_target" 2>/dev/null \
            || chcon u:object_r:vendor_fw_file:s0 "$_uecap_stage_target" 2>/dev/null \
            || return 1
    fi
    [ "$(ls -Zd "$_uecap_stage_target" 2>/dev/null | awk '{print $1}')" = \
        "$(ls -Zd "$UECAP_TARGET" 2>/dev/null | awk '{print $1}')" ] || return 1
    [ "$(uecap_hash "$_uecap_stage_target")" = "$(uecap_hash "$_uecap_stage_source")" ] || return 1
    UECAP_CONTENT_IMAGE="$(uecap_meta_content_path "vendor/firmware/uecapconfig/$UECAP_TARGET_NAME")" || return 1
    uecap_atomic_write "$MODDIR/.uecap_content_image" "$UECAP_CONTENT_IMAGE" || return 1
    uecap_atomic_write "$MODDIR/.uecap_backend" metamodule_content || return 1
    UECAP_STAGE_RESULT="staged"
    return 0
}

uecap_verify_staged_mode() {
    _uecap_verify_mode="$1"
    uecap_meta_readback_mode "$_uecap_verify_mode" || return 1
    rm -f "$MODDIR/.uecap_reboot_required" 2>/dev/null || true
    UECAP_CONTENT_IMAGE="$UECAP_READBACK_CONTENT_PATH"
    UECAP_DESIRED_PROFILE="$_uecap_verify_mode"
    UECAP_BOUND_PROFILE="$_uecap_verify_mode"
    UECAP_MODEM_LOAD_STATE=pre_modem_bind
    UECAP_MODEM_LOADED_PROFILE=unknown
    UECAP_FUNCTIONAL_STATE=modem_load_unconfirmed
    UECAP_RECEIPT_FRESHNESS=current_boot
    UECAP_RELOAD_RESULT=not_required_pre_modem
    UECAP_CONTEXT_VERIFIED=true
    uecap_write_runtime_receipt "$_uecap_verify_mode" "$UECAP_READBACK_SOURCE_HASH" \
        "$UECAP_READBACK_EFFECTIVE_HASH" pre_modem applied pre_modem_observed
}
uecap_last_switch() {
    cat "$UECAP_SWITCH_FILE" 2>/dev/null | tr -d ' \n\r'
}

uecap_json_escape() {
    printf '%s' "$1" | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\r//g;s/\n/\\n/g'
}

uecap_atomic_write() {
    _uecap_file="$1"
    _uecap_value="$2"
    [ -n "$_uecap_file" ] && [ ! -d "$_uecap_file" ] || return 1
    _uecap_tmp="${_uecap_file}.tmp.$$"
    if printf '%s' "$_uecap_value" > "$_uecap_tmp" 2>/dev/null \
        && mv "$_uecap_tmp" "$_uecap_file" 2>/dev/null \
        && [ -f "$_uecap_file" ]; then
        _uecap_written=$(cat "$_uecap_file" 2>/dev/null)
        [ "$_uecap_written" = "$_uecap_value" ] && return 0
    fi
    rm -f "$_uecap_tmp" 2>/dev/null
    return 1
}

uecap_receipt_value() {
    # The receipt is a deliberately small key/value file.  Strip separators
    # before writing so CGI JSON cannot be confused by command output.
    printf '%s' "$1" | tr '\r\n=|' '    '
}

uecap_receipt_get() {
    _uecap_receipt_key="$1"
    [ -f "$UECAP_RECEIPT_FILE" ] || return 1
    awk -F= -v key="$_uecap_receipt_key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "$UECAP_RECEIPT_FILE" 2>/dev/null
}

uecap_boot_id() {
    if [ -n "${PIXEL9PRO_UECAP_BOOT_ID:-}" ]; then
        printf '%s' "$PIXEL9PRO_UECAP_BOOT_ID"
        return 0
    fi
    _uecap_boot_id_value=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \n\r\t')
    [ -n "$_uecap_boot_id_value" ] \
        || _uecap_boot_id_value=$(getprop ro.boot.boot_id 2>/dev/null | tr -d ' \n\r\t')
    [ -n "$_uecap_boot_id_value" ] && printf '%s' "$_uecap_boot_id_value" || printf 'unknown'
}

uecap_capture_radio_snapshot() {
    UECAP_RADIO_ACTUAL_RAT="unknown"
    UECAP_RADIO_NR_AVAILABLE="unknown"
    UECAP_RADIO_ENDC_AVAILABLE="unknown"
    UECAP_RADIO_NR_REGISTERED="unknown"
    UECAP_RADIO_NR_BAND="unknown"
    UECAP_RADIO_NR_ARFCN="unknown"
    UECAP_RADIO_NR_RANGE="unknown"
    UECAP_RADIO_LTE_ANCHOR="unknown"

    if [ "${PIXEL9PRO_UECAP_TEST_MODE:-0}" = "1" ]; then
        UECAP_RADIO_ACTUAL_RAT="${PIXEL9PRO_UECAP_ACTUAL_RAT:-unknown}"
        UECAP_RADIO_NR_AVAILABLE="${PIXEL9PRO_UECAP_NR_AVAILABLE:-unknown}"
        UECAP_RADIO_ENDC_AVAILABLE="${PIXEL9PRO_UECAP_ENDC_AVAILABLE:-unknown}"
        UECAP_RADIO_NR_REGISTERED="${PIXEL9PRO_UECAP_NR_REGISTERED:-unknown}"
        UECAP_RADIO_NR_BAND="${PIXEL9PRO_UECAP_NR_BAND:-unknown}"
        UECAP_RADIO_NR_ARFCN="${PIXEL9PRO_UECAP_NR_ARFCN:-unknown}"
        UECAP_RADIO_NR_RANGE="${PIXEL9PRO_UECAP_NR_RANGE:-unknown}"
        UECAP_RADIO_LTE_ANCHOR="${PIXEL9PRO_UECAP_LTE_ANCHOR:-unknown}"
        case "${UECAP_RADIO_ACTUAL_RAT:-unknown}" in
            NR_SA|NR-SA|SA)
                UECAP_RADIO_ENDC_AVAILABLE="not_applicable"
                UECAP_RADIO_LTE_ANCHOR="not_applicable"
                ;;
        esac
        return 0
    fi

    _uecap_radio_dump="$MODDIR/.uecap_telephony.$$"
    timeout 5 dumpsys telephony.registry > "$_uecap_radio_dump" 2>/dev/null || {
        rm -f "$_uecap_radio_dump" 2>/dev/null
        return 1
    }
    _uecap_radio_text=$(tr '\n' ' ' < "$_uecap_radio_dump" 2>/dev/null)
    UECAP_RADIO_ACTUAL_RAT=$(printf '%s' "$_uecap_radio_text" | sed -n 's/.*mTelephonyDisplayInfo=.*network=\([^,} ]*\).*/\1/p' | head -n 1)
    _uecap_ril_radio=$(printf '%s' "$_uecap_radio_text" | sed -n 's/.*\(getRilDataRadioTechnology\|mRilDataRadioTechnology\)=\([^ ,})]*\).*/\2/p' | head -n 1)
    UECAP_RADIO_NR_AVAILABLE=$(grep -o 'isNrAvailable[[:space:]]*=[[:space:]]*[A-Za-z]*' "$_uecap_radio_dump" | head -n 1 | sed 's/.*=[[:space:]]*//')
    UECAP_RADIO_ENDC_AVAILABLE=$(grep -o 'isEnDcAvailable[[:space:]]*=[[:space:]]*[A-Za-z]*' "$_uecap_radio_dump" | head -n 1 | sed 's/.*=[[:space:]]*//')
    _uecap_nr_identity=$(grep -o 'CellIdentityNr[^}]*' "$_uecap_radio_dump" | head -n 1)
    case "$_uecap_nr_identity" in
        ''|*null*|*none*) UECAP_RADIO_NR_REGISTERED=false ;;
        *) UECAP_RADIO_NR_REGISTERED=true ;;
    esac
    UECAP_RADIO_NR_BAND=$(printf '%s' "$_uecap_nr_identity" | sed -n 's/.*mBands=\[\([^]]*\)\].*/\1/p')
    UECAP_RADIO_NR_ARFCN=$(printf '%s' "$_uecap_nr_identity" | sed -n 's/.*mNrarfcn=\([^ ]*\).*/\1/p')
    # Prefer an explicit RAT token. In particular, NR_SA is valid with
    # isEnDcAvailable=false; that field describes EN-DC capability and must
    # never downgrade an explicit SA registration to an NSA failure.
    _uecap_radio_upper=$(printf '%s %s' "$_uecap_radio_text" "$_uecap_ril_radio" | tr '[:lower:]' '[:upper:]')
    case "$_uecap_radio_upper" in
        *NR_SA*|*NR-SA*|*NR\ SA*) UECAP_RADIO_ACTUAL_RAT=NR_SA ;;
        *NR_NSA*|*NR-NSA*|*EN-DC*|*ENDC*) UECAP_RADIO_ACTUAL_RAT=NR_NSA ;;
        *NR*)
            case "$_uecap_ril_radio:$UECAP_RADIO_ENDC_AVAILABLE" in
                20\(*:true|20:true|*:true) UECAP_RADIO_ACTUAL_RAT=NR_NSA ;;
                20\(*:false|20:false|20\(*:unknown|20:unknown) UECAP_RADIO_ACTUAL_RAT=NR_SA ;;
                *) UECAP_RADIO_ACTUAL_RAT=unknown ;;
            esac
            ;;
        *LTE*|*:13:*|*:13\(*:*) UECAP_RADIO_ACTUAL_RAT=LTE ;;
        *) UECAP_RADIO_ACTUAL_RAT=unknown ;;
    esac
    [ -n "$UECAP_RADIO_NR_AVAILABLE" ] || UECAP_RADIO_NR_AVAILABLE=unknown
    [ -n "$UECAP_RADIO_ENDC_AVAILABLE" ] || UECAP_RADIO_ENDC_AVAILABLE=unknown
    [ -n "$UECAP_RADIO_NR_BAND" ] || UECAP_RADIO_NR_BAND=unknown
    [ -n "$UECAP_RADIO_NR_ARFCN" ] || UECAP_RADIO_NR_ARFCN=unknown
    UECAP_RADIO_NR_RANGE=$(sed -n 's/.*mNrFrequencyRange=\([^,} ]*\).*/\1/p' "$_uecap_radio_dump" | head -n 1)
    [ -n "$UECAP_RADIO_NR_RANGE" ] || UECAP_RADIO_NR_RANGE=unknown
    UECAP_RADIO_LTE_ANCHOR=unknown
    case "$UECAP_RADIO_ACTUAL_RAT" in
        NR_SA)
            UECAP_RADIO_ENDC_AVAILABLE=not_applicable
            UECAP_RADIO_LTE_ANCHOR=not_applicable
            ;;
        NR_NSA)
            [ -n "$UECAP_RADIO_ENDC_AVAILABLE" ] || UECAP_RADIO_ENDC_AVAILABLE=unknown
            UECAP_RADIO_LTE_ANCHOR=observed_or_unknown
            ;;
    esac
    rm -f "$_uecap_radio_dump" 2>/dev/null
    return 0
}

uecap_bind_status() {
    _uecap_bind_source="$1"
    _uecap_bind_target_hash="$2"
    _uecap_bind_source_hash=$(uecap_hash "$_uecap_bind_source")
    _uecap_bind_context=$(ls -Zd "$UECAP_TARGET" 2>/dev/null | awk '{print $1}')
    _uecap_bind_expected_context=u:object_r:vendor_fw_file:s0
    [ -f "$_uecap_bind_source" ] \
        && [ -n "$_uecap_bind_source_hash" ] \
        && [ "$_uecap_bind_source_hash" = "$_uecap_bind_target_hash" ] \
        && [ "$_uecap_bind_context" = "$_uecap_bind_expected_context" ] \
        && { [ "$UECAP_BACKEND" = metamodule_content ] || [ "$UECAP_BACKEND" = hybrid_mount ] || uecap_target_is_mounted; } \
        && printf 'verified' \
        || printf 'unverified'
}

uecap_load_receipt_observation() {
    UECAP_DESIRED_PROFILE=$(uecap_receipt_get desired_profile 2>/dev/null)
    [ -n "$UECAP_DESIRED_PROFILE" ] || UECAP_DESIRED_PROFILE=$(uecap_receipt_get requested_mode 2>/dev/null)
    [ -n "$UECAP_DESIRED_PROFILE" ] || UECAP_DESIRED_PROFILE=$(uecap_current_mode)
    UECAP_BOUND_PROFILE=$(uecap_receipt_get bound_profile 2>/dev/null)
    [ -n "$UECAP_BOUND_PROFILE" ] || UECAP_BOUND_PROFILE=$(uecap_detect_active_mode)
    UECAP_MODEM_LOAD_STATE=$(uecap_receipt_get modem_load_state 2>/dev/null)
    [ -n "$UECAP_MODEM_LOAD_STATE" ] || UECAP_MODEM_LOAD_STATE=unknown
    UECAP_MODEM_LOADED_PROFILE=$(uecap_receipt_get modem_loaded_profile 2>/dev/null)
    [ -n "$UECAP_MODEM_LOADED_PROFILE" ] || UECAP_MODEM_LOADED_PROFILE=unknown
    UECAP_FUNCTIONAL_STATE=$(uecap_receipt_get functional_state 2>/dev/null)
    [ -n "$UECAP_FUNCTIONAL_STATE" ] || UECAP_FUNCTIONAL_STATE=unknown
    UECAP_RECEIPT_FRESHNESS=$(uecap_receipt_get receipt_freshness 2>/dev/null)
    [ -n "$UECAP_RECEIPT_FRESHNESS" ] || UECAP_RECEIPT_FRESHNESS=missing
}

uecap_write_runtime_receipt() {
    _uecap_receipt_mode="$1"
    _uecap_receipt_source_hash="$2"
    _uecap_receipt_target_hash="$3"
    _uecap_receipt_reason="$4"
    _uecap_receipt_apply="$5"
    _uecap_receipt_effective="$6"
    _uecap_receipt_now="$(date +%s 2>/dev/null || echo 0)"
    _uecap_receipt_tmp="${UECAP_RECEIPT_FILE}.tmp.$$"
    [ -n "$UECAP_RECEIPT_FILE" ] && [ ! -d "$UECAP_RECEIPT_FILE" ] || return 1
    if [ "$_uecap_receipt_mode" = stock ] && ! uecap_target_is_mounted; then
        _uecap_receipt_bind_status=stock_unmounted
    else
        _uecap_receipt_bind_status=$(uecap_bind_status "$(uecap_resolve_source "$_uecap_receipt_mode" 2>/dev/null)" "$_uecap_receipt_target_hash")
    fi
    _uecap_receipt_effective_context=$(ls -Zd "$UECAP_TARGET" 2>/dev/null | awk '{print $1}')
    _uecap_receipt_content_context=none
    if [ -n "${UECAP_CONTENT_IMAGE:-}" ] && [ "${UECAP_CONTENT_IMAGE:-}" != none ] \
        && [ -e "$UECAP_CONTENT_IMAGE" ]; then
        _uecap_receipt_content_context=$(ls -Zd "$UECAP_CONTENT_IMAGE" 2>/dev/null | awk '{print $1}')
    fi
    _uecap_receipt_effective_hash=$(uecap_hash "$UECAP_TARGET")
    _uecap_receipt_content_hash=none
    if [ -n "${UECAP_CONTENT_IMAGE:-}" ] && [ "${UECAP_CONTENT_IMAGE:-}" != none ] \
        && [ -f "$UECAP_CONTENT_IMAGE" ]; then
        _uecap_receipt_content_hash=$(uecap_hash "$UECAP_CONTENT_IMAGE")
    fi
    if [ "${UECAP_CONTEXT_VERIFIED:-unknown}" = unknown ]; then
        if [ "$_uecap_receipt_effective_context" = u:object_r:vendor_fw_file:s0 ] \
            && { [ "$_uecap_receipt_content_context" = u:object_r:vendor_fw_file:s0 ] \
                || [ "$_uecap_receipt_content_context" = none ]; }; then
            UECAP_CONTEXT_VERIFIED=true
        else
            UECAP_CONTEXT_VERIFIED=false
        fi
    fi
    uecap_payload_metadata "$_uecap_receipt_mode" >/dev/null 2>&1 || {
        UECAP_PAYLOAD_STATE=unverified
        UECAP_PAYLOAD_BUILD=unknown
        UECAP_PAYLOAD_BYTES=0
        UECAP_PAYLOAD_SHA=""
    }
    {
        printf 'schema=3\n'
        printf 'boot_id=%s\n' "$(uecap_receipt_value "$(uecap_boot_id)")"
        printf 'updated_at=%s\n' "$_uecap_receipt_now"
        printf 'reason=%s\n' "$(uecap_receipt_value "$_uecap_receipt_reason")"
        printf 'requested_mode=%s\n' "$(uecap_receipt_value "$_uecap_receipt_mode")"
        printf 'active_mode=%s\n' "$(uecap_receipt_value "$(uecap_detect_active_mode)")"
        printf 'source_hash=%s\n' "$(uecap_receipt_value "$_uecap_receipt_source_hash")"
        printf 'target_hash=%s\n' "$(uecap_receipt_value "$_uecap_receipt_target_hash")"
        printf 'backend=%s\n' "$(uecap_receipt_value "${UECAP_BACKEND:-unknown}")"
        printf 'content_image=%s\n' "$(uecap_receipt_value "${UECAP_CONTENT_IMAGE:-unknown}")"
        printf 'content_contract_hash=%s\n' "$(uecap_receipt_value "${_uecap_receipt_source_hash}")"
        printf 'effective_contract_hash=%s\n' "$(uecap_receipt_value "${_uecap_receipt_target_hash}")"
        printf 'content_hash=%s\n' "$(uecap_receipt_value "${_uecap_receipt_content_hash}")"
        printf 'effective_hash=%s\n' "$(uecap_receipt_value "${_uecap_receipt_effective_hash}")"
        printf 'mount_observed=%s\n' "$(uecap_receipt_value "${UECAP_MOUNT_OBSERVED:-unknown}")"
        printf 'context_verified=%s\n' "$(uecap_receipt_value "${UECAP_CONTEXT_VERIFIED:-unknown}")"
        printf 'content_context=%s\n' "$(uecap_receipt_value "$_uecap_receipt_content_context")"
        printf 'effective_context=%s\n' "$(uecap_receipt_value "$_uecap_receipt_effective_context")"
        printf 'bind_status=%s\n' "$(uecap_receipt_value "$_uecap_receipt_bind_status")"
        printf 'apply_result=%s\n' "$(uecap_receipt_value "$_uecap_receipt_apply")"
        printf 'reload_dispatched=%s\n' "$(uecap_receipt_value "${UECAP_RELOAD_DISPATCHED:-false}")"
        printf 'reload_result=%s\n' "$(uecap_receipt_value "${UECAP_RELOAD_RESULT:-not_run}")"
        printf 'effective_state=%s\n' "$(uecap_receipt_value "$_uecap_receipt_effective")"
        printf 'device=%s\n' "$(uecap_receipt_value "${UECAP_DEVICE:-unknown}")"
        printf 'device_policy=%s\n' "$(uecap_receipt_value "${UECAP_DEVICE_POLICY:-unknown}")"
        printf 'target_name=%s\n' "$(uecap_receipt_value "${UECAP_TARGET_NAME:-unknown}")"
        printf 'payload_state=%s\n' "$(uecap_receipt_value "$UECAP_PAYLOAD_STATE")"
        printf 'payload_source_build=%s\n' "$(uecap_receipt_value "$UECAP_PAYLOAD_BUILD")"
        printf 'payload_bytes=%s\n' "$(uecap_receipt_value "$UECAP_PAYLOAD_BYTES")"
        printf 'payload_sha256=%s\n' "$(uecap_receipt_value "$UECAP_PAYLOAD_SHA")"
        printf 'desired_profile=%s\n' "$(uecap_receipt_value "${UECAP_DESIRED_PROFILE:-unknown}")"
        printf 'bound_profile=%s\n' "$(uecap_receipt_value "${UECAP_BOUND_PROFILE:-unknown}")"
        printf 'modem_load_state=%s\n' "$(uecap_receipt_value "${UECAP_MODEM_LOAD_STATE:-unknown}")"
        printf 'modem_loaded_profile=%s\n' "$(uecap_receipt_value "${UECAP_MODEM_LOADED_PROFILE:-unknown}")"
        printf 'radio_observed_state=%s\n' "$(uecap_receipt_value "${UECAP_RADIO_OBSERVED_STATE:-unknown}")"
        printf 'functional_state=%s\n' "$(uecap_receipt_value "${UECAP_FUNCTIONAL_STATE:-unknown}")"
        printf 'receipt_freshness=%s\n' "$(uecap_receipt_value "${UECAP_RECEIPT_FRESHNESS:-unknown}")"
        printf 'actual_rat=%s\n' "$(uecap_receipt_value "${UECAP_RADIO_ACTUAL_RAT:-unknown}")"
        printf 'nr_available=%s\n' "$(uecap_receipt_value "${UECAP_RADIO_NR_AVAILABLE:-unknown}")"
        printf 'endc_available=%s\n' "$(uecap_receipt_value "${UECAP_RADIO_ENDC_AVAILABLE:-unknown}")"
        printf 'nr_registered=%s\n' "$(uecap_receipt_value "${UECAP_RADIO_NR_REGISTERED:-unknown}")"
        printf 'nr_band=%s\n' "$(uecap_receipt_value "${UECAP_RADIO_NR_BAND:-unknown}")"
        printf 'nr_arfcn=%s\n' "$(uecap_receipt_value "${UECAP_RADIO_NR_ARFCN:-unknown}")"
        printf 'nr_frequency_range=%s\n' "$(uecap_receipt_value "${UECAP_RADIO_NR_RANGE:-unknown}")"
        printf 'lte_anchor=%s\n' "$(uecap_receipt_value "${UECAP_RADIO_LTE_ANCHOR:-unknown}")"
        printf 'nsa_status=%s\n' "$(uecap_receipt_value "${UECAP_NSA_STATUS:-not_applicable}")"
        printf 'nsa_reason=%s\n' "$(uecap_receipt_value "${UECAP_NSA_REASON:-no_confirmed_nsa_cell}")"
    } > "$_uecap_receipt_tmp" 2>/dev/null \
        && mv "$_uecap_receipt_tmp" "$UECAP_RECEIPT_FILE" 2>/dev/null \
        && [ -f "$UECAP_RECEIPT_FILE" ]
    _uecap_receipt_rc=$?
    [ "$_uecap_receipt_rc" -eq 0 ] || rm -f "$_uecap_receipt_tmp" 2>/dev/null
    return "$_uecap_receipt_rc"
}

uecap_classify_radio_state() {
    case "${UECAP_RADIO_ACTUAL_RAT:-unknown}" in
        NR_SA|NR-SA|SA)
            UECAP_RADIO_OBSERVED_STATE="NR_SA"
            UECAP_NSA_STATUS="not_applicable"
            UECAP_NSA_REASON="sa_observed"
            ;;
        NR_NSA|NR-NSA|NSA)
            UECAP_RADIO_OBSERVED_STATE="NR_NSA"
            UECAP_NSA_STATUS="observed"
            UECAP_NSA_REASON="nr_nsa_observed"
            ;;
        LTE|LTE_CA)
            UECAP_RADIO_OBSERVED_STATE="LTE"
            UECAP_NSA_STATUS="not_applicable"
            UECAP_NSA_REASON="no_confirmed_nsa_cell"
            ;;
        *)
            UECAP_RADIO_OBSERVED_STATE="UNKNOWN"
            UECAP_NSA_STATUS="not_applicable"
            UECAP_NSA_REASON="no_confirmed_nsa_cell"
            ;;
    esac
}

uecap_refresh_observed_state() {
    UECAP_DESIRED_PROFILE=$(uecap_current_manual_mode)
    UECAP_BOUND_PROFILE="unknown"
    UECAP_MODEM_LOAD_STATE="unknown"
    UECAP_MODEM_LOADED_PROFILE="unknown"
    UECAP_FUNCTIONAL_STATE="unknown"
    UECAP_RECEIPT_FRESHNESS="missing"
    UECAP_NSA_STATUS="not_applicable"
    UECAP_NSA_REASON="no_confirmed_nsa_cell"
    _uecap_observed_target_hash=$(uecap_hash "$UECAP_TARGET")
    _uecap_observed_source=""
    _uecap_observed_source_hash=""

    if ! uecap_is_available; then
        UECAP_DESIRED_PROFILE="disabled"
        UECAP_BOUND_PROFILE="unknown"
        UECAP_MODEM_LOAD_STATE="not_managed"
        UECAP_FUNCTIONAL_STATE="external_or_disabled"
    else
        if [ "$UECAP_DESIRED_PROFILE" = stock ]; then
            _uecap_observed_source_hash="$_uecap_observed_target_hash"
        else
            _uecap_observed_source=$(uecap_resolve_source "$UECAP_DESIRED_PROFILE" 2>/dev/null || true)
            _uecap_observed_source_hash=$(uecap_hash "$_uecap_observed_source")
        fi
        if [ "$UECAP_BACKEND" = metamodule_content ] || [ "$UECAP_BACKEND" = hybrid_mount ]; then
            uecap_meta_readback_mode "$UECAP_DESIRED_PROFILE" >/dev/null 2>&1 || true
            UECAP_BOUND_PROFILE=$(uecap_detect_active_mode)
        elif [ "$UECAP_DESIRED_PROFILE" = stock ] && ! uecap_target_is_mounted; then
            UECAP_BOUND_PROFILE=stock
        elif [ -n "$_uecap_observed_target_hash" ] && uecap_target_is_mounted; then
            UECAP_BOUND_PROFILE=$(uecap_detect_active_mode)
        elif [ -n "$_uecap_observed_target_hash" ]; then
            UECAP_BOUND_PROFILE="stock_or_unmounted"
        else
            UECAP_BOUND_PROFILE="missing"
        fi

        _uecap_receipt_boot=$(uecap_receipt_get boot_id 2>/dev/null)
        _uecap_receipt_schema=$(uecap_receipt_get schema 2>/dev/null)
        _uecap_receipt_target=$(uecap_receipt_get target_hash 2>/dev/null)
        _uecap_receipt_source=$(uecap_receipt_get source_hash 2>/dev/null)
        if [ "$_uecap_receipt_schema" = "3" ] \
            && [ -n "$_uecap_receipt_boot" ] && [ "$_uecap_receipt_boot" = "$(uecap_boot_id)" ] \
            && [ "$_uecap_receipt_target" = "$_uecap_observed_target_hash" ] \
            && [ "$_uecap_receipt_source" = "$_uecap_observed_source_hash" ]; then
            UECAP_RECEIPT_FRESHNESS="current_boot"
        elif [ -n "$_uecap_receipt_boot" ]; then
            UECAP_RECEIPT_FRESHNESS="stale_or_mismatched"
        fi
        UECAP_MODEM_LOAD_STATE=$(uecap_receipt_get modem_load_state 2>/dev/null)
        [ -n "$UECAP_MODEM_LOAD_STATE" ] || UECAP_MODEM_LOAD_STATE="unknown"
        UECAP_MODEM_LOADED_PROFILE=$(uecap_receipt_get modem_loaded_profile 2>/dev/null)
        [ -n "$UECAP_MODEM_LOADED_PROFILE" ] || UECAP_MODEM_LOADED_PROFILE="unknown"
        if [ "$UECAP_RECEIPT_FRESHNESS" != "current_boot" ]; then
            UECAP_MODEM_LOADED_PROFILE="unknown"
            case "$UECAP_MODEM_LOAD_STATE" in
                confirmed_readback|reload_accepted|pre_modem_bind) UECAP_MODEM_LOAD_STATE="stale_receipt" ;;
            esac
        fi
        case "$UECAP_MODEM_LOAD_STATE:$UECAP_RECEIPT_FRESHNESS" in
            confirmed_readback:current_boot)
                UECAP_FUNCTIONAL_STATE="verified"
                ;;
            reload_accepted:current_boot|pre_modem_bind:current_boot)
                UECAP_FUNCTIONAL_STATE="modem_load_unconfirmed"
                ;;
            reload_failed:*)
                UECAP_FUNCTIONAL_STATE="unverified"
                ;;
            stale_receipt:*)
                UECAP_FUNCTIONAL_STATE="stale_receipt"
                ;;
            *)
                UECAP_FUNCTIONAL_STATE="unverified"
                ;;
        esac
    fi
    # Do not block a status CGI on a telephony binder dump. A radio snapshot
    # is diagnostic only; the same-boot receipt remains authoritative for the
    # content/effective contract and the next explicit refresh may collect it.
    UECAP_RADIO_SNAPSHOT_RESULT=deferred
    uecap_classify_radio_state
}

uecap_pre_modem_receipt_is_current() {
    _uecap_pre_modem_mode="$1"
    uecap_is_valid_mode "$_uecap_pre_modem_mode" || return 1
    if [ "$UECAP_BACKEND" = metamodule_content ] || [ "$UECAP_BACKEND" = hybrid_mount ]; then
        uecap_meta_readback_mode "$_uecap_pre_modem_mode" || return 1
        [ "$(uecap_receipt_get schema)" = "3" ] \
            && [ "$(uecap_receipt_get boot_id)" = "$(uecap_boot_id)" ] \
            && [ "$(uecap_receipt_get reason)" = "pre_modem" ] \
            && [ "$(uecap_receipt_get requested_mode)" = "$_uecap_pre_modem_mode" ] \
            && [ "$(uecap_receipt_get active_mode)" = "$_uecap_pre_modem_mode" ] \
            && [ "$(uecap_receipt_get backend)" = "$UECAP_BACKEND" ] \
            && [ "$(uecap_receipt_get reload_result)" = not_required_pre_modem ] \
            && [ "$(uecap_receipt_get mount_observed)" = "$UECAP_MOUNT_OBSERVED" ] \
            && [ "$(uecap_receipt_get context_verified)" = true ] \
            && [ "$(uecap_receipt_get source_hash)" = "$UECAP_READBACK_SOURCE_HASH" ] \
            && [ "$(uecap_receipt_get target_hash)" = "$UECAP_READBACK_EFFECTIVE_HASH" ] \
            && [ "$(uecap_receipt_get content_hash)" = "$UECAP_READBACK_CONTENT_HASH" ] \
            && [ "$(uecap_receipt_get effective_hash)" = "$UECAP_READBACK_EFFECTIVE_HASH" ] \
            && [ "$(uecap_receipt_get content_context)" = "$UECAP_READBACK_CONTENT_CONTEXT" ] \
            && [ "$(uecap_receipt_get effective_context)" = "$UECAP_READBACK_EFFECTIVE_CONTEXT" ]
        return $?
    fi
    if [ "$_uecap_pre_modem_mode" = stock ]; then
        _uecap_pre_modem_target_hash=$(uecap_hash "$UECAP_TARGET")
        [ -n "$_uecap_pre_modem_target_hash" ] \
            && ! uecap_target_is_mounted \
            && [ "$(uecap_receipt_get schema)" = "3" ] \
            && [ "$(uecap_receipt_get boot_id)" = "$(uecap_boot_id)" ] \
            && [ "$(uecap_receipt_get reason)" = "pre_modem" ] \
            && [ "$(uecap_receipt_get requested_mode)" = stock ] \
            && [ "$(uecap_receipt_get active_mode)" = stock ] \
            && [ "$(uecap_receipt_get bind_status)" = stock_unmounted ] \
            && [ "$(uecap_receipt_get backend)" = metamodule_content ] \
            && [ "$(uecap_receipt_get mount_observed)" = stock_unmounted ] \
            && [ "$(uecap_receipt_get context_verified)" = true ] \
            && [ "$(uecap_receipt_get content_hash)" = none ] \
            && [ "$(uecap_receipt_get effective_hash)" = "$_uecap_pre_modem_target_hash" ] \
            && [ "$(uecap_receipt_get content_context)" = none ] \
            && [ "$(uecap_receipt_get effective_context)" = u:object_r:vendor_fw_file:s0 ] \
            && [ "$(uecap_receipt_get source_hash)" = "$_uecap_pre_modem_target_hash" ] \
            && [ "$(uecap_receipt_get target_hash)" = "$_uecap_pre_modem_target_hash" ] \
            && [ "$(uecap_receipt_get reload_result)" = not_required_pre_modem ]
        return $?
    fi
    _uecap_pre_modem_source=$(uecap_resolve_source "$_uecap_pre_modem_mode") || return 1
    _uecap_pre_modem_source_hash=$(uecap_hash "$_uecap_pre_modem_source")
    _uecap_pre_modem_target_hash=$(uecap_hash "$UECAP_TARGET")
    [ -n "$_uecap_pre_modem_source_hash" ] \
        && [ "$_uecap_pre_modem_source_hash" = "$_uecap_pre_modem_target_hash" ] \
        && [ "$(uecap_receipt_get schema)" = "3" ] \
        && [ "$(uecap_receipt_get boot_id)" = "$(uecap_boot_id)" ] \
        && [ "$(uecap_receipt_get reason)" = "pre_modem" ] \
        && [ "$(uecap_receipt_get requested_mode)" = "$_uecap_pre_modem_mode" ] \
        && [ "$(uecap_receipt_get active_mode)" = "$_uecap_pre_modem_mode" ] \
        && [ "$(uecap_receipt_get bind_status)" = "verified" ] \
        && [ "$(uecap_receipt_get source_hash)" = "$_uecap_pre_modem_source_hash" ] \
        && [ "$(uecap_receipt_get target_hash)" = "$_uecap_pre_modem_target_hash" ] \
        && [ "$(uecap_receipt_get reload_result)" = "not_required_pre_modem" ]
}

uecap_restore_file() {
    if [ "$2" = "1" ]; then
        uecap_atomic_write "$1" "$3"
    else
        rm -f "$1" 2>/dev/null
    fi
}

uecap_commit_state() {
    _uecap_commit_mode="$1"
    _uecap_commit_reason="$2"
    _uecap_commit_time="$3"
    case "$_uecap_commit_reason" in ''|*[!A-Za-z0-9_.:-]*) return 1 ;; esac
    case "$_uecap_commit_time" in ''|*[!0-9]*) return 1 ;; esac

    _uecap_mode_existed=0; [ -e "$UECAP_MODE_FILE" ] && _uecap_mode_existed=1
    _uecap_manual_existed=0; [ -e "$UECAP_MANUAL_MODE_FILE" ] && _uecap_manual_existed=1
    _uecap_policy_existed=0; [ -e "$UECAP_POLICY_FILE" ] && _uecap_policy_existed=1
    _uecap_reason_existed=0; [ -e "$UECAP_REASON_FILE" ] && _uecap_reason_existed=1
    _uecap_switch_existed=0; [ -e "$UECAP_SWITCH_FILE" ] && _uecap_switch_existed=1
    _uecap_mode_old=$(cat "$UECAP_MODE_FILE" 2>/dev/null)
    _uecap_manual_old=$(cat "$UECAP_MANUAL_MODE_FILE" 2>/dev/null)
    _uecap_policy_old=$(cat "$UECAP_POLICY_FILE" 2>/dev/null)
    _uecap_reason_old=$(cat "$UECAP_REASON_FILE" 2>/dev/null)
    _uecap_switch_old=$(cat "$UECAP_SWITCH_FILE" 2>/dev/null)

    UECAP_STATE_ROLLBACK_RESULT="not_needed"
    if uecap_set_mode "$_uecap_commit_mode" \
        && uecap_set_manual_mode "$_uecap_commit_mode" \
        && uecap_set_policy "$UECAP_DEVICE_POLICY" \
        && uecap_set_reason "$_uecap_commit_reason" \
        && uecap_set_switch_time "$_uecap_commit_time"; then
        return 0
    fi

    _uecap_restore_failed=0
    uecap_restore_file "$UECAP_MODE_FILE" "$_uecap_mode_existed" "$_uecap_mode_old" || _uecap_restore_failed=1
    uecap_restore_file "$UECAP_MANUAL_MODE_FILE" "$_uecap_manual_existed" "$_uecap_manual_old" || _uecap_restore_failed=1
    uecap_restore_file "$UECAP_POLICY_FILE" "$_uecap_policy_existed" "$_uecap_policy_old" || _uecap_restore_failed=1
    uecap_restore_file "$UECAP_REASON_FILE" "$_uecap_reason_existed" "$_uecap_reason_old" || _uecap_restore_failed=1
    uecap_restore_file "$UECAP_SWITCH_FILE" "$_uecap_switch_existed" "$_uecap_switch_old" || _uecap_restore_failed=1
    if [ "$_uecap_restore_failed" -eq 0 ]; then
        UECAP_STATE_ROLLBACK_RESULT="complete"
    else
        UECAP_STATE_ROLLBACK_RESULT="incomplete"
    fi
    return 1
}

uecap_set_mode() {
    _uecap_set_mode_value=$(uecap_mode_label "$1")
    [ "$_uecap_set_mode_value" != "unknown" ] || return 1
    uecap_atomic_write "$UECAP_MODE_FILE" "$_uecap_set_mode_value"
}

uecap_set_manual_mode() {
    _uecap_set_manual_value=$(uecap_mode_label "$1")
    [ "$_uecap_set_manual_value" != "unknown" ] || return 1
    uecap_atomic_write "$UECAP_MANUAL_MODE_FILE" "$_uecap_set_manual_value"
}

uecap_set_policy() {
    case "$1" in
        managed_profiles|single_candidate) uecap_atomic_write "$UECAP_POLICY_FILE" "$1" ;;
        *) return 1 ;;
    esac
}

uecap_set_reason() {
    case "$1" in ''|*[!A-Za-z0-9_.:-]*) return 1 ;; esac
    uecap_atomic_write "$UECAP_REASON_FILE" "$1"
}

uecap_set_switch_time() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    uecap_atomic_write "$UECAP_SWITCH_FILE" "$1"
}

uecap_resolve_source() {
    uecap_is_valid_mode "$1" || return 1
    uecap_payload_source "$1"
}

uecap_print_ui_contract_json() {
    if ! uecap_is_available; then
        printf '{"mode_order":[],"default_mode":"disabled"}'
        return 0
    fi
    printf '{"mode_order":['
    _uecap_contract_first=1
    for _uecap_contract_mode in $UECAP_MODE_ORDER; do
        [ "$_uecap_contract_first" -eq 1 ] && _uecap_contract_first=0 || printf ','
        printf '"%s"' "$_uecap_contract_mode"
    done
    printf '],"default_mode":"%s"}' "$UECAP_DEFAULT_MODE"
}

uecap_reload_modem() {
    _uecap_reload_reason="${1:-manual}"
    UECAP_RELOAD_DISPATCHED=false
    UECAP_RELOAD_RESULT="not_run"
    if [ "$_uecap_reload_reason" = "pre_modem" ]; then
        UECAP_RELOAD_RESULT="not_required_pre_modem"
        UECAP_MODEM_LOAD_STATE="pre_modem_bind"
        if [ "$UECAP_BACKEND" = metamodule_content ]; then
            uecap_log_line "UECap effective target verified from MetaModule content image; modem load remains unconfirmed"
        else
            uecap_log_line "UECap bind verified after mount; modem load remains unconfirmed"
        fi
        return 0
    fi
    if [ "${PIXEL9PRO_UECAP_TEST_MODE:-0}" = "1" ]; then
        case "${PIXEL9PRO_UECAP_RESTART_MODEM_RESULT:-success}" in
            fail)
                UECAP_RELOAD_RESULT="failed"
                UECAP_MODEM_LOAD_STATE="reload_failed"
                uecap_log_line "modem restart test failure (reason=$_uecap_reload_reason)"
                return 1
                ;;
        esac
        UECAP_RELOAD_DISPATCHED=true
        UECAP_RELOAD_RESULT="success"
        UECAP_MODEM_LOAD_STATE="reload_accepted"
        uecap_log_line "modem restart test accepted (reason=$_uecap_reload_reason)"
        return 0
    fi
    # restart-modem only cycles cellular radio, does NOT touch WiFi/BT
    # Much safer than airplane toggle which crashed the network stack (B29)
    if /system/bin/cmd phone restart-modem >/dev/null 2>&1; then
        UECAP_RELOAD_DISPATCHED=true
        UECAP_RELOAD_RESULT="success"
        UECAP_MODEM_LOAD_STATE="reload_accepted"
        uecap_log_line "modem restart accepted (reason=$_uecap_reload_reason)"
        return 0
    fi
    UECAP_RELOAD_RESULT="failed"
    UECAP_MODEM_LOAD_STATE="reload_failed"
    uecap_log_line "modem restart failed (reason=$_uecap_reload_reason)"
    return 1
}

uecap_detect_active_mode() {
    if ! uecap_is_available; then
        echo unknown
        return 0
    fi
    if [ "$UECAP_BACKEND" = metamodule_content ] || [ "$UECAP_BACKEND" = hybrid_mount ]; then
        for _uecap_detect_mode in $UECAP_MODE_ORDER; do
            if uecap_meta_readback_mode "$_uecap_detect_mode" >/dev/null 2>&1; then
                echo "$_uecap_detect_mode"
                return 0
            fi
        done
        echo unknown
        return 0
    fi
    uecap_target_is_mounted || { echo stock; return 0; }
    _uecap_detect_target_hash=$(uecap_hash "$UECAP_TARGET")
    [ -n "$_uecap_detect_target_hash" ] || { echo unknown; return 0; }

    # Prefer the recorded mode if its hash matches; then scan this device's
    # manifest modes only. The other SKU is never a candidate.
    _uecap_detect_requested=$(uecap_current_mode)
    if [ "$_uecap_detect_requested" != stock ]; then
        _uecap_detect_requested_source=$(uecap_resolve_source "$_uecap_detect_requested" 2>/dev/null)
        _uecap_detect_requested_hash=$(uecap_hash "$_uecap_detect_requested_source")
        if [ -n "$_uecap_detect_requested_hash" ] \
            && [ "$_uecap_detect_target_hash" = "$_uecap_detect_requested_hash" ]; then
            echo "$_uecap_detect_requested"
            return 0
        fi
    fi
    for _uecap_detect_mode in $UECAP_MODE_ORDER; do
        [ "$_uecap_detect_mode" != stock ] || continue
        _uecap_detect_source=$(uecap_resolve_source "$_uecap_detect_mode" 2>/dev/null) || continue
        _uecap_detect_source_hash=$(uecap_hash "$_uecap_detect_source")
        if [ -n "$_uecap_detect_source_hash" ] \
            && [ "$_uecap_detect_target_hash" = "$_uecap_detect_source_hash" ]; then
            echo "$_uecap_detect_mode"
            return 0
        fi
    done
    echo unknown
}
uecap_restore_previous_mount() {
    _uecap_restore_old_mounted="$1"
    _uecap_restore_old_source="$2"
    _uecap_restore_old_hash="$3"
    if uecap_target_is_mounted && ! uecap_unmount "$UECAP_TARGET"; then
        return 1
    fi
    if [ "$_uecap_restore_old_mounted" -eq 1 ]; then
        [ -f "$_uecap_restore_old_source" ] && [ -n "$_uecap_restore_old_hash" ] || return 1
        uecap_mount_bind "$_uecap_restore_old_source" "$UECAP_TARGET" || return 1
        [ "$(uecap_hash "$UECAP_TARGET")" = "$_uecap_restore_old_hash" ] || return 1
        uecap_target_is_mounted
        return $?
    fi
    ! uecap_target_is_mounted
}

uecap_apply_mode() {
    UECAP_APPLY_RESULT="invalid"
    uecap_is_available || {
        UECAP_APPLY_RESULT="device_not_managed"
        return 1
    }
    if [ "$UECAP_BACKEND" = metamodule_content ]; then
        UECAP_APPLY_RESULT="metamodule_requires_reinstall"
        uecap_log_line "UECap mode change rejected: MetaModule content staging requires module reinstall and reboot"
        return 4
    fi
    _uecap_apply_mode_value=$(uecap_mode_label "$1")
    [ "$_uecap_apply_mode_value" != "unknown" ] || return 1
    _uecap_apply_reason="${2:-manual}"
    case "$_uecap_apply_reason" in ''|*[!A-Za-z0-9_.:-]*) return 1 ;; esac

    if [ "$UECAP_BACKEND" = hybrid_mount ]; then
        uecap_stage_mode "$_uecap_apply_mode_value" || {
            UECAP_APPLY_RESULT="hybrid_stage_failed"
            return 1
        }
        _uecap_hybrid_switch_time=$(date +%s 2>/dev/null || echo 0)
        uecap_commit_state "$_uecap_apply_mode_value" "$_uecap_apply_reason" "$_uecap_hybrid_switch_time" || {
            UECAP_APPLY_RESULT="hybrid_state_commit_failed"
            return 1
        }
        uecap_atomic_write "$MODDIR/.uecap_reboot_required" 1 || {
            UECAP_APPLY_RESULT="hybrid_reboot_marker_failed"
            return 1
        }
        UECAP_APPLY_RESULT=staged_reboot_required
        UECAP_MOUNT_OBSERVED=pending_reboot
        UECAP_RELOAD_RESULT=not_required_pre_modem
        UECAP_FUNCTIONAL_STATE=pending_reboot
        return 5
    fi

    if [ "$_uecap_apply_mode_value" = stock ]; then
        [ -e "$UECAP_TARGET" ] || { UECAP_APPLY_RESULT="target_missing"; return 1; }
        _uecap_apply_old_mounted=0
        _uecap_apply_old_source=""
        _uecap_apply_old_hash=""
        if uecap_target_is_mounted; then
            _uecap_apply_old_mounted=1
            _uecap_apply_old_mode=$(uecap_detect_active_mode)
            if ! uecap_is_valid_mode "$_uecap_apply_old_mode" \
                || [ "$_uecap_apply_old_mode" = stock ]; then
                UECAP_APPLY_RESULT="unknown_active_bind"
                return 1
            fi
            _uecap_apply_old_source=$(uecap_resolve_source "$_uecap_apply_old_mode") || return 1
            _uecap_apply_old_hash=$(uecap_hash "$_uecap_apply_old_source")
            [ -n "$_uecap_apply_old_hash" ] || return 1
            uecap_unmount "$UECAP_TARGET" || { UECAP_APPLY_RESULT="unbind_failed"; return 1; }
        fi
        _uecap_apply_target_hash=$(uecap_hash "$UECAP_TARGET")
        [ -n "$_uecap_apply_target_hash" ] && ! uecap_target_is_mounted \
            || { UECAP_APPLY_RESULT="stock_readback_unconfirmed"; return 1; }
        _uecap_apply_switch_time=$(date +%s 2>/dev/null || echo 0)
        if ! uecap_commit_state stock "$_uecap_apply_reason" "$_uecap_apply_switch_time"; then
            if uecap_restore_previous_mount "$_uecap_apply_old_mounted" "$_uecap_apply_old_source" "$_uecap_apply_old_hash" \
                && [ "$UECAP_STATE_ROLLBACK_RESULT" = complete ]; then
                UECAP_APPLY_RESULT="state_failed_rolled_back"
                return 1
            fi
            UECAP_APPLY_RESULT="state_failed_rollback_incomplete"
            return 2
        fi
        UECAP_DESIRED_PROFILE=stock
        UECAP_BOUND_PROFILE=stock
        UECAP_MOUNT_OBSERVED=stock_unmounted
        if uecap_reload_modem "$_uecap_apply_reason"; then
            UECAP_FUNCTIONAL_STATE="modem_load_unconfirmed"
            UECAP_RECEIPT_FRESHNESS="current_boot"
            UECAP_APPLY_RESULT="applied"
            uecap_capture_radio_snapshot >/dev/null 2>&1 || true
            uecap_classify_radio_state
            uecap_write_runtime_receipt stock "$_uecap_apply_target_hash" "$_uecap_apply_target_hash" \
                "$_uecap_apply_reason" applied stock_unmounted >/dev/null 2>&1 \
                || uecap_log_line "WARNING: failed to persist stock UECap receipt"
            return 0
        fi
        UECAP_APPLY_RESULT="applied_reload_failed"
        UECAP_FUNCTIONAL_STATE="unverified"
        UECAP_RECEIPT_FRESHNESS="stale_after_reload_failure"
        uecap_write_runtime_receipt stock "$_uecap_apply_target_hash" "$_uecap_apply_target_hash" \
            "$_uecap_apply_reason" applied_reload_failed unverified >/dev/null 2>&1 || true
        return 3
    fi

    _uecap_apply_source=$(uecap_resolve_source "$_uecap_apply_mode_value")
    [ -f "$_uecap_apply_source" ] || {
        uecap_log_line "SOURCE_MISSING_mode_$_uecap_apply_mode_value"
        return 1
    }
    [ -e "$UECAP_TARGET" ] || {
        uecap_log_line "TARGET_MISSING"
        return 1
    }

    _uecap_apply_source_hash=$(uecap_hash "$_uecap_apply_source")
    [ -n "$_uecap_apply_source_hash" ] || return 1

    _uecap_apply_target_ctx=$(ls -Zd "$UECAP_TARGET" 2>/dev/null | awk '{print $1}')
    _uecap_apply_source_ctx=$(ls -Zd "$_uecap_apply_source" 2>/dev/null | awk '{print $1}')
    if [ -n "$_uecap_apply_target_ctx" ] && [ "$_uecap_apply_source_ctx" != "$_uecap_apply_target_ctx" ]; then
        chcon "$_uecap_apply_target_ctx" "$_uecap_apply_source" 2>/dev/null || {
            uecap_log_line "SELinux context update failed mode=$_uecap_apply_mode_value"
            return 1
        }
        _uecap_apply_source_ctx=$(ls -Zd "$_uecap_apply_source" 2>/dev/null | awk '{print $1}')
        [ "$_uecap_apply_source_ctx" = "$_uecap_apply_target_ctx" ] || return 1
    fi

    _uecap_apply_old_mounted=0
    _uecap_apply_old_source=""
    _uecap_apply_old_hash=""
    if uecap_target_is_mounted; then
        _uecap_apply_old_mounted=1
        _uecap_apply_old_mode=$(uecap_detect_active_mode)
        if ! uecap_is_valid_mode "$_uecap_apply_old_mode" \
            || [ "$_uecap_apply_old_mode" = stock ]; then
            uecap_log_line "refuse to replace unknown active bind"
            return 1
        fi
        _uecap_apply_old_source=$(uecap_resolve_source "$_uecap_apply_old_mode") || return 1
        _uecap_apply_old_hash=$(uecap_hash "$_uecap_apply_old_source")
        [ -n "$_uecap_apply_old_hash" ] || return 1
        uecap_unmount "$UECAP_TARGET" || {
            uecap_log_line "unbind failed mode=$_uecap_apply_mode_value"
            return 1
        }
    fi

    if ! uecap_mount_bind "$_uecap_apply_source" "$UECAP_TARGET"; then
        if uecap_restore_previous_mount "$_uecap_apply_old_mounted" "$_uecap_apply_old_source" "$_uecap_apply_old_hash"; then
            UECAP_APPLY_RESULT="bind_failed_rolled_back"
            uecap_log_line "bind failed mode=$_uecap_apply_mode_value rollback=complete"
            return 1
        fi
        UECAP_APPLY_RESULT="bind_failed_rollback_incomplete"
        uecap_log_line "bind failed mode=$_uecap_apply_mode_value rollback=incomplete"
        return 2
    fi

    if [ "$(uecap_hash "$UECAP_TARGET")" != "$_uecap_apply_source_hash" ]; then
        if uecap_restore_previous_mount "$_uecap_apply_old_mounted" "$_uecap_apply_old_source" "$_uecap_apply_old_hash"; then
            UECAP_APPLY_RESULT="bind_verify_failed_rolled_back"
            uecap_log_line "bind verification failed mode=$_uecap_apply_mode_value rollback=complete"
            return 1
        fi
        UECAP_APPLY_RESULT="bind_verify_failed_rollback_incomplete"
        uecap_log_line "bind verification failed mode=$_uecap_apply_mode_value rollback=incomplete"
        return 2
    fi
    UECAP_BOUND_PROFILE="$_uecap_apply_mode_value"
    UECAP_MOUNT_OBSERVED=bind

    _uecap_apply_switch_time=$(date +%s 2>/dev/null || echo 0)
    if ! uecap_commit_state "$_uecap_apply_mode_value" "$_uecap_apply_reason" "$_uecap_apply_switch_time"; then
        if uecap_restore_previous_mount "$_uecap_apply_old_mounted" "$_uecap_apply_old_source" "$_uecap_apply_old_hash" \
            && [ "$UECAP_STATE_ROLLBACK_RESULT" = "complete" ]; then
            UECAP_APPLY_RESULT="state_failed_rolled_back"
            uecap_log_line "state transaction failed mode=$_uecap_apply_mode_value rollback=complete"
            return 1
        fi
        UECAP_APPLY_RESULT="state_failed_rollback_incomplete"
        uecap_log_line "state transaction failed mode=$_uecap_apply_mode_value rollback=incomplete state=$UECAP_STATE_ROLLBACK_RESULT"
        return 2
    fi
    uecap_log_line "bind ok mode=$_uecap_apply_mode_value hash=$(uecap_hash "$_uecap_apply_source")"
    if uecap_reload_modem "$_uecap_apply_reason"; then
        [ "${UECAP_RELOAD_RESULT:-not_run}" = "not_run" ] \
            && UECAP_RELOAD_RESULT="success"
        _uecap_effective_state="reload_accepted"
        [ "$UECAP_RELOAD_RESULT" = "not_required_pre_modem" ] \
            && _uecap_effective_state="pre_modem_bind"
        UECAP_MODEM_LOADED_PROFILE="unknown"
        UECAP_FUNCTIONAL_STATE="modem_load_unconfirmed"
        if [ "${PIXEL9PRO_UECAP_TEST_MODE:-0}" = "1" ] \
            && [ -n "${PIXEL9PRO_UECAP_MODEM_LOADED_PROFILE:-}" ] \
            && uecap_is_valid_mode "$PIXEL9PRO_UECAP_MODEM_LOADED_PROFILE"; then
            UECAP_MODEM_LOADED_PROFILE="$PIXEL9PRO_UECAP_MODEM_LOADED_PROFILE"
            UECAP_MODEM_LOAD_STATE="confirmed_readback"
            UECAP_FUNCTIONAL_STATE="verified"
        fi
        UECAP_RECEIPT_FRESHNESS="current_boot"
        UECAP_APPLY_RESULT="applied"
        UECAP_DESIRED_PROFILE="$_uecap_apply_mode_value"
        uecap_capture_radio_snapshot >/dev/null 2>&1 || true
        uecap_classify_radio_state
        uecap_write_runtime_receipt "$_uecap_apply_mode_value" "$_uecap_apply_source_hash" \
            "$(uecap_hash "$UECAP_TARGET")" "$_uecap_apply_reason" "applied" "$_uecap_effective_state" \
            >/dev/null 2>&1 || uecap_log_line "WARNING: failed to persist UECap runtime receipt"
        return 0
    fi
    [ "${UECAP_RELOAD_RESULT:-not_run}" = "not_run" ] \
        && UECAP_RELOAD_RESULT="failed"
    UECAP_APPLY_RESULT="applied_reload_failed"
    UECAP_MODEM_LOAD_STATE="reload_failed"
    UECAP_MODEM_LOADED_PROFILE="unknown"
    UECAP_FUNCTIONAL_STATE="unverified"
    UECAP_RECEIPT_FRESHNESS="stale_after_reload_failure"
    UECAP_DESIRED_PROFILE="$_uecap_apply_mode_value"
    uecap_capture_radio_snapshot >/dev/null 2>&1 || true
    uecap_classify_radio_state
    uecap_write_runtime_receipt "$_uecap_apply_mode_value" "$_uecap_apply_source_hash" \
        "$(uecap_hash "$UECAP_TARGET")" "$_uecap_apply_reason" "applied_reload_failed" "unverified" \
        >/dev/null 2>&1 || uecap_log_line "WARNING: failed to persist UECap runtime receipt"
    return 3
}

uecap_print_status_json() {
    uecap_refresh_runtime_policy
    uecap_refresh_observed_state
    _uecap_status_requested=$(uecap_current_mode)
    _uecap_status_policy=$(uecap_current_policy)
    _uecap_status_manual=$(uecap_current_manual_mode)
    _uecap_status_reason=$(uecap_current_reason)
    _uecap_status_active=$(uecap_detect_active_mode)
    _uecap_status_target_hash=$(uecap_hash "$UECAP_TARGET")
    _uecap_status_special_hash=$(uecap_hash "$UECAP_SPECIAL")
    _uecap_status_balanced_hash=$(uecap_hash "$UECAP_BALANCED")
    _uecap_status_universal_hash=$(uecap_hash "$UECAP_UNIVERSAL")
    _uecap_status_candidate_hash=$(uecap_hash "$UECAP_CANDIDATE")
    _uecap_status_meta_mode="$_uecap_status_requested"
    [ "$UECAP_DEVICE_POLICY" = single_candidate ] && _uecap_status_meta_mode=candidate
    uecap_payload_metadata "$_uecap_status_meta_mode" >/dev/null 2>&1 || {
        UECAP_PAYLOAD_STATE=unverified
        UECAP_PAYLOAD_BUILD=unknown
        UECAP_PAYLOAD_BYTES=0
        UECAP_PAYLOAD_SHA=""
    }
    _uecap_status_last_switch=$(uecap_last_switch)
    case "$_uecap_status_last_switch" in ''|*[!0-9]*) _uecap_status_last_switch=0 ;; esac

    _uecap_receipt_schema=$(uecap_receipt_get schema); [ -n "$_uecap_receipt_schema" ] || _uecap_receipt_schema=0
    _uecap_receipt_boot_id=$(uecap_receipt_get boot_id); [ -n "$_uecap_receipt_boot_id" ] || _uecap_receipt_boot_id=unknown
    _uecap_receipt_updated_at=$(uecap_receipt_get updated_at); [ -n "$_uecap_receipt_updated_at" ] || _uecap_receipt_updated_at=0
    _uecap_receipt_reason=$(uecap_receipt_get reason); [ -n "$_uecap_receipt_reason" ] || _uecap_receipt_reason=unknown
    _uecap_receipt_apply=$(uecap_receipt_get apply_result); [ -n "$_uecap_receipt_apply" ] || _uecap_receipt_apply=unknown
    _uecap_receipt_reload_dispatched=$(uecap_receipt_get reload_dispatched); [ -n "$_uecap_receipt_reload_dispatched" ] || _uecap_receipt_reload_dispatched=false
    case "$_uecap_receipt_reload_dispatched" in true|false) ;; *) _uecap_receipt_reload_dispatched=false ;; esac
    _uecap_receipt_reload_result=$(uecap_receipt_get reload_result); [ -n "$_uecap_receipt_reload_result" ] || _uecap_receipt_reload_result=unknown
    _uecap_receipt_effective=$(uecap_receipt_get effective_state); [ -n "$_uecap_receipt_effective" ] || _uecap_receipt_effective=unknown
    _uecap_receipt_actual_rat=$(uecap_receipt_get actual_rat); [ -n "$_uecap_receipt_actual_rat" ] || _uecap_receipt_actual_rat=unknown
    _uecap_receipt_nr_available=$(uecap_receipt_get nr_available); [ -n "$_uecap_receipt_nr_available" ] || _uecap_receipt_nr_available=unknown
    _uecap_receipt_endc_available=$(uecap_receipt_get endc_available); [ -n "$_uecap_receipt_endc_available" ] || _uecap_receipt_endc_available=unknown
    _uecap_receipt_nr_registered=$(uecap_receipt_get nr_registered); [ -n "$_uecap_receipt_nr_registered" ] || _uecap_receipt_nr_registered=unknown
    _uecap_receipt_nr_band=$(uecap_receipt_get nr_band); [ -n "$_uecap_receipt_nr_band" ] || _uecap_receipt_nr_band=unknown
    _uecap_receipt_nr_arfcn=$(uecap_receipt_get nr_arfcn); [ -n "$_uecap_receipt_nr_arfcn" ] || _uecap_receipt_nr_arfcn=unknown
    _uecap_receipt_nr_range=$(uecap_receipt_get nr_frequency_range); [ -n "$_uecap_receipt_nr_range" ] || _uecap_receipt_nr_range=unknown
    _uecap_receipt_bind_status=$(uecap_receipt_get bind_status); [ -n "$_uecap_receipt_bind_status" ] || _uecap_receipt_bind_status=unknown
    _uecap_receipt_backend=$(uecap_receipt_get backend); [ -n "$_uecap_receipt_backend" ] || _uecap_receipt_backend="${UECAP_BACKEND:-unknown}"
    _uecap_receipt_content_image=$(uecap_receipt_get content_image); [ -n "$_uecap_receipt_content_image" ] || _uecap_receipt_content_image=unknown
    _uecap_receipt_mount_observed=$(uecap_receipt_get mount_observed); [ -n "$_uecap_receipt_mount_observed" ] || _uecap_receipt_mount_observed=unknown
    _uecap_receipt_context_verified=$(uecap_receipt_get context_verified); [ -n "$_uecap_receipt_context_verified" ] || _uecap_receipt_context_verified=unknown
    _uecap_receipt_content_context=$(uecap_receipt_get content_context); [ -n "$_uecap_receipt_content_context" ] || _uecap_receipt_content_context=unknown
    _uecap_receipt_effective_context=$(uecap_receipt_get effective_context); [ -n "$_uecap_receipt_effective_context" ] || _uecap_receipt_effective_context=unknown
    _uecap_receipt_content_hash=$(uecap_receipt_get content_hash); [ -n "$_uecap_receipt_content_hash" ] || _uecap_receipt_content_hash="${UECAP_READBACK_CONTENT_HASH:-unknown}"
    _uecap_receipt_effective_hash=$(uecap_receipt_get effective_hash); [ -n "$_uecap_receipt_effective_hash" ] || _uecap_receipt_effective_hash="${UECAP_READBACK_EFFECTIVE_HASH:-unknown}"
    _uecap_receipt_device=$(uecap_receipt_get device); [ -n "$_uecap_receipt_device" ] || _uecap_receipt_device="${UECAP_DEVICE:-unknown}"
    _uecap_receipt_device_policy=$(uecap_receipt_get device_policy); [ -n "$_uecap_receipt_device_policy" ] || _uecap_receipt_device_policy="${UECAP_DEVICE_POLICY:-unknown}"
    _uecap_receipt_desired=$(uecap_receipt_get desired_profile); [ -n "$_uecap_receipt_desired" ] || _uecap_receipt_desired="${UECAP_DESIRED_PROFILE:-unknown}"
    _uecap_receipt_bound=$(uecap_receipt_get bound_profile); [ -n "$_uecap_receipt_bound" ] || _uecap_receipt_bound="${UECAP_BOUND_PROFILE:-unknown}"
    _uecap_receipt_modem_state=$(uecap_receipt_get modem_load_state); [ -n "$_uecap_receipt_modem_state" ] || _uecap_receipt_modem_state="${UECAP_MODEM_LOAD_STATE:-unknown}"
    _uecap_receipt_loaded_profile=$(uecap_receipt_get modem_loaded_profile); [ -n "$_uecap_receipt_loaded_profile" ] || _uecap_receipt_loaded_profile="${UECAP_MODEM_LOADED_PROFILE:-unknown}"
    _uecap_receipt_radio_state=$(uecap_receipt_get radio_observed_state); [ -n "$_uecap_receipt_radio_state" ] || _uecap_receipt_radio_state="${UECAP_RADIO_OBSERVED_STATE:-UNKNOWN}"
    _uecap_receipt_functional=$(uecap_receipt_get functional_state); [ -n "$_uecap_receipt_functional" ] || _uecap_receipt_functional="${UECAP_FUNCTIONAL_STATE:-unknown}"
    _uecap_receipt_freshness=$(uecap_receipt_get receipt_freshness); [ -n "$_uecap_receipt_freshness" ] || _uecap_receipt_freshness="${UECAP_RECEIPT_FRESHNESS:-unknown}"
    _uecap_receipt_lte_anchor=$(uecap_receipt_get lte_anchor); [ -n "$_uecap_receipt_lte_anchor" ] || _uecap_receipt_lte_anchor=unknown
    _uecap_receipt_nsa_status=$(uecap_receipt_get nsa_status); [ -n "$_uecap_receipt_nsa_status" ] || _uecap_receipt_nsa_status="${UECAP_NSA_STATUS:-not_applicable}"
    _uecap_receipt_nsa_reason=$(uecap_receipt_get nsa_reason); [ -n "$_uecap_receipt_nsa_reason" ] || _uecap_receipt_nsa_reason="${UECAP_NSA_REASON:-no_confirmed_nsa_cell}"

    if ! uecap_is_available; then
        _uecap_status_special_hash=""
        _uecap_status_balanced_hash=""
        _uecap_status_universal_hash=""
        _uecap_status_candidate_hash=""
    fi

    case "$_uecap_receipt_schema" in ''|*[!0-9]*) _uecap_receipt_schema=0 ;; esac
    case "$_uecap_receipt_updated_at" in ''|*[!0-9]*) _uecap_receipt_updated_at=0 ;; esac
    printf '{"device":"%s","device_label":"%s","device_policy":"%s","contract_result":"%s","runtime_policy":"%s","policy":"%s","requested_mode":"%s","manual_mode":"%s","active_mode":"%s","reason":"%s","disabled":%s,"disabled_message":"%s","last_switch":"%s","target_name":"%s","target_hash":"%s","special_hash":"%s","balanced_hash":"%s","universal_hash":"%s","candidate_hash":"%s","payload_state":"%s","payload_source_build":"%s","payload_bytes":%s,"payload_sha256":"%s","backend":"%s","content_image":"%s","content_hash":"%s","effective_hash":"%s","mount_observed":"%s","context_verified":%s,"content_context":"%s","effective_context":"%s","uecap_contract":' \
        "$(uecap_json_escape "${UECAP_DEVICE:-unknown}")" "$(uecap_json_escape "${UECAP_DEVICE_LABEL:-unknown}")" "$(uecap_json_escape "${UECAP_DEVICE_POLICY:-unknown}")" "$(uecap_json_escape "${UECAP_CONTRACT_RESULT:-unknown}")" "$(uecap_json_escape "${UECAP_RUNTIME_POLICY:-disabled}")" \
        "$(uecap_json_escape "$_uecap_status_policy")" "$(uecap_json_escape "$_uecap_status_requested")" "$(uecap_json_escape "$_uecap_status_manual")" "$(uecap_json_escape "$_uecap_status_active")" "$(uecap_json_escape "${_uecap_status_reason:-unknown}")" \
        "$(uecap_is_available && printf false || printf true)" "$(uecap_json_escape "$(uecap_disabled_message)")" "$_uecap_status_last_switch" "$(uecap_json_escape "${UECAP_TARGET_NAME:-unknown}")" \
        "$(uecap_json_escape "${_uecap_status_target_hash:-unknown}")" "$(uecap_json_escape "${_uecap_status_special_hash:-unknown}")" "$(uecap_json_escape "${_uecap_status_balanced_hash:-unknown}")" "$(uecap_json_escape "${_uecap_status_universal_hash:-unknown}")" \
        "$(uecap_json_escape "${_uecap_status_candidate_hash:-unknown}")" "$(uecap_json_escape "$UECAP_PAYLOAD_STATE")" "$(uecap_json_escape "$UECAP_PAYLOAD_BUILD")" "${UECAP_PAYLOAD_BYTES:-0}" "$(uecap_json_escape "$UECAP_PAYLOAD_SHA")" \
        "$(uecap_json_escape "$_uecap_receipt_backend")" "$(uecap_json_escape "$_uecap_receipt_content_image")" "$(uecap_json_escape "$_uecap_receipt_content_hash")" "$(uecap_json_escape "$_uecap_receipt_effective_hash")" "$(uecap_json_escape "$_uecap_receipt_mount_observed")" \
        "$( [ "$_uecap_receipt_context_verified" = true ] && printf true || printf false )" "$(uecap_json_escape "$_uecap_receipt_content_context")" "$(uecap_json_escape "$_uecap_receipt_effective_context")"
    uecap_print_ui_contract_json
    _uecap_reboot_required=false
    [ -f "$MODDIR/.uecap_reboot_required" ] && _uecap_reboot_required=true
    printf ',"reinstall_required":%s,"reboot_required":%s' \
        "$( [ "$UECAP_BACKEND" = metamodule_content ] && printf true || printf false )" \
        "$_uecap_reboot_required"
    printf ',"runtime_receipt":{"schema":%s,"boot_id":"%s","updated_at":"%s","reason":"%s","apply_result":"%s","reload_dispatched":%s,"reload_result":"%s","effective_state":"%s","bind_status":"%s","backend":"%s","content_image":"%s","content_hash":"%s","effective_hash":"%s","mount_observed":"%s","context_verified":%s,"content_context":"%s","effective_context":"%s","device":"%s","device_policy":"%s","desired_profile":"%s","bound_profile":"%s","modem_load_state":"%s","modem_loaded_profile":"%s","radio_observed_state":"%s","functional_state":"%s","receipt_freshness":"%s","actual_rat":"%s","nr_available":"%s","endc_available":"%s","nr_registered":"%s","nr_band":"%s","nr_arfcn":"%s","nr_frequency_range":"%s","lte_anchor":"%s","nsa_status":"%s","nsa_reason":"%s"}}' \
        "$_uecap_receipt_schema" "$(uecap_json_escape "$_uecap_receipt_boot_id")" "$_uecap_receipt_updated_at" \
        "$(uecap_json_escape "$_uecap_receipt_reason")" "$(uecap_json_escape "$_uecap_receipt_apply")" \
        "$_uecap_receipt_reload_dispatched" "$(uecap_json_escape "$_uecap_receipt_reload_result")" \
        "$(uecap_json_escape "$_uecap_receipt_effective")" "$(uecap_json_escape "$_uecap_receipt_bind_status")" \
        "$(uecap_json_escape "$_uecap_receipt_backend")" "$(uecap_json_escape "$_uecap_receipt_content_image")" "$(uecap_json_escape "$_uecap_receipt_content_hash")" "$(uecap_json_escape "$_uecap_receipt_effective_hash")" "$(uecap_json_escape "$_uecap_receipt_mount_observed")" \
        "$( [ "$_uecap_receipt_context_verified" = true ] && printf true || printf false )" "$(uecap_json_escape "$_uecap_receipt_content_context")" "$(uecap_json_escape "$_uecap_receipt_effective_context")" \
        "$(uecap_json_escape "$_uecap_receipt_device")" "$(uecap_json_escape "$_uecap_receipt_device_policy")" \
        "$(uecap_json_escape "$_uecap_receipt_desired")" "$(uecap_json_escape "$_uecap_receipt_bound")" \
        "$(uecap_json_escape "$_uecap_receipt_modem_state")" "$(uecap_json_escape "$_uecap_receipt_loaded_profile")" \
        "$(uecap_json_escape "$_uecap_receipt_radio_state")" "$(uecap_json_escape "$_uecap_receipt_functional")" \
        "$(uecap_json_escape "$_uecap_receipt_freshness")" "$(uecap_json_escape "${UECAP_RADIO_ACTUAL_RAT:-$_uecap_receipt_actual_rat}")" \
        "$(uecap_json_escape "${UECAP_RADIO_NR_AVAILABLE:-$_uecap_receipt_nr_available}")" "$(uecap_json_escape "${UECAP_RADIO_ENDC_AVAILABLE:-$_uecap_receipt_endc_available}")" \
        "$(uecap_json_escape "${UECAP_RADIO_NR_REGISTERED:-$_uecap_receipt_nr_registered}")" "$(uecap_json_escape "${UECAP_RADIO_NR_BAND:-$_uecap_receipt_nr_band}")" \
        "$(uecap_json_escape "${UECAP_RADIO_NR_ARFCN:-$_uecap_receipt_nr_arfcn}")" "$(uecap_json_escape "${UECAP_RADIO_NR_RANGE:-$_uecap_receipt_nr_range}")" \
        "$(uecap_json_escape "${UECAP_RADIO_LTE_ANCHOR:-$_uecap_receipt_lte_anchor}")" \
        "$(uecap_json_escape "${UECAP_NSA_STATUS:-$_uecap_receipt_nsa_status}")" "$(uecap_json_escape "${UECAP_NSA_REASON:-$_uecap_receipt_nsa_reason}")"
}

uecap_main() {
    case "$1" in
        apply)
            _uecap_cli_mode=$(uecap_mode_label "${2:-$(uecap_current_mode)}")
            [ "$_uecap_cli_mode" = "unknown" ] && return 1
            uecap_apply_mode "$_uecap_cli_mode" manual
            ;;
        status)
            uecap_print_status_json
            ;;
        modes)
            printf '%s\n' "$UECAP_MODE_ORDER"
            ;;
        default)
            printf '%s\n' "$UECAP_DEFAULT_MODE"
            ;;
        policy)
            printf '%s\n' "$UECAP_DEVICE_POLICY"
            ;;
        validate)
            for _uecap_cli_validate_mode in $UECAP_MODE_ORDER; do
                [ "$_uecap_cli_validate_mode" != stock ] || continue
                uecap_resolve_source "$_uecap_cli_validate_mode" >/dev/null || return 1
            done
            ;;
        stage)
            uecap_stage_mode "${2:-disabled}"
            ;;
        *)
            return 1
            ;;
    esac
}

uecap_refresh_device_contract >/dev/null 2>&1 || {
    UECAP_DEVICE="unknown"
    UECAP_DEVICE_LABEL="unknown"
    UECAP_DEVICE_POLICY="unknown"
    UECAP_CONTRACT_RESULT="${UECAP_CONTRACT_RESULT:-invalid}"
    UECAP_MODE_ORDER=""
    UECAP_DEFAULT_MODE="disabled"
}
uecap_refresh_runtime_policy

case "${0##*/}" in
    uecap_profile.sh) uecap_main "$@" ;;
esac
