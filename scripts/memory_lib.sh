#!/system/bin/sh
# Memory control source of truth: VM, boot preferences and online transactions.
# service.sh and swap.sh use these same definitions; memory_worker.sh is the
# sole finite worker. Platform maintenance is not rescheduled by this module.

# ---- Runtime observations, input contract and module preset ----
VM_ZRAM_SIZE_PROPERTY="persist.vendor.zram_swap_size_v2"
VM_MMD_ZRAM_SIZE_PROPERTY="mmd.zram.size"
VM_ZRAM_SIZE_MIN_BYTES=0
VM_ZRAM_SIZE_MAX_BYTES=0
VM_BASELINE_FILE="${VM_BASELINE_FILE:-${MODDIR:-/data/adb/modules/pixel9pro_control}/.vm_baseline}"
# Page size is discovered from the running kernel, never from block sectors.
VM_ZRAM_SIZE_STEP_BYTES=0
VM_ZRAM_MB_MIN=$(( (VM_ZRAM_SIZE_MIN_BYTES + 999999) / 1000000 ))
VM_ZRAM_MB_MAX=$(( VM_ZRAM_SIZE_MAX_BYTES / 1000000 ))
VM_ZRAM_PERCENT_MIN=1
VM_ZRAM_PERCENT_MAX=200

VM_SWAPPINESS_MIN=0
VM_SWAPPINESS_MAX=200
VM_MIN_FREE_KBYTES_MIN=1024
VM_MIN_FREE_KBYTES_MAX=0
VM_WATERMARK_SCALE_MIN=1
VM_WATERMARK_SCALE_MAX=3000
VM_VFS_CACHE_PRESSURE_MIN=1
VM_VFS_CACHE_PRESSURE_MAX=1000
VM_MIN_FREE_RAM_DIVISOR=50
VM_PRESET_SWAPPINESS=80
VM_PRESET_MIN_FREE_KBYTES=65536


vm_zram_current_boot_id() {
    local value
    IFS= read -r value < /proc/sys/kernel/random/boot_id || return 1
    printf '%s' "$value"
}

vm_zram_new_txid() {
    _vm_tx_boot=$(vm_zram_current_boot_id)
    _vm_tx_now=$(date +%s 2>/dev/null | tr -d ' \n\r\t')
    [ -n "$_vm_tx_boot" ] || _vm_tx_boot=unknown
    [ -n "$_vm_tx_now" ] || _vm_tx_now=0
    printf '%s-%s-%s' "$_vm_tx_boot" "$$" "$_vm_tx_now"
}

vm_is_uint_range() {
    _vm_value="$1"
    _vm_min="$2"
    _vm_max="$3"
    case "$_vm_value" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$_vm_value" -ge "$_vm_min" ] 2>/dev/null \
        && [ "$_vm_value" -le "$_vm_max" ] 2>/dev/null
}

vm_validate_params() {
    vm_is_uint_range "$1" "$VM_SWAPPINESS_MIN" "$VM_SWAPPINESS_MAX" \
        && vm_is_uint_range "$2" "$VM_MIN_FREE_KBYTES_MIN" "$VM_MIN_FREE_KBYTES_MAX" \
        && vm_is_uint_range "$3" "$VM_WATERMARK_SCALE_MIN" "$VM_WATERMARK_SCALE_MAX" \
        && vm_is_uint_range "$4" "$VM_VFS_CACHE_PRESSURE_MIN" "$VM_VFS_CACHE_PRESSURE_MAX"
}

vm_write_params() {
    _vm_sw="$1"
    _vm_mfk="$2"
    _vm_wsf="$3"
    _vm_vcp="$4"
    vm_is_uint_range "$_vm_sw" "$VM_SWAPPINESS_MIN" "$VM_SWAPPINESS_MAX" || return 1
    vm_is_uint_range "$_vm_mfk" "$VM_MIN_FREE_KBYTES_MIN" "$VM_MIN_FREE_KBYTES_MAX" || return 1
    vm_is_uint_range "$_vm_wsf" "$VM_WATERMARK_SCALE_MIN" "$VM_WATERMARK_SCALE_MAX" || return 1
    vm_is_uint_range "$_vm_vcp" "$VM_VFS_CACHE_PRESSURE_MIN" "$VM_VFS_CACHE_PRESSURE_MAX" || return 1
    vm_capture_baseline || return 1
    vm_params_match "$_vm_sw" "$_vm_mfk" "$_vm_wsf" "$_vm_vcp" && return 0

    _vm_old=$(vm_current_params)
    # Refuse a partial/unreadable baseline before touching any sysctl. Without
    # four actual values a failed write cannot be rolled back safely.
    set -- $_vm_old
    [ "$#" -eq 4 ] || return 1
    for _vm_old_value in "$@"; do
        case "$_vm_old_value" in ''|*[!0-9]*) return 1 ;; esac
    done
    if ! vm_write_params_raw "$_vm_sw" "$_vm_mfk" "$_vm_wsf" "$_vm_vcp" \
        || ! vm_params_match "$_vm_sw" "$_vm_mfk" "$_vm_wsf" "$_vm_vcp"; then
        set -- $_vm_old
        if [ "$#" -eq 4 ] \
            && vm_write_params_raw "$1" "$2" "$3" "$4" >/dev/null 2>&1 \
            && vm_params_match "$1" "$2" "$3" "$4"; then
            return 1
        fi
        return 2
    fi
}

vm_current_params() {
    # Read proc sysctls with buffered I/O. BusyBox ash read uses incremental
    # reads, which this kernel's sysctl handler can terminate before newline.
    awk 'FNR==1 {if(n++)printf " ";printf "%s",$1} END{if(n!=4)exit 1}' \
        /proc/sys/vm/swappiness /proc/sys/vm/min_free_kbytes \
        /proc/sys/vm/watermark_scale_factor /proc/sys/vm/vfs_cache_pressure
}

vm_write_params_raw() {
    printf '%s\n' "$1" > /proc/sys/vm/swappiness 2>/dev/null \
        && printf '%s\n' "$2" > /proc/sys/vm/min_free_kbytes 2>/dev/null \
        && printf '%s\n' "$3" > /proc/sys/vm/watermark_scale_factor 2>/dev/null \
        && printf '%s\n' "$4" > /proc/sys/vm/vfs_cache_pressure 2>/dev/null
}

