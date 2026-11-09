#!/system/bin/sh
# Memory API: observation, one-boot operations and explicit boot preferences.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
require_loopback
. "$MODDIR/scripts/memory_lib.sh" \
    || json_error '500 Internal Server Error' 'memory libraries unavailable'

parse_memory_fields() {
    local key value type tab row rest
    tab=$(printf '\t')
    MEMORY_PRESENT='|'; REQUEST_FIELD_COUNT=0
    while IFS= read -r row || [ -n "$row" ]; do
        [ -n "$row" ] || continue
        key=${row%%"$tab"*}; rest=${row#*"$tab"}
        value=${rest%"$tab"*}; type=${rest##*"$tab"}
        case "$key:$type" in
            mode:string) REQUEST_MODE="$value" ;;
            capacity:string) REQUEST_CAPACITY="$value" ;;
            unit:string) REQUEST_UNIT="$value" ;;
            algorithm:string) REQUEST_ALGORITHM="$value" ;;
            auto_apply:string) REQUEST_AUTO="$value" ;;
            vm_enabled:string) REQUEST_VM="$value" ;;
            size_bytes:number|size_bytes:string) REQUEST_SIZE="$value" ;;
            swappiness:number) REQUEST_SW="$value" ;;
            min_free_kbytes:number) REQUEST_MFK="$value" ;;
            watermark_scale_factor:number) REQUEST_WSF="$value" ;;
            vfs_cache_pressure:number) REQUEST_VCP="$value" ;;
            *) return 1 ;;
        esac
        MEMORY_PRESENT="$MEMORY_PRESENT$key|"
        REQUEST_FIELD_COUNT=$((REQUEST_FIELD_COUNT+1))
    done <<JSON_FIELDS
$CGI_JSON_FIELDS
JSON_FIELDS
    has_field mode
}

field() {
    case "$1" in mode) printf '%s' "$REQUEST_MODE" ;; capacity) printf '%s' "$REQUEST_CAPACITY" ;;
        unit) printf '%s' "$REQUEST_UNIT" ;; algorithm) printf '%s' "$REQUEST_ALGORITHM" ;;
        auto_apply) printf '%s' "$REQUEST_AUTO" ;; vm_enabled) printf '%s' "$REQUEST_VM" ;;
        size_bytes) printf '%s' "$REQUEST_SIZE" ;; swappiness) printf '%s' "$REQUEST_SW" ;;
        min_free_kbytes) printf '%s' "$REQUEST_MFK" ;; watermark_scale_factor) printf '%s' "$REQUEST_WSF" ;;
        vfs_cache_pressure) printf '%s' "$REQUEST_VCP" ;; esac
}
has_field() { case "$MEMORY_PRESENT" in *"|$1|"*) return 0 ;; *) return 1 ;; esac; }

request_size() {
    if has_field capacity || has_field unit; then
        ! has_field size_bytes || return 1
        vm_zram_normalize_capacity "$(field capacity)" "$(field unit)"
    else
        field size_bytes
    fi
}

memory_snapshot() {
    local setup=false
    [ ! -x /system/bin/mmd_setup ] || setup=true
    getprop | awk -v root="$MODDIR" -v pagesize="$(getconf PAGESIZE)" -v setup="$setup" \
        -v policy="$VM_SWAPPINESS_MIN $VM_SWAPPINESS_MAX $VM_MIN_FREE_KBYTES_MIN $VM_WATERMARK_SCALE_MIN $VM_WATERMARK_SCALE_MAX $VM_VFS_CACHE_PRESSURE_MIN $VM_VFS_CACHE_PRESSURE_MAX $VM_PRESET_SWAPPINESS $VM_PRESET_MIN_FREE_KBYTES $VM_ZRAM_PERCENT_MIN $VM_ZRAM_PERCENT_MAX $VM_MIN_FREE_RAM_DIVISOR" \
        -f "$MODDIR/scripts/memory_status.awk"
}

mutation_success() {
    json_headers
    printf '{"ok":true,"state":'
    memory_snapshot
    printf '}'
}

case "$REQUEST_METHOD" in
    GET) json_headers; memory_snapshot; exit 0 ;;
    POST) require_json_post; require_token; acquire_lock swap ;;
    *) json_error '405 Method Not Allowed' 'GET or POST required' ;;
esac
memory_init "$MODDIR" || json_error '500 Internal Server Error' 'memory state unavailable'
read_json_body 1024
parse_memory_fields || json_error '400 Bad Request' 'invalid memory request JSON'
mode=$(field mode)
zram_runtime_load
if [ "$mode" != boot_save ]; then
    [ "$(cat "$MODDIR/.vm_policy_ready" 2>/dev/null)" = true ] || json_error '503 Service Unavailable' 'boot memory readback is not ready'
    [ "$ZR_PENDING" != true ] || json_error '409 Conflict' 'online memory operation is running'
    case "$ZR_PHASE:$mode" in unconfirmed:recover|rollback_incomplete:recover) ;;
        unconfirmed:*|rollback_incomplete:*) json_error '409 Conflict' 'previous operation needs explicit recovery' ;;
    esac
