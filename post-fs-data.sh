#!/system/bin/sh

# APatch runs this hook after the metamodule mount hook. Thermal and UECap are
# observation-only here; neither writes a mounted vendor path nor tries to
# repair the current boot.
MODDIR="${PIXEL9PRO_MODDIR:-${MODDIR:-${0%/*}}}"

# Thermal is a plain Hybrid Mount source.  This hook does not lock, promote,
# roll back, or relabel thermal content.  Record only what is
# visible in the current namespace; post-mount performs the final readback.
_thermal_source="$MODDIR/system/vendor/etc/thermal_info_config.json"
_thermal_effective=/vendor/etc/thermal_info_config.json
_thermal_source_hash=none
_thermal_source_context=none
_thermal_source_present=false
_thermal_effective_hash=none
_thermal_effective_context=none
_thermal_config_name=$(getprop vendor.thermal.config 2>/dev/null | tr -d ' \n\r\t')
[ -n "$_thermal_config_name" ] || _thermal_config_name=thermal_info_config.json
[ -f "$_thermal_source" ] && _thermal_source_present=true \
    && _thermal_source_hash=$(sha256sum "$_thermal_source" 2>/dev/null | awk '{print $1}') \
    && _thermal_source_context=$(ls -Zd "$_thermal_source" 2>/dev/null | awk '{print $1}')
[ -f "$_thermal_effective" ] && _thermal_effective_hash=$(sha256sum "$_thermal_effective" 2>/dev/null | awk '{print $1}')
[ -e "$_thermal_effective" ] && _thermal_effective_context=$(ls -Zd "$_thermal_effective" 2>/dev/null | awk '{print $1}')
_thermal_receipt_tmp="$MODDIR/.thermal_runtime_receipt.tmp.$$"
{
    printf 'schema=2\nboot_id=%s\nbackend=%s\nphase=post_fs_data_observed\n' \
        "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \n\r\t')" \
        "${UECAP_BACKEND:-unknown}"
    printf 'policy=%s\nsource_path=%s\nsource_present=%s\n' \
        "$(cat "$MODDIR/.thermal_policy" 2>/dev/null | tr -d ' \n\r\t')" \
        "$_thermal_source" "$_thermal_source_present"
    printf 'source_hash=%s\nsource_context=%s\n' "$_thermal_source_hash" "$_thermal_source_context"
    printf 'effective_path=%s\neffective_hash=%s\neffective_context=%s\n' \
        "$_thermal_effective" "$_thermal_effective_hash" "$_thermal_effective_context"
    printf 'selected_config=%s\n' "$_thermal_config_name"
    printf 'status=post_fs_data_observed\n'
} > "$_thermal_receipt_tmp" 2>/dev/null \
    && mv -f "$_thermal_receipt_tmp" "$MODDIR/.thermal_runtime_receipt" 2>/dev/null \
    || rm -f "$_thermal_receipt_tmp" 2>/dev/null