vm_params_match() {
    [ "$(vm_current_params)" = "$1 $2 $3 $4" ]
}

vm_baseline_params() {
    [ "$(vm_zram_state_field boot_id "$VM_BASELINE_FILE")" = "$(vm_zram_current_boot_id)" ] \
        && [ -n "$(vm_zram_current_boot_id)" ] \
        && [ "$(vm_zram_state_field fingerprint "$VM_BASELINE_FILE")" = "$(getprop ro.build.fingerprint)" ] || return 1
    _vm_baseline_values=""
    for _vm_baseline_key in swappiness min_free_kbytes watermark_scale_factor vfs_cache_pressure; do
        _vm_baseline_value=$(vm_zram_state_field "$_vm_baseline_key" "$VM_BASELINE_FILE")
        case "$_vm_baseline_value" in ''|*[!0-9]*) return 1 ;; esac
        _vm_baseline_values="$_vm_baseline_values $_vm_baseline_value"
    done
    printf '%s' "${_vm_baseline_values# }"
}

vm_capture_baseline() {
    vm_baseline_params >/dev/null 2>&1 && return 0
    _vm_capture_boot=$(vm_zram_current_boot_id)
    [ -n "$_vm_capture_boot" ] || return 1
    set -- $(vm_current_params)
    [ "$#" -eq 4 ] || return 1
    for _vm_capture_value in "$@"; do
        case "$_vm_capture_value" in ''|*[!0-9]*) return 1 ;; esac
    done
    vm_zram_atomic_state_write "$VM_BASELINE_FILE" "schema=1
boot_id=$_vm_capture_boot
fingerprint=$(getprop ro.build.fingerprint)
source=before_module_write
swappiness=$1
min_free_kbytes=$2
watermark_scale_factor=$3
vfs_cache_pressure=$4"
}

vm_zram_page_size() {
    _vz_page=$(getconf PAGESIZE 2>/dev/null | tr -d ' \r\n\t')
    case "$_vz_page" in 4096|16384|65536) printf '%s' "$_vz_page" ;; *) return 1 ;; esac
}

vm_zram_mem_total_bytes() {
    awk '/^MemTotal:/{if ($2 > 0) printf "%.0f", $2 * 1024; exit}' /proc/meminfo 2>/dev/null
}

vm_zram_init_limits() {
    VM_ZRAM_SIZE_STEP_BYTES=$(vm_zram_page_size) || VM_ZRAM_SIZE_STEP_BYTES=0
    _vz_ram=$(vm_zram_mem_total_bytes)
    case "$_vz_ram" in ''|*[!0-9]*) return 1 ;; esac
    # Product bounds: at least two pages for swap format, at most twice RAM
    # following the kernel documentation's 2:1 sizing guidance. These are not
    # an Android performance guarantee. Keep large arithmetic in awk (mksh).
    VM_ZRAM_SIZE_MIN_BYTES=$((VM_ZRAM_SIZE_STEP_BYTES * 2))
    VM_ZRAM_SIZE_MAX_BYTES=$(awk -v ram="$_vz_ram" -v page="$VM_ZRAM_SIZE_STEP_BYTES" -v pct="$VM_ZRAM_PERCENT_MAX" 'BEGIN {printf "%.0f", int(ram*pct/100/page)*page}')
    VM_MIN_FREE_KBYTES_MAX=$(awk -v ram="$_vz_ram" -v divisor="$VM_MIN_FREE_RAM_DIVISOR" 'BEGIN {printf "%.0f", int(ram/1024/divisor)}')
    VM_ZRAM_MB_MIN=$(awk -v bytes="$VM_ZRAM_SIZE_MIN_BYTES" 'BEGIN {printf "%.2f", (int(bytes/10000)+1)/100}')
    VM_ZRAM_MB_MAX=$(awk -v bytes="$VM_ZRAM_SIZE_MAX_BYTES" 'BEGIN {printf "%.2f", int(bytes/10000)/100}')
}

vm_zram_normalize_capacity() {
    _vz_value="$1"
    case "$2" in
        mb|mib)
            _vz_multiplier=1000000
            [ "$2" = mib ] && _vz_multiplier=1048576
            [ "$VM_ZRAM_SIZE_STEP_BYTES" -gt 0 ] || return 1
            awk -v value="$_vz_value" -v min="$VM_ZRAM_SIZE_MIN_BYTES" -v max="$VM_ZRAM_SIZE_MAX_BYTES" \
                -v page="$VM_ZRAM_SIZE_STEP_BYTES" -v multiplier="$_vz_multiplier" '
                BEGIN {
                    if (value !~ /^[0-9]+([.][0-9][0-9]?)?$/ || length(value)>16) exit 1
                    bytes=value*multiplier; aligned=int((bytes+page-1)/page)*page
                    if (bytes<min || aligned>max) exit 1
                    printf "%.0f", aligned
                }' </dev/null ;;
        percent)
            vm_is_uint_range "$_vz_value" "$VM_ZRAM_PERCENT_MIN" "$VM_ZRAM_PERCENT_MAX" || return 1
            awk -v value="$_vz_value" 'BEGIN {printf "%d%%", value}' </dev/null ;;
        *) return 1 ;;
    esac
}

vm_zram_size_is_valid() {
    case "$1" in
        *%)
            _vz_percent=${1%%%}
            vm_is_uint_range "$_vz_percent" "$VM_ZRAM_PERCENT_MIN" "$VM_ZRAM_PERCENT_MAX" \
                && [ "$VM_ZRAM_SIZE_STEP_BYTES" -gt 0 ] ;;
        ''|*[!0-9]*) return 1 ;;
        *)
            awk -v value="$1" -v min="$VM_ZRAM_SIZE_MIN_BYTES" -v max="$VM_ZRAM_SIZE_MAX_BYTES" -v page="$VM_ZRAM_SIZE_STEP_BYTES" \
                'BEGIN {exit !(length(value)<=16 && page>0 && value>=min && value<=max && value%page==0)}' </dev/null ;;
    esac
}

vm_zram_size_to_bytes() {
    case "$1" in
        *%)
            _vz_percent=${1%%%}
            case "$_vz_percent" in ''|*[!0-9]*) return 1 ;; esac
            [ "$VM_ZRAM_SIZE_STEP_BYTES" -gt 0 ] || return 1
            awk -v pct="$_vz_percent" -v page="$VM_ZRAM_SIZE_STEP_BYTES" -v ram="$(vm_zram_mem_total_bytes)" \
                'BEGIN {if (ram<=0) exit 1; printf "%.0f", int(ram*pct/100/page)*page}' </dev/null ;;
        ''|*[!0-9]*) return 1 ;;
        *) printf '%s' "$1" ;;
    esac
}

