#!/system/bin/sh

# Thermal policy contract. There is one mutable payload only:
#   $MODDIR/system/vendor/etc/thermal_info_config.json
# Runtime evidence is kept separately in .thermal_runtime_receipt and never
# controls the desired source or becomes a /vendor write target.

THERMAL_POLICY_DEFAULT=system
THERMAL_SOURCE_CONTEXT=u:object_r:vendor_configs_file:s0
THERMAL_EFFECTIVE_FILE=/vendor/etc/thermal_info_config.json

thermal_policy_init() {
    THERMAL_POLICY_ROOT="$1"
    [ -n "$THERMAL_POLICY_ROOT" ] || return 1
    THERMAL_POLICY_FILE="$THERMAL_POLICY_ROOT/.thermal_policy"
    THERMAL_OFFSET_FILE="$THERMAL_POLICY_ROOT/.thermal_offset"
    THERMAL_SOURCE_FILE="$THERMAL_POLICY_ROOT/system/vendor/etc/thermal_info_config.json"
    THERMAL_OVERLAY_FILE="$THERMAL_SOURCE_FILE"
    THERMAL_RUNTIME_RECEIPT="$THERMAL_POLICY_ROOT/.thermal_runtime_receipt"
    THERMAL_CONFIG_FILE="$THERMAL_POLICY_ROOT/.thermal_config_name"
    THERMAL_TX_ROOT="$THERMAL_POLICY_ROOT/.thermal_tx"
    THERMAL_TX_META="$THERMAL_TX_ROOT/meta"
    THERMAL_TX_SOURCE="$THERMAL_TX_ROOT/source"
}

thermal_policy_selected_config() {
    _tpl_config=$(getprop vendor.thermal.config 2>/dev/null | tr -d ' \n\r\t')
    [ -n "$_tpl_config" ] && printf '%s' "$_tpl_config" || printf '%s' thermal_info_config.json
}

thermal_policy_validate_selected_config() {
    _tpl_config=$(thermal_policy_selected_config)
    case "$_tpl_config" in
        thermal_info_config.json) return 0 ;;
        thermal_info_config_lpm.json)
            [ -r "/vendor/etc/$_tpl_config" ] || return 1
            grep -q 'thermal_info_config.json' "/vendor/etc/$_tpl_config" 2>/dev/null
            ;;
        *) return 1 ;;
    esac
}

thermal_policy_is_valid() {
    case "$1" in system|custom) return 0 ;; *) return 1 ;; esac
}

thermal_policy_read() {
    _tpl_value=$(cat "$THERMAL_POLICY_FILE" 2>/dev/null | tr -d ' \r\n\t')
    thermal_policy_is_valid "$_tpl_value" && printf '%s' "$_tpl_value" || printf '%s' "$THERMAL_POLICY_DEFAULT"
}

thermal_policy_offset_read() {
    _tpl_value=$(cat "$THERMAL_OFFSET_FILE" 2>/dev/null | tr -d ' \r\n\t')
    printf '%s' "$_tpl_value"
}

thermal_policy_snapshot_path() {
    case "$1" in caiman|komodo) ;; *) return 1 ;; esac
    printf '%s/payloads/thermal/%s/stock.json' "$THERMAL_POLICY_ROOT" "$1"
}

thermal_policy_validate_stock() {
    _tpl_source="$1"
    [ -r "$_tpl_source" ] || return 1
    _tpl_validation="${TMPDIR:-/dev/tmp}/pixel9pro_thermal_validate.$$"
    thermal_generate_config "$_tpl_source" "$_tpl_validation" 0 >/dev/null 2>&1
    _tpl_rc=$?
    rm -f "$_tpl_validation" 2>/dev/null
    return "$_tpl_rc"
}

thermal_policy_capture_stock() {
    _tpl_source="$1"
    _tpl_target="$2"
    thermal_policy_validate_stock "$_tpl_source" || return 1
    mkdir -p "${_tpl_target%/*}" 2>/dev/null || return 1
    _tpl_tmp="${_tpl_target}.tmp.$$"
    rm -f "$_tpl_tmp" 2>/dev/null
    cp "$_tpl_source" "$_tpl_tmp" 2>/dev/null \
        && thermal_policy_validate_stock "$_tpl_tmp" \
        && mv "$_tpl_tmp" "$_tpl_target" 2>/dev/null \
        && chmod 600 "$_tpl_target" 2>/dev/null \
        && [ -f "$_tpl_target" ] && return 0
    rm -f "$_tpl_tmp" 2>/dev/null
    return 1
}

