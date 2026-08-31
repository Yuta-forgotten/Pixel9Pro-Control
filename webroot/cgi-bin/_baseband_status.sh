#!/system/bin/sh

# Shared read-only view of pixel9pro_baseband_trial.
#
# The module directory is only the installation surface.  Runtime validity is
# read from the standalone module's .runtime_status receipt, which is written
# after source/content/effective paths and the current boot have been checked.
# Control never mounts, copies, or repairs the standalone module here.

BASEBAND_STATUS_MODULE_ID="${BASEBAND_STATUS_MODULE_ID:-pixel9pro_baseband_trial}"
BASEBAND_STATUS_ACTIVE_ROOT="${BASEBAND_STATUS_ACTIVE_ROOT:-/data/adb/modules}"
BASEBAND_STATUS_UPDATE_ROOT="${BASEBAND_STATUS_UPDATE_ROOT:-/data/adb/modules_update}"
BASEBAND_STATUS_DIR=""
BASEBAND_STATUS_MODULE_DIR_STATE="missing"
BASEBAND_STATUS_SOURCE=""
BASEBAND_STATUS_MODULE_STATE="missing"
BASEBAND_STATUS_ENABLED=false
BASEBAND_STATUS_PENDING_UPDATE_DIR=""
BASEBAND_STATUS_PENDING_UPDATE_PRESENT=false
BASEBAND_STATUS_PROP_VERSION=""
BASEBAND_STATUS_PROP_VERSION_CODE=""
BASEBAND_STATUS_PROP_DESCRIPTION=""
BASEBAND_STATUS_RECEIPT=""
BASEBAND_STATUS_RUNTIME_VERIFIED=false

baseband_status_trim() {
    tr -d ' \r\n\t'
}

baseband_status_get() {
    _bb_status_file="$1"
    _bb_status_key="$2"
    _bb_status_default="${3:-}"
    _bb_status_value=""
    if [ -f "$_bb_status_file" ]; then
        _bb_status_value=$(sed -n "s/^${_bb_status_key}=//p" "$_bb_status_file" 2>/dev/null | head -n 1)
    fi
    [ -n "$_bb_status_value" ] && printf '%s' "$_bb_status_value" || printf '%s' "$_bb_status_default"
}

baseband_status_bool() {
    case "$1" in
        1|yes|true|on|enabled|PASS) printf 'true' ;;
        *) printf 'false' ;;
    esac
}

baseband_status_json_string() {
    json_escape "${1:-}"
}

baseband_status_select_module() {
    BASEBAND_STATUS_DIR=""
    BASEBAND_STATUS_MODULE_DIR_STATE="missing"
    BASEBAND_STATUS_SOURCE=""
    BASEBAND_STATUS_MODULE_STATE="missing"
    BASEBAND_STATUS_ENABLED=false
    BASEBAND_STATUS_PENDING_UPDATE_DIR=""
    BASEBAND_STATUS_PENDING_UPDATE_PRESENT=false
    BASEBAND_STATUS_PROP_VERSION=""
    BASEBAND_STATUS_PROP_VERSION_CODE=""
    BASEBAND_STATUS_PROP_DESCRIPTION=""
    BASEBAND_STATUS_RECEIPT=""
    BASEBAND_STATUS_RUNTIME_VERIFIED=false
    _bb_status_active="$BASEBAND_STATUS_ACTIVE_ROOT/$BASEBAND_STATUS_MODULE_ID"
    _bb_status_update="$BASEBAND_STATUS_UPDATE_ROOT/$BASEBAND_STATUS_MODULE_ID"
    if [ -d "$_bb_status_update" ]; then
        BASEBAND_STATUS_PENDING_UPDATE_DIR="$_bb_status_update"
        BASEBAND_STATUS_PENDING_UPDATE_PRESENT=true
    fi
    # The active module is the current boot source of truth.  A pending update
    # is reported separately and must not replace the active module in status.
    if [ -d "$_bb_status_active" ]; then
        BASEBAND_STATUS_DIR="$_bb_status_active"
        BASEBAND_STATUS_MODULE_DIR_STATE=active
        BASEBAND_STATUS_SOURCE=active
    elif [ -d "$_bb_status_update" ]; then
        BASEBAND_STATUS_DIR="$_bb_status_update"
        BASEBAND_STATUS_MODULE_DIR_STATE=pending_update
        BASEBAND_STATUS_SOURCE=pending_update
    fi
    [ -n "$BASEBAND_STATUS_DIR" ] || return 1

    if [ -e "$BASEBAND_STATUS_DIR/remove" ]; then
        BASEBAND_STATUS_MODULE_STATE=remove_pending
        BASEBAND_STATUS_ENABLED=false
    elif [ -e "$BASEBAND_STATUS_DIR/disable" ]; then
        BASEBAND_STATUS_MODULE_STATE=disabled
        BASEBAND_STATUS_ENABLED=false
    else
        BASEBAND_STATUS_MODULE_STATE=enabled
        BASEBAND_STATUS_ENABLED=true
    fi

    BASEBAND_STATUS_PROP_VERSION=$(grep '^version=' "$BASEBAND_STATUS_DIR/module.prop" 2>/dev/null \
        | cut -d= -f2- | tr -d '\r\n"\\')
    BASEBAND_STATUS_PROP_VERSION_CODE=$(grep '^versionCode=' "$BASEBAND_STATUS_DIR/module.prop" 2>/dev/null \
        | cut -d= -f2- | tr -d '\r\n"\\')
    BASEBAND_STATUS_PROP_DESCRIPTION=$(grep '^description=' "$BASEBAND_STATUS_DIR/module.prop" 2>/dev/null \
        | cut -d= -f2- | tr -d '\r\n"\\')
    BASEBAND_STATUS_RECEIPT="$BASEBAND_STATUS_DIR/.runtime_status"
    return 0
}