vm_zram_capacity_matches() {
    vm_zram_is_active || return 1
    _vz_match_expected=$(vm_zram_size_to_bytes "$1") || return 1
    _vz_match_actual=$(vm_zram_read_disksize)
    case "$_vz_match_expected:$_vz_match_actual" in *[!0-9:]*) return 1 ;; esac
    [ -n "$_vz_match_actual" ] && [ -n "$_vz_match_expected" ] || return 1
    if [ "$_vz_match_actual" = "$_vz_match_expected" ]; then return 0; fi
    # Percentage requests can be rounded down by mmd or PAGE_ALIGN'd up by
    # the kernel. Accept only that single boundary page, never an arbitrary
    # percentage tolerance. Absolute byte requests must match exactly.
    case "$1" in
        *%)
            awk -v expected="$_vz_match_expected" -v actual="$_vz_match_actual" -v page="$VM_ZRAM_SIZE_STEP_BYTES" \
                -v pct="${1%%%}" -v ram="$(vm_zram_mem_total_bytes)" \
                'BEGIN {raw=ram*pct/100; exit !(ram>0 && raw>expected && actual==expected+page)}' </dev/null ;;
        *) return 1 ;;
    esac
}

vm_zram_property_value() {
    getprop "$1"
}

vm_zram_state_field() {
    local wanted="$1" key value result found=false
    [ -f "$2" ] && [ ! -L "$2" ] || return 1
    while IFS='=' read -r key value || [ -n "$key" ]; do
        if [ "$key" = "$wanted" ]; then result="$value"; found=true; fi
    done < "$2" || return 1
    [ "$found" = true ] || return 1
    printf '%s' "$result"
}

vm_zram_atomic_state_write() {
    command -v state_atomic_write >/dev/null 2>&1 \
        || . "${MODDIR:-${MODPATH:-/data/adb/modules/pixel9pro_control}}/scripts/state_io_lib.sh" || return 1
    state_atomic_write "$1" "$2"
}

vm_zram_matches() {
    [ "$(vm_zram_read_algorithm)" = "$1" ] && [ "$(vm_zram_read_disksize)" = "$2" ] \
        && vm_zram_is_active
}

vm_zram_read_algorithm() {
    local algorithms selected
    algorithms=$(cat /sys/block/zram0/comp_algorithm) || return 1
    case "$algorithms" in
        *'['*']'*) selected=${algorithms#*\[}; printf '%s' "${selected%%\]*}" ;;
        *) return 1 ;;
    esac
}

vm_zram_read_disksize() {
    cat /sys/block/zram0/disksize
}

vm_zram_read_swap_kb() {
    awk '$1 ~ /(^|\/)zram0$/ {print $4; found=1; exit} END {if (!found) print 0}' /proc/swaps 2>/dev/null
}

vm_zram_read_swap_size_kb() {
    awk '$1 ~ /(^|\/)zram0$/ {print $3; found=1; exit} END {if (!found) print 0}' /proc/swaps 2>/dev/null
}

vm_zram_is_active() {
    [ "$(vm_zram_active_state)" = active ]
}

vm_zram_active_state() {
    _vz_active=$(awk '$1 ~ /(^|\/)zram0$/ {found=1} END {print found ? "active" : "inactive"}' /proc/swaps 2>/dev/null)
    [ "$?" -eq 0 ] || { printf unknown; return 0; }
    printf '%s' "$_vz_active"
}

vm_zram_read_swap_total_kb() {
    awk '/^SwapTotal:/{print $2; exit}' /proc/meminfo 2>/dev/null
}

vm_zram_mmd_ready() {
    [ "$(vm_zram_property_value mmd.zram.enabled)" = true ] \
        && [ "$(vm_zram_property_value mmd.setup_complete)" = true ] \
        && [ "$(vm_zram_property_value init.svc.mmd)" = running ]
}

vm_zram_vendor_alias_supported() {
    # A boot-scoped alias is required; a runtime on-property trigger could
    # reconfigure memory during the user's session and must not be accepted.
    awk '
        /^[^ \t#]/ {boot=($1=="on" && ($2=="init" || $2=="boot" || $2=="post-fs-data" || $2=="load_persist_props_action"))}
        boot && $1=="setprop" && $2=="mmd.zram.size" \
            && $3 ~ /^\$\{persist[.]vendor[.]zram_swap_size_v2(:-[0-9]+%?)?\}$/ {found=1}
        END {exit !found}' /vendor/etc/init/hw/init.*.board.rc 2>/dev/null
}

vm_zram_target_supported() {
    [ "$(getprop ro.build.version.sdk)" -ge 37 ] || return 1
    vm_zram_mmd_ready && vm_zram_vendor_alias_supported \
        && [ "$VM_ZRAM_SIZE_STEP_BYTES" -gt 0 ] || return 1
    # This contract represents zram0 only, so fail closed for multi-device
    # mmd configuration instead of writing a scalar over a property list.
    _vz_devices=$(vm_zram_property_value mmd.zram.num_devices)
    case "$_vz_devices" in ''|1) ;; *) return 1 ;; esac
    for _vz_device_path in /sys/block/zram*; do
        [ ! -d "$_vz_device_path" ] || [ "$_vz_device_path" = /sys/block/zram0 ] || return 1
    done
}

vm_zram_owner() {
    if [ "$(vm_zram_property_value mmd.zram.enabled)" = true ]; then printf mmd; else printf unknown; fi
}

vm_zram_read_requested_algorithm() {
    if [ "$(vm_zram_owner)" = mmd ]; then
        vm_zram_property_value mmd.zram.comp_algorithm
    else
        vm_zram_property_value persist.vendor.zram_comp_algorithm
    fi
}

vm_zram_read_requested_size() {
    if [ "$(vm_zram_owner)" = mmd ]; then
        vm_zram_property_value "$VM_MMD_ZRAM_SIZE_PROPERTY"
    else
        vm_zram_property_value "$VM_ZRAM_SIZE_PROPERTY"
    fi
}