thermal_policy_stock_provenance_valid() {
    _tpl_stock="$1"
    _tpl_meta="$_tpl_stock.meta"
    [ -r "$_tpl_meta" ] && [ -r "$_tpl_stock" ] || return 1
    _tpl_fingerprint=$(getprop ro.build.fingerprint 2>/dev/null)
    [ -n "$_tpl_fingerprint" ] || return 1
    [ "$(sed -n 's/^fingerprint=//p' "$_tpl_meta")" = "$_tpl_fingerprint" ] || return 1
    [ "$(sed -n 's/^sha256=//p' "$_tpl_meta")" = "$(sha256sum "$_tpl_stock" 2>/dev/null | awk '{print $1}')" ]
}

thermal_policy_stock_record_provenance() {
    _tpl_stock="$1"
    _tpl_fingerprint=$(getprop ro.build.fingerprint 2>/dev/null)
    _tpl_sha=$(sha256sum "$_tpl_stock" 2>/dev/null | awk '{print $1}')
    [ -n "$_tpl_fingerprint" ] && [ -n "$_tpl_sha" ] || return 1
    _tpl_meta="$_tpl_stock.meta"
    { printf 'fingerprint=%s\n' "$_tpl_fingerprint"; printf 'sha256=%s\n' "$_tpl_sha"; } \
        > "$_tpl_meta.tmp.$$" && chmod 600 "$_tpl_meta.tmp.$$" \
        && mv "$_tpl_meta.tmp.$$" "$_tpl_meta"
}

thermal_policy_prepare_snapshot() {
    _tpl_device="$1"
    _tpl_old_root="$2"
    _tpl_allow_vendor="$3"
    _tpl_target=$(thermal_policy_snapshot_path "$_tpl_device") || return 1
    thermal_policy_stock_provenance_valid "$_tpl_target" \
        && thermal_policy_validate_stock "$_tpl_target" && return 0

    _tpl_legacy_name=thermal_stock.json
    [ "$_tpl_device" = komodo ] && _tpl_legacy_name=thermal_stock_xl.json
    for _tpl_candidate in \
        "$_tpl_old_root/payloads/thermal/$_tpl_device/stock.json" \
        "$_tpl_old_root/system/vendor/etc/$_tpl_legacy_name"; do
        [ -n "$_tpl_old_root" ] && thermal_policy_stock_provenance_valid "$_tpl_candidate" \
            && thermal_policy_capture_stock "$_tpl_candidate" "$_tpl_target" \
            && thermal_policy_stock_record_provenance "$_tpl_target" \
            && return 0
    done
    if [ "$_tpl_allow_vendor" = yes ]; then
        # Never relabel an old custom payload as stock. Missing provenance on
        # an upgrade is a diagnosis condition, not permission to recapture it.
        _tpl_old_disabled=0
        [ -f "$_tpl_old_root/disable" ] && _tpl_old_disabled=1
        { [ ! -e "$_tpl_old_root/system/vendor/etc/thermal_info_config.json" ] \
            || [ "$_tpl_old_disabled" -eq 1 ]; } || return 1
        if [ "$_tpl_old_disabled" -ne 1 ] \
            && [ "$(cat "$_tpl_old_root/.thermal_policy" 2>/dev/null)" = custom ]; then
            return 1
        fi
        if awk '$5 ~ /\/thermal_info_config[.]json$/ { found=1 } END { exit found ? 0 : 1 }' \
            /proc/self/mountinfo 2>/dev/null; then return 1; fi
        thermal_policy_capture_stock /vendor/etc/thermal_info_config.json "$_tpl_target" \
            && thermal_policy_stock_record_provenance "$_tpl_target" \
            && return 0
    fi
    return 1
}

thermal_policy_source_hash() {
    [ -f "$THERMAL_SOURCE_FILE" ] || { printf '%s' none; return 0; }
    sha256sum "$THERMAL_SOURCE_FILE" 2>/dev/null | awk '{print $1}'
}

thermal_policy_effective_hash() {
    [ -f "$THERMAL_EFFECTIVE_FILE" ] || { printf '%s' none; return 0; }
    sha256sum "$THERMAL_EFFECTIVE_FILE" 2>/dev/null | awk '{print $1}'
}

thermal_policy_source_context() {
    [ -e "$THERMAL_SOURCE_FILE" ] || { printf '%s' none; return 0; }
    ls -Zd "$THERMAL_SOURCE_FILE" 2>/dev/null | awk '{print $1}'
}

thermal_policy_effective_context() {
    [ -e "$THERMAL_EFFECTIVE_FILE" ] || { printf '%s' none; return 0; }
    ls -Zd "$THERMAL_EFFECTIVE_FILE" 2>/dev/null | awk '{print $1}'
}

