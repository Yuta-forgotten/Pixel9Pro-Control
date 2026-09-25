#!/system/bin/sh
# GET returns current VM/ZRAM state and the shared profile contract. POST
# applies optimized, stock, or validated custom VM parameters immediately.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback

SWAP_MODE_FILE="$MODDIR/.swap_mode"
SWAP_CUSTOM_FILE="$MODDIR/.swap_custom"
VM_FEATURE_FILE="$MODDIR/.feature_vm"
VM_PROFILE_LIB="$MODDIR/scripts/vm_profile_lib.sh"

[ -r "$VM_PROFILE_LIB" ] && . "$VM_PROFILE_LIB" \
    || json_error '500 Internal Server Error' 'VM profile contract not found'

json_num_field() {
    printf '%s' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p"
}

persist_value() {
    cgi_atomic_write "$1" "$2"
}

restore_vm_state() {
    _vm_restore_failed=0
    set -- $_old_vm_params
    [ "$#" -eq 4 ] \
        && vm_write_params_raw "$1" "$2" "$3" "$4" >/dev/null 2>&1 \
        && vm_params_match "$1" "$2" "$3" "$4" \
        || _vm_restore_failed=1
    cgi_restore_file "$SWAP_MODE_FILE" "$_old_mode_existed" "$_old_mode" >/dev/null 2>&1 \
        || _vm_restore_failed=1
    cgi_restore_file "$SWAP_CUSTOM_FILE" "$_old_custom_existed" "$_old_custom" >/dev/null 2>&1 \
        || _vm_restore_failed=1
    cgi_restore_file "$VM_FEATURE_FILE" "$_old_feature_existed" "$_old_feature" >/dev/null 2>&1 \
        || _vm_restore_failed=1
    [ "$_vm_restore_failed" -eq 0 ]
}

restore_vm_policy_state() {
    _vm_policy_restore_failed=0
    cgi_restore_file "$SWAP_MODE_FILE" "$_old_mode_existed" "$_old_mode" >/dev/null 2>&1 \
        || _vm_policy_restore_failed=1
    cgi_restore_file "$VM_FEATURE_FILE" "$_old_feature_existed" "$_old_feature" >/dev/null 2>&1 \
        || _vm_policy_restore_failed=1
    [ "$_vm_policy_restore_failed" -eq 0 ]
}

vm_write_error() {
    if restore_vm_state; then
        json_error '500 Internal Server Error' 'failed to write VM params; previous state restored'
    fi
    json_error '500 Internal Server Error' 'failed to write VM params and rollback was incomplete'
}

emit_state() {
    json_headers
    sw=$(cat /proc/sys/vm/swappiness 2>/dev/null)
    mfk=$(cat /proc/sys/vm/min_free_kbytes 2>/dev/null)
    wsf=$(cat /proc/sys/vm/watermark_scale_factor 2>/dev/null)
    vcp=$(cat /proc/sys/vm/vfs_cache_pressure 2>/dev/null)
    algo=$(cat /sys/block/zram0/comp_algorithm 2>/dev/null | sed 's/.*\[\(.*\)\].*/\1/')
    disksize=$(cat /sys/block/zram0/disksize 2>/dev/null)
    swap_kb=$(awk '$1 ~ /(^|\/)zram0$/ { print $3; found=1 } END { if (!found) print 0 }' /proc/swaps 2>/dev/null | tail -1)
    swap_total_kb=$(awk '/^SwapTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null)
    [ "${swap_kb:-0}" -gt 0 ] 2>/dev/null && zram_active=true || zram_active=false
    mmd_owned=false
    vm_zram_mmd_ready && mmd_owned=true
    target_property="$VM_ZRAM_SIZE_PROPERTY"
    if [ "$mmd_owned" = true ]; then
        target_property="$VM_MMD_ZRAM_SIZE_PROPERTY"
    fi
    target_value=$(getprop "$target_property" 2>/dev/null | tr -d ' \n\r\t')
    [ -n "$target_value" ] || target_value=$(getprop "$VM_ZRAM_SIZE_PROPERTY" 2>/dev/null | tr -d ' \n\r\t')
    [ -n "$target_value" ] || target_value=50%
    target_size_bytes=$(vm_zram_size_to_bytes "$target_value")

    # ZRAM mm_stat: orig compr mem_used ...
    mm=$(cat /sys/block/zram0/mm_stat 2>/dev/null)
    orig=$(echo "$mm" | awk '{print $1}')
    compr=$(echo "$mm" | awk '{print $2}')
    mem_used=$(echo "$mm" | awk '{print $3}')

    # 原厂 ZRAM 大小 = 50% RAM (fstab.zram.50p), 用 awk 避免 32 位溢出
    stock_zram_bytes=$(awk '/MemTotal/{printf "%.0f", $2 * 512}' /proc/meminfo 2>/dev/null)

    mode=$(vm_detect_mode)
    feature_vm=$(cat "$VM_FEATURE_FILE" 2>/dev/null | tr -d ' \r\n\t')
    case "$feature_vm" in system|optimized|disabled) ;; *) feature_vm=system ;; esac
    contract=$(vm_contract_json)

    printf '{"swappiness":%s,"min_free_kbytes":%s,"watermark_scale_factor":%s,"vfs_cache_pressure":%s,"zram_algo":"%s","zram_disksize":%s,"zram_active":%s,"zram_swap_kb":%s,"swap_total_kb":%s,"zram_owner":"%s","zram_target_supported":%s,"zram_size_property":"%s","zram_size_requested":"%s","zram_target_current_bytes":%s,"stock_zram_size":%s,"zram_orig_bytes":%s,"zram_compr_bytes":%s,"zram_mem_used_bytes":%s,"mode":"%s","feature_vm":"%s",%s}' \
        "${sw:-0}" "${mfk:-0}" "${wsf:-0}" "${vcp:-0}" "$(json_escape "${algo:-unknown}")" \
        "${disksize:-0}" "$zram_active" "${swap_kb:-0}" "${swap_total_kb:-0}" "$([ "$mmd_owned" = true ] && echo mmd || echo module)" "$([ "$mmd_owned" = true ] && echo false || echo true)" "$target_property" "$target_value" "$target_size_bytes" "${stock_zram_bytes:-0}" \
        "${orig:-0}" "${compr:-0}" "${mem_used:-0}" "$mode" "$feature_vm" "$contract"
}