vm_zram_algorithms() {
    cat /sys/block/zram0/comp_algorithm 2>/dev/null | tr -d '[]' | tr ' ' '\n' | sed '/^$/d'
}

vm_zram_algorithm_valid() {
    case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; esac
    [ "$1" != lz77eh ] || [ "$VM_ZRAM_SIZE_STEP_BYTES" = 4096 ] || return 1
    vm_zram_algorithms | grep -Fxq "$1"
}

vm_zram_algorithms_json() {
    vm_zram_algorithms | awk -v page="$VM_ZRAM_SIZE_STEP_BYTES" '
        BEGIN {printf "["}
        $0 ~ /^[A-Za-z0-9_-]+$/ && !($0=="lz77eh" && page!=4096) {
            if (n++) printf ","; printf "\"%s\"",$0
        }
        END {printf "]"}'
}

vm_preset_size() {
    vm_zram_state_field size "$MC_ORIGINAL"
}

vm_preset_params() {
    local wsf vcp
    wsf=$(vm_zram_state_field watermark_scale_factor "$MC_ORIGINAL")
    vcp=$(vm_zram_state_field vfs_cache_pressure "$MC_ORIGINAL")
    [ -n "$wsf" ] && [ -n "$vcp" ] || return 1
    printf '%s %s %s %s' "$VM_PRESET_SWAPPINESS" "$VM_PRESET_MIN_FREE_KBYTES" "$wsf" "$vcp"
}

vm_preset_algorithm() {
    vm_zram_state_field algorithm "$MC_ORIGINAL"
}

vm_zram_receipt() {
    printf 'owner=%s\nmmd_setup_complete=%s\nmmd_service=%s\n' "$(vm_zram_owner)" \
        "$(vm_zram_property_value mmd.setup_complete)" "$(vm_zram_property_value init.svc.mmd)"
    printf 'mmd_zram_enabled=%s\nmmd_requested_size=%s\nmmd_requested_algorithm=%s\n' \
        "$(vm_zram_property_value mmd.zram.enabled)" "$(vm_zram_read_requested_size)" "$(vm_zram_read_requested_algorithm)"
    printf 'persistent_size_request=%s\nalgorithm=%s\ndisksize_bytes=%s\nactive_state=%s\n' \
        "$(vm_zram_property_value "$VM_ZRAM_SIZE_PROPERTY")" "$(vm_zram_read_algorithm)" "$(vm_zram_read_disksize)" "$(vm_zram_active_state)"
    printf 'swap_used_kb=%s\nswap_size_kb=%s\nswap_total_kb=%s\npage_size=%s\n' \
        "$(vm_zram_read_swap_kb)" "$(vm_zram_read_swap_size_kb)" "$(vm_zram_read_swap_total_kb)" "$VM_ZRAM_SIZE_STEP_BYTES"
}


# User-selected boot settings are separate from one-boot operations. Values
# are data, never sourced as shell code. No timer reapplies memory settings.

memory_config_init() {
    MC_ROOT="$1"
    MC_CONFIG="$MC_ROOT/.memory_boot_config"
    MC_BASELINE="$MC_ROOT/.memory_boot_baseline"
    MC_STAGE="$MC_ROOT/.memory_boot_stage"
    MC_RESULT="$MC_ROOT/.memory_boot_result"
    MC_RUNTIME_VM="$MC_ROOT/.memory_runtime_vm"
    MC_ORIGINAL="$MC_ROOT/.memory_original"
    command -v state_atomic_write >/dev/null 2>&1 || . "$MC_ROOT/scripts/state_io_lib.sh"
}

memory_original_refresh() {
    local original
    original=$(/system/bin/sh "$MC_ROOT/scripts/vendor_source.sh") || return 1
    state_atomic_write "$MC_ORIGINAL" "$original"
}

memory_original_params() {
    [ "$(vm_zram_state_field fingerprint "$MC_ORIGINAL")" = "$(getprop ro.build.fingerprint)" ] || return 1
    awk -F '=' '
        $1=="swappiness"{sw=$2}
        $1=="min_free_kbytes"{mfk=$2}
        $1=="watermark_scale_factor"{wsf=$2}
        $1=="vfs_cache_pressure"{vcp=$2}
        END {if(sw=="" || mfk=="" || wsf=="" || vcp=="")exit 1;printf "%s %s %s %s",sw,mfk,wsf,vcp}
    ' "$MC_ORIGINAL"
}

memory_config_load() {
    local key value
    MC_AUTO=off; MC_VM=off; MC_SIZE=''; MC_ALGORITHM=''
    MC_SW=''; MC_MFK=''; MC_WSF=''; MC_VCP=''
    [ -f "$MC_CONFIG" ] && [ ! -L "$MC_CONFIG" ] || return 0
    while IFS='=' read -r key value || [ -n "$key" ]; do
        case "$key" in auto_apply) MC_AUTO="$value" ;; vm_enabled) MC_VM="$value" ;;
            size) MC_SIZE="$value" ;; algorithm) MC_ALGORITHM="$value" ;;
            swappiness) MC_SW="$value" ;; min_free_kbytes) MC_MFK="$value" ;;
            watermark_scale_factor) MC_WSF="$value" ;; vfs_cache_pressure) MC_VCP="$value" ;;
        esac
    done < "$MC_CONFIG"
}

memory_config_hash() {
    if [ -f "$MC_CONFIG" ]; then sha256sum "$MC_CONFIG" | awk '{print $1}'; else printf none; fi
}

memory_config_validate() {
    case "$MC_AUTO:$MC_VM" in on:on|on:off|off:on|off:off) ;; *) return 1 ;; esac
    [ -z "$MC_SIZE" ] || vm_zram_size_is_valid "$MC_SIZE" || return 1
    [ -z "$MC_ALGORITHM" ] || vm_zram_algorithm_valid "$MC_ALGORITHM" || return 1
    [ "$MC_VM" != on ] || vm_validate_params "$MC_SW" "$MC_MFK" "$MC_WSF" "$MC_VCP"
}

memory_config_commit() {
    state_atomic_write "$MC_CONFIG" "schema=2
auto_apply=$MC_AUTO
vm_enabled=$MC_VM
size=$MC_SIZE
algorithm=$MC_ALGORITHM
swappiness=$MC_SW
min_free_kbytes=$MC_MFK
watermark_scale_factor=$MC_WSF
vfs_cache_pressure=$MC_VCP"
}

memory_config_save() {
    memory_config_validate && memory_config_commit
}