# Read-only SELinux/hash gate. It never chcon and never writes /vendor.
thermal_policy_readback_check() {
    _tpl_policy="$1"
    _tpl_source_hash=$(thermal_policy_source_hash)
    _tpl_effective_hash=$(thermal_policy_effective_hash)
    _tpl_source_context=$(thermal_policy_source_context)
    _tpl_effective_context=$(thermal_policy_effective_context)
    if [ "$_tpl_policy" = system ]; then
        [ "$_tpl_source_hash" = none ] || return 1
        _tpl_device=$(cat "$THERMAL_POLICY_ROOT/.device_variant" 2>/dev/null | tr -d ' \n\r\t')
        _tpl_stock=$(thermal_policy_snapshot_path "$_tpl_device" 2>/dev/null) || return 1
        thermal_policy_stock_provenance_valid "$_tpl_stock" || return 1
        [ "$_tpl_effective_hash" = "$(sha256sum "$_tpl_stock" 2>/dev/null | awk '{print $1}')" ] || return 1
    elif [ "$_tpl_policy" = custom ]; then
        [ "$_tpl_source_hash" != none ] && [ "$_tpl_source_hash" = "$_tpl_effective_hash" ] || return 1
    else
        return 1
    fi
    [ "$_tpl_effective_context" = "$THERMAL_SOURCE_CONTEXT" ] || return 1
    return 0
}

# Labeling is an explicit pre-commit operation for a custom source. If the
# device policy disallows chcon, callers fail closed and remove the source.
thermal_policy_label_source() {
    [ -f "$THERMAL_SOURCE_FILE" ] || return 1
    chcon "$THERMAL_SOURCE_CONTEXT" "$THERMAL_SOURCE_FILE" 2>/dev/null || return 1
    [ "$(thermal_policy_source_context)" = "$THERMAL_SOURCE_CONTEXT" ]
}

thermal_policy_remove_overlay() {
    rm -f "$THERMAL_SOURCE_FILE" 2>/dev/null || return 1
    rmdir "${THERMAL_SOURCE_FILE%/*}" 2>/dev/null || true
    rmdir "${THERMAL_SOURCE_FILE%/*/*}" 2>/dev/null || true
    return 0
}

# Remove only legacy thermal and UECap transaction files from pre-redesign
# installs. The current backend never recreates this state.
thermal_policy_cleanup_legacy_state() {
    _tpl_root="${1:-$THERMAL_POLICY_ROOT}"
    _tpl_slot_root="${PIXEL9PRO_SLOT_ROOT:-/data/adb/pixel9pro_control/slots}"
    for _tpl_component in thermal uecap; do
        _tpl_slots="$_tpl_slot_root/$_tpl_component"
        rm -f "$_tpl_slots/pending" "$_tpl_slots/promoted" \
            "$_tpl_slots/rollback_pending" "$_tpl_slots/previous_state" \
            "$_tpl_slots/last-good" "$_tpl_slots/active" 2>/dev/null || true
        rm -f "$_tpl_slots/slot-a/manifest" "$_tpl_slots/slot-a/payload" \
            "$_tpl_slots/slot-b/manifest" "$_tpl_slots/slot-b/payload" 2>/dev/null || true
        rmdir "$_tpl_slots/slot-a" "$_tpl_slots/slot-b" "$_tpl_slots" 2>/dev/null || true
    done
    if [ ! -s "$_tpl_slot_root.lock/pid" ]; then
        rm -f "$_tpl_slot_root.lock/pid" "$_tpl_slot_root.lock/start_ticks" 2>/dev/null || true
        rmdir "$_tpl_slot_root.lock" 2>/dev/null || true
    fi
    rm -f "$_tpl_root/.thermal_tx/meta" "$_tpl_root/.thermal_tx/source" 2>/dev/null || true
    rmdir "$_tpl_root/.thermal_tx" 2>/dev/null || true
    rm -f "$_tpl_root/.thermal_pending_id" "$_tpl_root/.thermal_previous_state" 2>/dev/null || true
}

# Single reversible desired-state journal for the WebUI. It never represents a
# mount layer: it only keeps the previous regular source until reboot or an
# explicit cancel request restores it.
thermal_policy_transaction_pending() {
    [ -s "$THERMAL_TX_META" ]
}

thermal_policy_transaction_value() {
    sed -n "s/^$1=//p" "$THERMAL_TX_META" 2>/dev/null | head -n 1 | tr -d '\r'
}

thermal_policy_transaction_clear() {
    rm -f "$THERMAL_TX_META" "$THERMAL_TX_SOURCE" 2>/dev/null || return 1
    rmdir "$THERMAL_TX_ROOT" 2>/dev/null || true
    [ ! -e "$THERMAL_TX_META" ] && [ ! -e "$THERMAL_TX_SOURCE" ]
}