baseband_status_emit_json() {
    baseband_status_select_module >/dev/null 2>&1 || {
        BASEBAND_STATUS_RUNTIME_VERIFIED=false
        printf '{"installed":false,"enabled":false,"runtime_verified":false,"module_dir":"","module_dir_state":"missing","module_state":"missing","source":"none","root_impl":"unknown","version":"","version_code":"","description":"","runtime_status":"UNVERIFIED","status_schema":0,"mount_observed":"unknown","effective_overlay_verified":"no","source_contract_verified":"no","content_image_verified":"unknown","effective_contract_verified":"no","effective_extra_files_allowed":"yes","migration_state":"missing","source_path":"","effective_path":"","content_image":"missing","source_hash":"unknown","source_contract_hash":"unknown","effective_hash":"unknown","effective_contract_hash":"unknown","content_image_hash":"unknown","content_contract_hash":"unknown","source_tree_hash":"unknown","content_tree_hash":"unknown","clean_reinstall_required":false,"pending_update":false,"pending_update_dir":"","runtime_receipt_freshness":"missing","prior_receipt_freshness":"missing","current_runtime_check_freshness":"missing","boot_id":"unknown","errors":"module_missing","carrier_settings":{"installed":false,"count":0,"carrier_list_sha256":"missing"},"mcfg":{"installed":false,"count":0},"props":{"volte_avail_ovr":"","wfc_avail_ovr":"","vt_avail_ovr":"","apns_conf_sha256":"missing"}}'
        return 0
    }

    _bb_status_has_receipt=false
    [ -f "$BASEBAND_STATUS_RECEIPT" ] && _bb_status_has_receipt=true
    _bb_status_receipt_kind=file
    [ -d "$BASEBAND_STATUS_RECEIPT" ] && _bb_status_receipt_kind=directory

    _bb_status_runtime_status=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" status missing)
    _bb_status_schema=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" schema 0)
    case "$_bb_status_schema" in ''|*[!0-9]*) _bb_status_schema=0 ;; esac
    _bb_status_root_impl=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" root_impl unknown)
    _bb_status_runtime_freshness=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" runtime_receipt_freshness missing)
    _bb_status_prior_freshness=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" prior_receipt_freshness missing)
    _bb_status_current_freshness=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" current_runtime_check_freshness missing)
    _bb_status_clean=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" clean_reinstall_required no)
    _bb_status_errors=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" errors none)
    if [ "$_bb_status_has_receipt" != true ]; then
        _bb_status_runtime_status=UNVERIFIED
        _bb_status_runtime_freshness=missing
        _bb_status_prior_freshness=missing
        _bb_status_current_freshness=missing
        _bb_status_clean=yes
        case "$_bb_status_receipt_kind" in
            directory) _bb_status_errors=status_receipt_is_directory ;;
            *) _bb_status_errors=runtime_receipt_missing ;;
        esac
    fi
    [ "$BASEBAND_STATUS_ENABLED" = true ] || {
        _bb_status_runtime_status=DISABLED
        _bb_status_clean=no
    }
    if [ "$BASEBAND_STATUS_SOURCE" = pending_update ] && [ "$BASEBAND_STATUS_ENABLED" = true ]; then
        _bb_status_runtime_status=PENDING_UPDATE
        _bb_status_clean=no
    fi
    if [ "$_bb_status_has_receipt" = true ] && [ "$_bb_status_schema" -ne 3 ] 2>/dev/null; then
        _bb_status_runtime_status=LEGACY_RECEIPT
        _bb_status_clean=yes
        if [ -z "$_bb_status_errors" ] || [ "$_bb_status_errors" = none ]; then
            _bb_status_errors=legacy_receipt_schema
        else
            _bb_status_errors="$_bb_status_errors,legacy_receipt_schema"
        fi
    fi

    _bb_status_mount=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" mount_observed unknown)
    _bb_status_effective=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" effective_overlay_verified no)
    _bb_status_source_verified=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" source_contract_verified no)
    _bb_status_content_verified=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" content_image_verified unknown)
    _bb_status_effective_verified=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" effective_contract_verified no)
    _bb_status_extra_allowed=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" effective_extra_files_allowed yes)
    _bb_status_migration=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" migration_state unknown)
    _bb_status_boot=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" boot_id unknown)
    _bb_status_content_image=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" content_image missing)
    _bb_status_source_path=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" source_path "$BASEBAND_STATUS_DIR/system")
    _bb_status_effective_path=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" effective_path /product,/vendor)
    _bb_status_source_hash=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" source_hash unknown)
    _bb_status_source_contract_hash=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" source_contract_hash "$_bb_status_source_hash")
    _bb_status_effective_hash=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" effective_hash unknown)
    _bb_status_effective_contract_hash=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" effective_contract_hash "$_bb_status_effective_hash")
    _bb_status_content_hash=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" content_image_hash unknown)
    _bb_status_content_contract_hash=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" content_contract_hash unknown)
    _bb_status_source_tree_hash=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" source_tree_hash unknown)
    _bb_status_content_tree_hash=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" content_tree_hash unknown)
    _bb_status_carrier_count=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" carrier_settings_files 0)
    _bb_status_mcfg_count=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" china_mcfg_files 0)
    _bb_status_carrier_hash=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" carrier_list_sha256 missing)
    _bb_status_apn_hash=$(baseband_status_get "$BASEBAND_STATUS_RECEIPT" apns_conf_sha256 missing)
    case "$_bb_status_carrier_count" in ''|*[!0-9]*) _bb_status_carrier_count=0 ;; esac
    case "$_bb_status_mcfg_count" in ''|*[!0-9]*) _bb_status_mcfg_count=0 ;; esac

    _bb_status_volte=$(getprop persist.dbg.volte_avail_ovr 2>/dev/null | baseband_status_trim)
    _bb_status_wfc=$(getprop persist.dbg.wfc_avail_ovr 2>/dev/null | baseband_status_trim)
    _bb_status_vt=$(getprop persist.dbg.vt_avail_ovr 2>/dev/null | baseband_status_trim)
    _bb_status_carrier_installed=false
    [ "$_bb_status_carrier_count" -gt 0 ] 2>/dev/null && _bb_status_carrier_installed=true
    _bb_status_mcfg_installed=false
    [ "$_bb_status_mcfg_count" -gt 0 ] 2>/dev/null && _bb_status_mcfg_installed=true
    _bb_status_runtime_verified=false
    if [ "$BASEBAND_STATUS_SOURCE" = active ] \
        && [ "$BASEBAND_STATUS_ENABLED" = true ] \
        && [ "$_bb_status_runtime_status" = PASS ] \
        && [ "$_bb_status_effective" = yes ] \
        && [ "$_bb_status_source_verified" = yes ] \
        && [ "$_bb_status_effective_verified" = yes ] \
        && { [ "$_bb_status_content_verified" = yes ] || [ "$_bb_status_content_verified" = not_required_magisk ]; } \
        && [ "$_bb_status_current_freshness" = current_check ] \
        && [ "$_bb_status_schema" -eq 3 ] 2>/dev/null; then
        _bb_status_runtime_verified=true
    fi
    BASEBAND_STATUS_RUNTIME_VERIFIED=$_bb_status_runtime_verified

    printf '{"installed":true,"enabled":%s,"runtime_verified":%s,"module_dir":"%s","module_dir_state":"%s","module_state":"%s","source":"%s","root_impl":"%s","version":"%s","version_code":"%s","description":"%s","runtime_status":"%s","status_schema":%s,"mount_observed":"%s","effective_overlay_verified":"%s","source_contract_verified":"%s","content_image_verified":"%s","effective_contract_verified":"%s","effective_extra_files_allowed":"%s","migration_state":"%s","source_path":"%s","effective_path":"%s","content_image":"%s","source_hash":"%s","source_contract_hash":"%s","effective_hash":"%s","effective_contract_hash":"%s","content_image_hash":"%s","content_contract_hash":"%s","source_tree_hash":"%s","content_tree_hash":"%s","clean_reinstall_required":%s,"pending_update":%s,"pending_update_dir":"%s","runtime_receipt_freshness":"%s","prior_receipt_freshness":"%s","current_runtime_check_freshness":"%s","boot_id":"%s","errors":"%s","carrier_settings":{"installed":%s,"count":%s,"carrier_list_sha256":"%s"},"mcfg":{"installed":%s,"count":%s},"props":{"volte_avail_ovr":"%s","wfc_avail_ovr":"%s","vt_avail_ovr":"%s","apns_conf_sha256":"%s"}}' \
        "$(baseband_status_bool "$BASEBAND_STATUS_ENABLED")" \
        "$_bb_status_runtime_verified" \
        "$(baseband_status_json_string "$BASEBAND_STATUS_DIR")" \
        "$(baseband_status_json_string "$BASEBAND_STATUS_MODULE_DIR_STATE")" \
        "$(baseband_status_json_string "$BASEBAND_STATUS_MODULE_STATE")" \
        "$(baseband_status_json_string "$BASEBAND_STATUS_SOURCE")" \
        "$(baseband_status_json_string "$_bb_status_root_impl")" \
        "$(baseband_status_json_string "$BASEBAND_STATUS_PROP_VERSION")" \
        "$(baseband_status_json_string "$BASEBAND_STATUS_PROP_VERSION_CODE")" \
        "$(baseband_status_json_string "$BASEBAND_STATUS_PROP_DESCRIPTION")" \
        "$(baseband_status_json_string "$_bb_status_runtime_status")" \
        "$_bb_status_schema" \
        "$(baseband_status_json_string "$_bb_status_mount")" \
        "$(baseband_status_json_string "$_bb_status_effective")" \
        "$(baseband_status_json_string "$_bb_status_source_verified")" \
        "$(baseband_status_json_string "$_bb_status_content_verified")" \
        "$(baseband_status_json_string "$_bb_status_effective_verified")" \
        "$(baseband_status_json_string "$_bb_status_extra_allowed")" \
        "$(baseband_status_json_string "$_bb_status_migration")" \
        "$(baseband_status_json_string "$_bb_status_source_path")" \
        "$(baseband_status_json_string "$_bb_status_effective_path")" \
        "$(baseband_status_json_string "$_bb_status_content_image")" \
        "$(baseband_status_json_string "$_bb_status_source_hash")" \
        "$(baseband_status_json_string "$_bb_status_source_contract_hash")" \
        "$(baseband_status_json_string "$_bb_status_effective_hash")" \
        "$(baseband_status_json_string "$_bb_status_effective_contract_hash")" \
        "$(baseband_status_json_string "$_bb_status_content_hash")" \
        "$(baseband_status_json_string "$_bb_status_content_contract_hash")" \
        "$(baseband_status_json_string "$_bb_status_source_tree_hash")" \
        "$(baseband_status_json_string "$_bb_status_content_tree_hash")" \
        "$(baseband_status_bool "$_bb_status_clean")" \
        "$BASEBAND_STATUS_PENDING_UPDATE_PRESENT" \
        "$(baseband_status_json_string "$BASEBAND_STATUS_PENDING_UPDATE_DIR")" \
        "$(baseband_status_json_string "$_bb_status_runtime_freshness")" \
        "$(baseband_status_json_string "$_bb_status_prior_freshness")" \
        "$(baseband_status_json_string "$_bb_status_current_freshness")" \
        "$(baseband_status_json_string "$_bb_status_boot")" \
        "$(baseband_status_json_string "$_bb_status_errors")" \
        "$_bb_status_carrier_installed" "$_bb_status_carrier_count" \
        "$(baseband_status_json_string "$_bb_status_carrier_hash")" \
        "$_bb_status_mcfg_installed" "$_bb_status_mcfg_count" \
        "$(baseband_status_json_string "$_bb_status_volte")" \
        "$(baseband_status_json_string "$_bb_status_wfc")" \
        "$(baseband_status_json_string "$_bb_status_vt")" \
        "$(baseband_status_json_string "$_bb_status_apn_hash")"
}