memory_vm_record() {
    state_atomic_write "$MC_RUNTIME_VM" "schema=2
boot_id=$(vm_zram_current_boot_id)
fingerprint=$(getprop ro.build.fingerprint)
source=$5
swappiness=$1
min_free_kbytes=$2
watermark_scale_factor=$3
vfs_cache_pressure=$4"
}

memory_apply_vm() {
    local old_values old_record old_custom old_mode old_feature write_rc
    old_values=$(vm_current_params)
    old_record=$(cat "$MC_RUNTIME_VM" 2>/dev/null)
    old_custom=$(cat "$MC_ROOT/.swap_custom" 2>/dev/null)
    old_mode=$(cat "$MC_ROOT/.swap_mode" 2>/dev/null)
    old_feature=$(cat "$MC_ROOT/.feature_vm" 2>/dev/null)
    vm_write_params "$1" "$2" "$3" "$4" || return $?
    if memory_vm_record "$1" "$2" "$3" "$4" "${5:-manual}" \
        && state_atomic_write "$MC_ROOT/.swap_custom" "swappiness=$1
min_free_kbytes=$2
watermark_scale_factor=$3
vfs_cache_pressure=$4" \
        && state_atomic_write "$MC_ROOT/.swap_mode" custom \
        && state_atomic_write "$MC_ROOT/.feature_vm" optimized; then return 0; fi
    write_rc=1
    set -- $old_values
    vm_write_params_raw "$1" "$2" "$3" "$4" && vm_params_match "$1" "$2" "$3" "$4" || write_rc=2
    state_atomic_write "$MC_RUNTIME_VM" "$old_record" \
        && state_atomic_write "$MC_ROOT/.swap_custom" "$old_custom" \
        && state_atomic_write "$MC_ROOT/.swap_mode" "$old_mode" \
        && state_atomic_write "$MC_ROOT/.feature_vm" "$old_feature" || write_rc=2
    return "$write_rc"
}

memory_restore_vm() {
    local values
    memory_original_refresh || return 1
    values=$(memory_original_params) || return 1
    set -- $values
    memory_apply_vm "$1" "$2" "$3" "$4" restore || return $?
    state_atomic_write "$MC_ROOT/.swap_mode" system \
        && state_atomic_write "$MC_ROOT/.feature_vm" system
}

memory_boot_prepare() {
    local boot fingerprint original_size original_algo requested_size requested_algo phase attempt=0
    boot=$(vm_zram_current_boot_id)
    fingerprint=$(getprop ro.build.fingerprint)
    [ "$(vm_zram_state_field boot_id "$MC_STAGE")" != "$boot" ] || return 0
    # APatch's late_start entry follows load_persist_props_action, unlike the
    # earlier post-fs-data hook. Wait only for persistent-property readiness,
    # then submit before mmd's sys.boot_completed trigger.
    while [ "$(getprop ro.persistent_properties.ready)" != true ]; do
        [ "$attempt" -lt 20 ] && [ "$(getprop mmd.setup_complete)" != true ] || return 1
        sleep 1; attempt=$((attempt+1))
    done
    original_size=$(vm_zram_property_value mmd.zram.size)
    original_algo=$(vm_zram_property_value mmd.zram.comp_algorithm)
    state_atomic_write "$MC_BASELINE" "schema=2
boot_id=$boot
fingerprint=$fingerprint
size=$original_size
algorithm=$original_algo" || return 1
    memory_config_load
    [ "$MC_AUTO" != on ] || memory_config_validate || return 1
    phase=observe
    if [ "$MC_AUTO" = on ] && { [ -n "$MC_SIZE" ] || [ -n "$MC_ALGORITHM" ]; }; then
        [ "$(getprop ro.build.version.sdk)" -ge 37 ] && [ -x /system/bin/mmd_setup ] \
            && vm_zram_vendor_alias_supported || return 1
        # The hook precedes sys.boot_completed and the first mmd_setup. Never
        # rebuild an already initialized swap as a late-boot compensation.
        [ "$(vm_zram_property_value mmd.setup_complete)" != true ] \
            && [ "$(vm_zram_active_state)" = inactive ] || return 1
        requested_size=${MC_SIZE:-$original_size}
        requested_algo=${MC_ALGORITHM:-$original_algo}
        if ! setprop mmd.zram.size "$requested_size" \
            || ! setprop mmd.zram.comp_algorithm "$requested_algo" \
            || [ "$(vm_zram_property_value mmd.zram.size)" != "$requested_size" ] \
            || [ "$(vm_zram_property_value mmd.zram.comp_algorithm)" != "$requested_algo" ]; then
            setprop mmd.zram.comp_algorithm "$original_algo"
            setprop mmd.zram.size "$original_size"
            return 1
        fi
        phase=prepared
    fi
    if state_atomic_write "$MC_STAGE" "schema=2
boot_id=$boot
fingerprint=$fingerprint
config_hash=$(memory_config_hash)
phase=$phase
size=$MC_SIZE
algorithm=$MC_ALGORITHM"; then return 0; fi
    if [ "$phase" = prepared ]; then
        setprop mmd.zram.comp_algorithm "$original_algo"
        setprop mmd.zram.size "$original_size"
        [ "$(vm_zram_property_value mmd.zram.size)" = "$original_size" ] \
            && [ "$(vm_zram_property_value mmd.zram.comp_algorithm)" = "$original_algo" ] || return 2
    fi
    return 1
}