if [ "$REQUEST_METHOD" = "POST" ]; then
    require_json_post
    require_token
    acquire_lock "swap"
    read_json_body 512
    body="$JSON_BODY"
    mode=$(printf '%s' "$body" | sed 's/.*"mode"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/')
    _old_vm_params=$(vm_current_params)
    _old_mode_existed=0
    _old_custom_existed=0
    _old_feature_existed=0
    [ -e "$SWAP_MODE_FILE" ] && _old_mode_existed=1
    [ -e "$SWAP_CUSTOM_FILE" ] && _old_custom_existed=1
    [ -e "$VM_FEATURE_FILE" ] && _old_feature_existed=1
    _old_mode=$(cat "$SWAP_MODE_FILE" 2>/dev/null)
    _old_custom=$(cat "$SWAP_CUSTOM_FILE" 2>/dev/null)
    _old_feature=$(cat "$VM_FEATURE_FILE" 2>/dev/null)
    case "$mode" in
        optimized)
            set -- $(vm_profile_params optimized)
            if persist_value "$VM_FEATURE_FILE" optimized \
                && persist_value "$SWAP_MODE_FILE" optimized \
                && vm_write_params "$1" "$2" "$3" "$4"; then
                [ "$AUDIT_LOG_AVAILABLE" -eq 1 ] && audit_log_event vm policy success VM_OPTIMIZED 0 >/dev/null 2>&1 || true
                emit_state
            else
                vm_write_error
            fi
            ;;
        stock)
            set -- $(vm_profile_params stock)
            if persist_value "$VM_FEATURE_FILE" system \
                && persist_value "$SWAP_MODE_FILE" stock \
                && vm_write_params "$1" "$2" "$3" "$4"; then
                [ "$AUDIT_LOG_AVAILABLE" -eq 1 ] && audit_log_event vm policy success VM_SYSTEM_NO_WRITE 0 >/dev/null 2>&1 || true
                emit_state
            else
                restore_vm_state >/dev/null 2>&1 || true
                json_error '500 Internal Server Error' 'failed to restore system VM params; previous state restored'
            fi
            ;;
        custom)
            sw=$(json_num_field "$body" swappiness)
            mfk=$(json_num_field "$body" min_free_kbytes)
            wsf=$(json_num_field "$body" watermark_scale_factor)
            vcp=$(json_num_field "$body" vfs_cache_pressure)
            if ! vm_is_uint_range "$sw" "$VM_SWAPPINESS_MIN" "$VM_SWAPPINESS_MAX"; then
                json_error '400 Bad Request' 'invalid swappiness'
            elif ! vm_is_uint_range "$mfk" "$VM_MIN_FREE_KBYTES_MIN" "$VM_MIN_FREE_KBYTES_MAX"; then
                json_error '400 Bad Request' 'invalid min_free_kbytes'
            elif ! vm_is_uint_range "$wsf" "$VM_WATERMARK_SCALE_MIN" "$VM_WATERMARK_SCALE_MAX"; then
                json_error '400 Bad Request' 'invalid watermark_scale_factor'
            elif ! vm_is_uint_range "$vcp" "$VM_VFS_CACHE_PRESSURE_MIN" "$VM_VFS_CACHE_PRESSURE_MAX"; then
                json_error '400 Bad Request' 'invalid vfs_cache_pressure'
            else
                [ ! -d "$SWAP_CUSTOM_FILE" ] \
                    || json_error '500 Internal Server Error' 'custom VM state path is not a file'
                _custom_tmp="${SWAP_CUSTOM_FILE}.tmp.$$"
                if {
                        printf 'swappiness=%s\n' "$sw"
                        printf 'min_free_kbytes=%s\n' "$mfk"
                        printf 'watermark_scale_factor=%s\n' "$wsf"
                        printf 'vfs_cache_pressure=%s\n' "$vcp"
                    } > "$_custom_tmp" 2>/dev/null \
                    && mv "$_custom_tmp" "$SWAP_CUSTOM_FILE" 2>/dev/null \
                    && [ -f "$SWAP_CUSTOM_FILE" ] \
                    && persist_value "$VM_FEATURE_FILE" optimized \
                    && persist_value "$SWAP_MODE_FILE" custom \
                    && vm_write_params "$sw" "$mfk" "$wsf" "$vcp"; then
                    [ "$AUDIT_LOG_AVAILABLE" -eq 1 ] && audit_log_event vm policy success VM_CUSTOM 0 >/dev/null 2>&1 || true
                    emit_state
                else
                    rm -f "$_custom_tmp" 2>/dev/null
                    vm_write_error
                fi
            fi
            ;;
        disabled)
            set -- $(vm_profile_params stock)
            if persist_value "$VM_FEATURE_FILE" disabled \
                && persist_value "$SWAP_MODE_FILE" disabled \
                && vm_write_params "$1" "$2" "$3" "$4"; then
                [ "$AUDIT_LOG_AVAILABLE" -eq 1 ] && audit_log_event vm policy success VM_DISABLED_NO_WRITE 0 >/dev/null 2>&1 || true
                emit_state
            else
                restore_vm_state >/dev/null 2>&1 || true
                json_error '500 Internal Server Error' 'failed to restore VM params while disabling module policy'
            fi
            ;;
        zram_size)
            [ "$(cat "$VM_FEATURE_FILE" 2>/dev/null | tr -d ' \r\n\t')" = optimized ] \
                || json_error '409 Conflict' 'VM optimization is not enabled'
            _zram_requested=$(printf '%s' "$body" | sed -n 's/.*"size_bytes"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9][0-9]*%\{0,1\}\)"\{0,1\}.*/\1/p')
            vm_zram_size_is_valid "$_zram_requested" \
                || json_error '400 Bad Request' 'invalid zram size_bytes (1GiB..16GiB or percent)'
            if ! vm_zram_mmd_ready; then
                json_error '409 Conflict' 'mmd owner is not ready; zram size change requires reboot'
            fi
            _zram_property="$VM_MMD_ZRAM_SIZE_PROPERTY"
            if ! setprop "$VM_MMD_ZRAM_SIZE_PROPERTY" "$_zram_requested" 2>/dev/null \
                || [ "$(getprop "$VM_MMD_ZRAM_SIZE_PROPERTY" 2>/dev/null | tr -d ' \n\r\t')" != "$_zram_requested" ]; then
                _zram_property="$VM_ZRAM_SIZE_PROPERTY"
                setprop "$VM_ZRAM_SIZE_PROPERTY" "$_zram_requested" 2>/dev/null \
                    && [ "$(getprop "$VM_ZRAM_SIZE_PROPERTY" 2>/dev/null | tr -d ' \n\r\t')" = "$_zram_requested" ] \
                    || json_error '409 Conflict' 'mmd zram size property is not writable on this build'
            fi
            _zram_mode=pending_reboot
            if ! vm_zram_is_active; then
                vm_mmd_setup_zram >/dev/null 2>&1 || true
                sleep 1
                _zram_requested_bytes=$(vm_zram_size_to_bytes "$_zram_requested")
                [ "$(vm_zram_read_disksize)" = "$_zram_requested_bytes" ] \
                    && _zram_mode=applied_online
            fi
            json_headers
            [ "$AUDIT_LOG_AVAILABLE" -eq 1 ] && audit_log_event vm zram success ZRAM_REBOOT_REQUEST 0 >/dev/null 2>&1 || true
            printf '{"ok":true,"mode":"%s","zram_size_property":"%s","zram_size_requested":"%s","message":"%s"}\n' \
                "$_zram_mode" "$_zram_property" "$_zram_requested" \
                "$( [ "$_zram_mode" = applied_online ] && printf 'mmd 已在线应用容量' || printf '当前 swap 正在使用，重启后由 mmd 应用' )"
            ;;
        *)
            json_error '400 Bad Request' 'invalid mode'
            ;;
    esac
elif [ "$REQUEST_METHOD" = "GET" ]; then
    emit_state
else
    json_error '405 Method Not Allowed' 'GET or POST only'
fi