fi
case "$mode" in
    custom)
        sw=$(field swappiness); mfk=$(field min_free_kbytes); wsf=$(field watermark_scale_factor); vcp=$(field vfs_cache_pressure)
        vm_validate_params "$sw" "$mfk" "$wsf" "$vcp" || json_error '400 Bad Request' 'VM parameters exceed kernel or device resource bounds'
        memory_apply_vm "$sw" "$mfk" "$wsf" "$vcp" manual
        result=$?
        case "$result" in 0) ;; 2) json_error '500 Internal Server Error' 'VM write failed and rollback was incomplete' ;;
            *) json_error '500 Internal Server Error' 'VM write failed; prior values restored' ;; esac
        mutation_success ;;
    system|stock|disabled|optimized|vm_restore)
        memory_restore_vm || json_error '500 Internal Server Error' 'pre-module VM restoration was not verified'
        mutation_success ;;
    boot_save)
        memory_config_load
        has_field auto_apply && MC_AUTO=$(field auto_apply)
        if [ "$MC_AUTO" = off ] && [ "$REQUEST_FIELD_COUNT" -eq 2 ] \
            && has_field auto_apply; then
            memory_config_commit || json_error '500 Internal Server Error' '关闭开机自动应用失败'
            mutation_success
            exit 0
        fi
        has_field vm_enabled && MC_VM=$(field vm_enabled)
        if has_field size_bytes || has_field capacity || has_field unit; then MC_SIZE=$(request_size) || json_error '400 Bad Request' 'invalid boot capacity'; fi
        has_field algorithm && MC_ALGORITHM=$(field algorithm)
        [ "$MC_ALGORITHM" != platform ] || MC_ALGORITHM=''
        for key in swappiness min_free_kbytes watermark_scale_factor vfs_cache_pressure; do
            if has_field "$key"; then
                value=$(field "$key")
                case "$key" in swappiness) MC_SW="$value" ;; min_free_kbytes) MC_MFK="$value" ;;
                    watermark_scale_factor) MC_WSF="$value" ;; vfs_cache_pressure) MC_VCP="$value" ;; esac
            fi
        done
        if [ "$MC_AUTO" = on ] && [ -n "$MC_SIZE$MC_ALGORITHM" ]; then
            [ "$(getprop ro.build.version.sdk)" -ge 37 ] && [ -x /system/bin/mmd_setup ] \
                && vm_zram_vendor_alias_supported || json_error '409 Conflict' 'boot ZRAM requires the supported API 37+ setup path'
        fi
        memory_config_save || json_error '400 Bad Request' 'boot settings were not saved; invalid values or persistence failure'
        mutation_success ;;
    preset|restore_system|zram_online|zram_size|zram_restore|recover)
        kind=apply
        if [ "$mode" = preset ]; then
            requested=$(vm_preset_size); algorithm=$(vm_preset_algorithm); kind=preset
        elif [ "$mode" = restore_system ] || [ "$mode" = zram_restore ]; then
            requested=$(vm_zram_state_field size "$MC_ORIGINAL")
            algorithm=$(vm_zram_state_field algorithm "$MC_ORIGINAL")
            [ "$mode" = restore_system ] && kind=restore_original || kind=restore_original_zram
        elif [ "$mode" = recover ]; then
            baseline="$ZR_BASELINE"; kind=recover
            [ "$(vm_zram_state_field boot_id "$baseline")" = "$(vm_zram_current_boot_id)" ] \
                && [ "$(vm_zram_state_field fingerprint "$baseline")" = "$(getprop ro.build.fingerprint)" ] \
                || json_error '409 Conflict' 'no restoration snapshot for this boot and build'
            requested=$(vm_zram_state_field size "$baseline")
            algorithm=$(vm_zram_state_field algorithm "$baseline")
        else
            requested=$(request_size) || json_error '400 Bad Request' 'invalid capacity or units'
            algorithm=$(field algorithm)
            [ -n "$algorithm" ] || algorithm=$(vm_zram_read_algorithm)
        fi
        vm_zram_size_is_valid "$requested" && vm_zram_algorithm_valid "$algorithm" \
            || json_error '400 Bad Request' 'capacity or compressor unsupported by this kernel/page size'
        if [ "$mode" = preset ] \
            && vm_zram_capacity_matches "$requested" && [ "$(vm_zram_read_algorithm)" = "$algorithm" ]; then
            values=$(vm_preset_params)
            set -- $values
            [ "$#" -eq 4 ] && memory_apply_vm "$1" "$2" "$3" "$4" "$kind" \
                || json_error '500 Internal Server Error' 'VM profile application was not verified'
            mutation_success
            exit 0
        fi
        zram_runtime_start "$requested" "$algorithm" "$kind"
        result=$?
        case "$result" in
            0) json_headers; printf '{"ok":true,"mode":"queued","operation_id":"%s","size":"%s","algorithm":"%s","scope":"this_boot"}' "$ZR_ID" "$requested" "$algorithm" ;;
            77) json_error '409 Conflict' "online operation unavailable: $ZR_CAPABILITY_REASON" ;;
            *) json_error '409 Conflict' 'online operation could not be queued' ;;
        esac ;;
    *) json_error '400 Bad Request' 'unknown memory action' ;;
esac