memory_boot_apply_vm() {
    local boot phase vm_phase zram_phase
    boot=$(vm_zram_current_boot_id)
    [ "$(vm_zram_state_field boot_id "$MC_RESULT")" != "$boot" ] || return 0
    vm_capture_baseline || return 1
    memory_config_load
    [ "$MC_AUTO" != on ] || memory_config_validate || return 1
    vm_phase=observe; zram_phase=observe; phase=effective
    if [ "$MC_AUTO" = on ]; then
        if [ "$MC_VM" = on ]; then
            memory_apply_vm "$MC_SW" "$MC_MFK" "$MC_WSF" "$MC_VCP" boot || return $?
            vm_phase=effective
        fi
        if [ -n "$MC_SIZE" ] || [ -n "$MC_ALGORITHM" ]; then
            zram_phase=effective
            [ "$(vm_zram_state_field phase "$MC_STAGE")" = prepared ] \
                && [ "$(vm_zram_state_field config_hash "$MC_STAGE")" = "$(memory_config_hash)" ] \
                && vm_zram_is_active || { zram_phase=unconfirmed; phase=unconfirmed; }
            [ -z "$MC_SIZE" ] || vm_zram_capacity_matches "$MC_SIZE" || { zram_phase=drifted; phase=drifted; }
            [ -z "$MC_ALGORITHM" ] || [ "$(vm_zram_read_algorithm)" = "$MC_ALGORITHM" ] || { zram_phase=drifted; phase=drifted; }
        fi
    fi
    if [ "$MC_AUTO:$MC_VM" != on:on ]; then
        state_atomic_write "$MC_ROOT/.swap_mode" system \
            && state_atomic_write "$MC_ROOT/.feature_vm" system || return 1
    fi
    state_atomic_write "$MC_ROOT/.vm_reboot_required" false || return 1
    state_atomic_write "$MC_RESULT" "schema=2
boot_id=$boot
fingerprint=$(getprop ro.build.fingerprint)
config_hash=$(memory_config_hash)
auto_apply=$MC_AUTO
phase=$phase
vm=$vm_phase
zram=$zram_phase
requested_size=$MC_SIZE
requested_algorithm=$MC_ALGORITHM
vm_enabled=$MC_VM
swappiness=$MC_SW
min_free_kbytes=$MC_MFK
watermark_scale_factor=$MC_WSF
vfs_cache_pressure=$MC_VCP"
}

zram_runtime_init() {
    ZR_ROOT="$1"
    ZR_STATE="$ZR_ROOT/.zram_runtime_state"
    ZR_LOCK="$ZR_ROOT/.zram_runtime.lock"
    ZR_BASELINE="$ZR_ROOT/.zram_runtime_baseline"
    . "$ZR_ROOT/scripts/state_io_lib.sh" && . "$ZR_ROOT/scripts/background_tasks_lib.sh"
}

zram_runtime_load() {
    local key value
    ZR_ID=''; ZR_BOOT=''; ZR_PHASE=none; ZR_REASON=''; ZR_SIZE=''; ZR_ALGORITHM=''; ZR_KIND=''; ZR_UPTIME=0
    ZR_RECOVERY_SIZE=''; ZR_RECOVERY_ALGORITHM=''
    ZR_PENDING=false
    if [ -f "$ZR_STATE" ] && [ ! -L "$ZR_STATE" ]; then
        while IFS='=' read -r key value || [ -n "$key" ]; do
            case "$key" in id) ZR_ID="$value" ;; boot_id) ZR_BOOT="$value" ;; phase) ZR_PHASE="$value" ;;
                reason) ZR_REASON="$value" ;; size) ZR_SIZE="$value" ;; algorithm) ZR_ALGORITHM="$value" ;;
                kind) ZR_KIND="$value" ;; uptime) ZR_UPTIME="$value" ;;
                recovery_size) ZR_RECOVERY_SIZE="$value" ;; recovery_algorithm) ZR_RECOVERY_ALGORITHM="$value" ;; esac
        done < "$ZR_STATE"
    fi
    case "$ZR_ID:$ZR_REASON:$ZR_PHASE" in *[!A-Za-z0-9._:-]*) ZR_PHASE=unconfirmed; ZR_REASON=invalid_state ;; esac
    if [ -n "$ZR_BOOT" ] && [ "$ZR_BOOT" != "$(vm_zram_current_boot_id)" ]; then ZR_PHASE=historical; fi
    case "$ZR_PHASE" in
        queued|preflight|stopping_mmd|swapoff|rebuilding|verifying|rollback)
            if module_lock_owner_alive "$ZR_LOCK"; then ZR_PENDING=true
            elif [ "$ZR_PHASE" = queued ] && vm_is_uint_range "$ZR_UPTIME" 1 2147483647 \
                && awk -v queued="$ZR_UPTIME" '{exit !($1>=queued && $1-queued<=30)}' /proc/uptime; then ZR_PENDING=true
            else ZR_PHASE=unconfirmed; ZR_REASON=worker_interrupted; fi ;;
        success)
            if ! vm_zram_matches "$ZR_ALGORITHM" "$(vm_zram_size_to_bytes "$ZR_SIZE")" \
                && { ! vm_zram_capacity_matches "$ZR_SIZE" || [ "$(vm_zram_read_algorithm)" != "$ZR_ALGORITHM" ]; }; then
                ZR_PHASE=external_changed; ZR_REASON=runtime_owner_changed
            fi ;;
        ''|failed|deferred|rollback_complete|rollback_incomplete|historical|unconfirmed|external_changed) ;;
        *) ZR_PHASE=unconfirmed; ZR_REASON=invalid_state ;;
    esac
    [ -n "$ZR_PHASE" ] || ZR_PHASE=none
}

zram_runtime_commit() {
    state_atomic_write "$ZR_STATE" "schema=2
id=$ZR_ID
boot_id=$ZR_BOOT
phase=$ZR_PHASE
reason=$ZR_REASON
size=$ZR_SIZE
algorithm=$ZR_ALGORITHM
kind=$ZR_KIND
recovery_size=$ZR_RECOVERY_SIZE
recovery_algorithm=$ZR_RECOVERY_ALGORITHM
uptime=$ZR_UPTIME"
}

