#!/system/bin/sh
SOURCE_ROOT="$1"
WORK="$2"
MODDIR="$WORK"
. "$SOURCE_ROOT/scripts/state_io_lib.sh" \
    && . "$SOURCE_ROOT/scripts/memory_lib.sh" \
    && memory_config_init "$WORK" || exit 2
vm_zram_init_limits || exit 2
PASS=0; FAIL=0; SDK=37
rm -f "$MC_STAGE" "$MC_BASELINE" "$MC_RESULT" "$WORK/property-ledger"
# Shared /sdcard scratch has FUSE mode 0660. This fixture checks configuration
# semantics with a data-only storage adapter; production state_io permissions
# are verified separately in the installed module's private directory.
state_atomic_write() {
    printf '%s' "$2" > "$1" && [ "$(cat "$1")" = "$2" ]
}
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok - %s\n' "$1"
    else FAIL=$((FAIL+1)); printf 'not ok - %s expected=%s actual=%s\n' "$1" "$2" "$3"; fi
}
getprop() {
    case "$1" in
        ro.build.version.sdk) printf '%s' "$SDK" ;;
        ro.build.fingerprint) printf fixture-build ;;
        ro.persistent_properties.ready) printf true ;;
        mmd.zram.size) cat "$WORK/live-size" ;;
        mmd.zram.comp_algorithm) cat "$WORK/live-algorithm" ;;
    esac
}
setprop() {
    printf '%s=%s\n' "$1" "$2" >> "$WORK/property-ledger"
    case "$1" in mmd.zram.size) printf '%s' "$2" > "$WORK/live-size" ;;
        mmd.zram.comp_algorithm) printf '%s' "$2" > "$WORK/live-algorithm" ;; esac
}
vm_zram_current_boot_id() { printf fixture-boot; }
vm_zram_active_state() { printf inactive; }
vm_zram_vendor_alias_supported() { return 0; }
vm_zram_algorithm_valid() { [ "$1" = lz77eh ] || [ "$1" = lz4 ]; }
vm_zram_read_requested_size() { getprop mmd.zram.size; }
vm_zram_property_value() { getprop "$1"; }
vm_current_params() { printf '60 27386 200 100'; }
printf '60%%' > "$WORK/live-size"
printf lz77eh > "$WORK/live-algorithm"
MC_AUTO=off; MC_VM=off; MC_SIZE='50%'; MC_ALGORITHM=lz77eh
MC_SW=80; MC_MFK=65536; MC_WSF=200; MC_VCP=100
memory_config_save || exit 2
check 'saving does not enable automatic application' off "$(vm_zram_state_field auto_apply "$MC_CONFIG")"
check 'saving does not alter live capacity' '60%' "$(cat "$WORK/live-size")"
memory_boot_prepare || exit 2
check 'auto off makes no property writes' no "$( [ -e "$WORK/property-ledger" ] && printf yes || printf no )"
# Reset only owned fixture state between simulated boots.
rm -f "$MC_STAGE" "$MC_BASELINE"
MC_AUTO=on; memory_config_save || exit 2
memory_boot_prepare || exit 2
check 'auto on submits capacity before initial setup' '50%' "$(cat "$WORK/live-size")"
check 'auto on does not mutate persistent vendor alias' 0 "$(grep -c '^persist[.]' "$WORK/property-ledger")"
count=$(wc -l < "$WORK/property-ledger" | tr -d ' ')
memory_boot_prepare || exit 2
check 'boot preparation runs once per boot' "$count" "$(wc -l < "$WORK/property-ledger" | tr -d ' ')"
check 'baseline keeps platform request separate' '60%' "$(vm_zram_state_field size "$MC_BASELINE")"
MC_AUTO=off; memory_config_save || exit 2
check 'turning auto off leaves current temporary capacity unchanged' '50%' "$(cat "$WORK/live-size")"
check 'turning auto off keeps saved capacity available' '50%' "$(vm_zram_state_field size "$MC_CONFIG")"
rm -f "$MC_STAGE" "$WORK/property-ledger"
MC_AUTO=on; memory_config_save || exit 2
printf '60%%' > "$WORK/live-size"
printf lz77eh > "$WORK/live-algorithm"
state_atomic_write() {
    [ "$1" != "$MC_STAGE" ] || return 1
    printf '%s' "$2" > "$1" && [ "$(cat "$1")" = "$2" ]
}
if memory_boot_prepare; then check 'failed marker prevents successful boot submission' failure success
else check 'failed marker prevents successful boot submission' failure failure; fi
check 'failed boot marker restores the actual original request' '60%' "$(cat "$WORK/live-size")"
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