zram_runtime_memory_ready() {
    # Used is uncompressed swap slots, including backing pages. Do not add
    # bd_count again or pre-credit memory that draining may eventually free.
    ZR_AVAILABLE=$(awk '/^MemAvailable:/{printf "%.0f",$2*1024;exit}' /proc/meminfo)
    ZR_REQUIRED=$(awk -v used="$(vm_zram_read_swap_kb)" \
        -v minfree="$(cat /proc/sys/vm/min_free_kbytes)" '
        /^MemTotal:/ {margin=$2*1024/20; if (minfree*1024>margin) margin=minfree*1024;
            printf "%.0f", used*1024+margin; exit}' /proc/meminfo)
    awk -v available="$ZR_AVAILABLE" -v required="$ZR_REQUIRED" \
        'BEGIN {exit !(available>0 && required>0 && available>=required)}' </dev/null
}

zram_runtime_capability() {
    ZR_CAPABLE=false; ZR_CAPABILITY_REASON=platform_setup_unavailable
    [ "$(getprop ro.build.version.sdk)" -ge 37 ] && [ -x /system/bin/mmd_setup ] \
        && vm_zram_mmd_ready && vm_zram_vendor_alias_supported \
        && grep -Eq '^service mmd_setup /system/bin/mmd_setup[[:space:]]*$' /system/etc/init/mmd.rc || return 0
    ZR_CAPABILITY_REASON=unsupported_swap_layout
    [ "$(awk 'NR>1 {n++} END {print n+0}' /proc/swaps)" = 1 ] && vm_zram_is_active || return 0
    ZR_CAPABILITY_REASON=writeback_history_present
    # mmd caches capacity and owns an in-process rolling writeback history.
    # A daemon restart is required after resize. Without an export/import ABI,
    # only a generation with no prior backing writes can retain its budget.
    awk '{exit !(NF>=3 && $1==0 && $2==0 && $3==0)}' /sys/block/zram0/bd_stat || return 0
    ZR_CAPABILITY_REASON=memory_pressure
    # Brief nonzero samples are normal. Refuse a sustained recent stall rather
    # than treating any historical PSI activity as an unavailable device.
    zram_runtime_pressure_ready || return 0
    ZR_CAPABILITY_REASON=insufficient_swapoff_headroom
    zram_runtime_memory_ready || return 0
    ZR_CAPABILITY_REASON=ready; ZR_CAPABLE=true
}

zram_runtime_pressure_ready() {
    awk '{split($2,a,"="); if (($1=="full" && a[2]>=1) || ($1=="some" && a[2]>=10)) exit 1}' /proc/pressure/memory
}

zram_runtime_start() {
    local requested_size requested_algorithm requested_kind interrupted_size interrupted_algorithm
    requested_size="$1"; requested_algorithm="$2"; requested_kind="${3:-apply}"
    vm_zram_size_is_valid "$requested_size" && vm_zram_algorithm_valid "$requested_algorithm" || return 64
    interrupted_size="$ZR_SIZE"; interrupted_algorithm="$ZR_ALGORITHM"
    if [ "$requested_kind" = recover ] && [ -n "$ZR_RECOVERY_SIZE" ]; then
        interrupted_size="$ZR_RECOVERY_SIZE"; interrupted_algorithm="$ZR_RECOVERY_ALGORITHM"
    fi
    # swap.sh already loaded and checked this operation under its write lock.
    [ "$ZR_PENDING" != true ] || return 75
    if [ "$requested_kind" != recover ]; then
        case "$ZR_PHASE" in unconfirmed|rollback_incomplete) return 76 ;; esac
        # The finite worker performs the authoritative resource/owner check
        # before any runtime write. The HTTP request only validates intent.
    fi
    state_lock_acquire "$ZR_LOCK" 1 || return 75
    ZR_BOOT=$(vm_zram_current_boot_id); ZR_UPTIME=$(awk '{printf "%d",$1}' /proc/uptime)
    ZR_ID=$(vm_zram_new_txid); ZR_PHASE=queued; ZR_REASON=explicit_online_request
    ZR_SIZE="$requested_size"; ZR_ALGORITHM="$requested_algorithm"; ZR_KIND="$requested_kind"
    ZR_RECOVERY_SIZE=''; ZR_RECOVERY_ALGORITHM=''
    if [ "$requested_kind" = recover ]; then
        ZR_RECOVERY_SIZE="$interrupted_size"; ZR_RECOVERY_ALGORITHM="$interrupted_algorithm"
    fi
    if ! zram_runtime_commit; then state_lock_release "$ZR_LOCK"; return 1; fi
    sh "$ZR_ROOT/scripts/memory_worker.sh" "$ZR_ROOT" "$ZR_ID" >/dev/null 2>"$ZR_ROOT/.memory_operation_error" </dev/null &
}

zram_runtime_wait_service() {
    local attempt=0
    while [ "$(vm_zram_property_value init.svc.mmd)" != "$1" ]; do
        [ "$attempt" -lt 10 ] || return 1
        sleep 1; attempt=$((attempt+1))
    done
}

zram_runtime_properties() {
    setprop mmd.zram.size "$1" && setprop mmd.zram.comp_algorithm "$2" \
        && [ "$(vm_zram_read_requested_size)" = "$1" ] \
        && [ "$(vm_zram_read_requested_algorithm)" = "$2" ]
}

zram_runtime_build() {
    [ "$(vm_zram_active_state)" = inactive ] || return 1
    printf '1\n' > /sys/block/zram0/reset || return 1
    [ "$(vm_zram_read_disksize)" = 0 ] || return 1
    /system/bin/mmd_setup > "$ZR_ROOT/.zram_setup_output" 2>&1 || return 1
    vm_zram_capacity_matches "$1" && [ "$(vm_zram_read_algorithm)" = "$2" ] || return 1
    # Restore writable kernel state that reset clears. The daily daemon
    # history was empty by admission; platform configuration stays unchanged.
    if [ "$(awk '{print $4}' /sys/block/zram0/mm_stat)" != "$ZR_OLD_MEM_LIMIT" ]; then
        printf '%s\n' "$ZR_OLD_MEM_LIMIT" > /sys/block/zram0/mem_limit || return 1
    fi
    if [ "$(cat /sys/block/zram0/writeback_limit)" != "$ZR_OLD_WB_LIMIT" ]; then
        printf '%s\n' "$ZR_OLD_WB_LIMIT" > /sys/block/zram0/writeback_limit || return 1
    fi
    if [ "$(cat /sys/block/zram0/writeback_limit_enable)" != "$ZR_OLD_WB_ENABLE" ]; then
        printf '%s\n' "$ZR_OLD_WB_ENABLE" > /sys/block/zram0/writeback_limit_enable || return 1
    fi
    [ "$(cat /sys/block/zram0/writeback_limit)" = "$ZR_OLD_WB_LIMIT" ] \
        && [ "$(cat /sys/block/zram0/writeback_limit_enable)" = "$ZR_OLD_WB_ENABLE" ] \
        && [ "$(awk '{print $4}' /sys/block/zram0/mm_stat)" = "$ZR_OLD_MEM_LIMIT" ] || return 1
    if [ "$ZR_OLD_BACKING" != none ]; then
        [ "$(cat /sys/block/zram0/backing_dev)" != none ] \
            && [ "$(vm_zram_property_value mmd.status.zram.writeback.device_size)" = "$ZR_OLD_BACKING_SIZE" ] || return 1
    fi
}

zram_runtime_start_mmd() {
    setprop ctl.start mmd && zram_runtime_wait_service running
}

zram_runtime_snapshot() {
    ZR_OLD_REQUEST=$(vm_zram_read_requested_size)
    ZR_OLD_DISKSIZE=$(vm_zram_read_disksize)
    ZR_OLD_ALGORITHM=$(vm_zram_read_algorithm)
    ZR_OLD_PERSIST=$(vm_zram_property_value "$VM_ZRAM_SIZE_PROPERTY")
    ZR_OLD_MEM_LIMIT=$(awk '{print $4}' /sys/block/zram0/mm_stat)
    ZR_OLD_WB_LIMIT=$(cat /sys/block/zram0/writeback_limit)
    ZR_OLD_WB_ENABLE=$(cat /sys/block/zram0/writeback_limit_enable)
    ZR_OLD_BACKING=$(cat /sys/block/zram0/backing_dev)
    ZR_OLD_BACKING_SIZE=$(vm_zram_property_value mmd.status.zram.writeback.device_size)
    vm_zram_capacity_matches "$ZR_OLD_REQUEST" && vm_zram_algorithm_valid "$ZR_OLD_ALGORITHM" || return 1
    for _zr_snapshot_number in "$ZR_OLD_DISKSIZE" "$ZR_OLD_MEM_LIMIT" "$ZR_OLD_WB_LIMIT" "$ZR_OLD_WB_ENABLE"; do
        case "$_zr_snapshot_number" in ''|*[!0-9]*) return 1 ;; esac
    done
    state_atomic_write "$ZR_BASELINE" "schema=2
id=$ZR_ID
boot_id=$ZR_BOOT
fingerprint=$(getprop ro.build.fingerprint)
live_size=$ZR_OLD_REQUEST
size=$ZR_OLD_DISKSIZE
algorithm=$ZR_OLD_ALGORITHM
persistent_size=$ZR_OLD_PERSIST
mem_limit=$ZR_OLD_MEM_LIMIT
writeback_limit=$ZR_OLD_WB_LIMIT
writeback_limit_enable=$ZR_OLD_WB_ENABLE
backing=$ZR_OLD_BACKING
backing_size=$ZR_OLD_BACKING_SIZE"
}

zram_runtime_load_snapshot() {
    [ "$(vm_zram_state_field boot_id "$ZR_BASELINE")" = "$(vm_zram_current_boot_id)" ] \
        && [ "$(vm_zram_state_field fingerprint "$ZR_BASELINE")" = "$(getprop ro.build.fingerprint)" ] || return 1
    ZR_OLD_REQUEST=$(vm_zram_state_field live_size "$ZR_BASELINE")
    ZR_OLD_DISKSIZE=$(vm_zram_state_field size "$ZR_BASELINE")
    ZR_OLD_ALGORITHM=$(vm_zram_state_field algorithm "$ZR_BASELINE")
    ZR_OLD_PERSIST=$(vm_zram_state_field persistent_size "$ZR_BASELINE")
    ZR_OLD_MEM_LIMIT=$(vm_zram_state_field mem_limit "$ZR_BASELINE")
    ZR_OLD_WB_LIMIT=$(vm_zram_state_field writeback_limit "$ZR_BASELINE")
    ZR_OLD_WB_ENABLE=$(vm_zram_state_field writeback_limit_enable "$ZR_BASELINE")
    ZR_OLD_BACKING=$(vm_zram_state_field backing "$ZR_BASELINE")
    ZR_OLD_BACKING_SIZE=$(vm_zram_state_field backing_size "$ZR_BASELINE")
}

zram_runtime_recovery_owned() {
    local live_size live_algorithm actual_state actual_size actual_algorithm
    live_size=$(vm_zram_read_requested_size)
    live_algorithm=$(vm_zram_read_requested_algorithm)
    if [ "$live_size:$live_algorithm" != "$ZR_OLD_REQUEST:$ZR_OLD_ALGORITHM" ] \
        && [ "$live_size:$live_algorithm" != "$ZR_RECOVERY_SIZE:$ZR_RECOVERY_ALGORITHM" ]; then return 1; fi
    actual_state=$(vm_zram_active_state)
    actual_size=$(vm_zram_read_disksize)
    actual_algorithm=$(vm_zram_read_algorithm)
    case "$actual_state" in
        active)
            { vm_zram_capacity_matches "$ZR_OLD_DISKSIZE" && [ "$actual_algorithm" = "$ZR_OLD_ALGORITHM" ]; } \
                || { vm_zram_capacity_matches "$ZR_RECOVERY_SIZE" && [ "$actual_algorithm" = "$ZR_RECOVERY_ALGORITHM" ]; }
            ;;
        inactive)
            [ "$actual_size" = 0 ] \
                || { [ "$actual_size" = "$ZR_OLD_DISKSIZE" ] && [ "$actual_algorithm" = "$ZR_OLD_ALGORITHM" ]; } \
                || { [ "$actual_size" = "$(vm_zram_size_to_bytes "$ZR_RECOVERY_SIZE")" ] && [ "$actual_algorithm" = "$ZR_RECOVERY_ALGORITHM" ]; }
            ;;
        *) return 1 ;;
    esac
}

zram_runtime_rollback() {
    ZR_PHASE=rollback; zram_runtime_commit || true
    if [ "$ZR_DEVICE_TOUCHED" != true ]; then
        vm_zram_matches "$ZR_OLD_ALGORITHM" "$ZR_OLD_DISKSIZE" && zram_runtime_start_mmd
        return $?
    fi
    _zr_rollback_live=$(vm_zram_read_requested_size)
    [ "$_zr_rollback_live" = "$ZR_SIZE" ] || [ "$_zr_rollback_live" = "$ZR_OLD_REQUEST" ] || return 1
    setprop ctl.stop mmd && zram_runtime_wait_service stopped || return 1
    if vm_zram_is_active; then zram_runtime_memory_ready && swapoff /dev/block/zram0 || return 1; fi
    zram_runtime_properties "$ZR_OLD_REQUEST" "$ZR_OLD_ALGORITHM" \
        && zram_runtime_build "$ZR_OLD_REQUEST" "$ZR_OLD_ALGORITHM" \
        && zram_runtime_start_mmd
}

memory_init() {
    vm_zram_init_limits && memory_config_init "$1" && zram_runtime_init "$1"
}
