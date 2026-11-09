#!/system/bin/sh
# Exercise the production worker's ordering with isolated, non-device adapters.
SOURCE_ROOT="$1"
WORK="$2"
mkdir -p "$WORK/scripts" || exit 2
cp "$SOURCE_ROOT/scripts/memory_lib.sh" "$WORK/scripts/memory_lib.sh" \
    && cp "$SOURCE_ROOT/scripts/memory_worker.sh" "$WORK/scripts/memory_worker.sh" || exit 2
cat >> "$WORK/scripts/memory_lib.sh" <<'FIXTURE'
memory_init() { ZR_ROOT="$1"; }
zram_runtime_load() {
    ZR_ID=fixture; ZR_BOOT=$(vm_zram_current_boot_id); ZR_PHASE=queued
    ZR_SIZE='50%'; ZR_ALGORITHM=lz77eh; ZR_KIND=preset
}
vm_zram_size_is_valid() { return 0; }
vm_zram_algorithm_valid() { return 0; }
module_lock_write_owner() { return 0; }
state_lock_release() { return 0; }
vm_current_params() { printf '60 27386 200 100'; }
zram_runtime_commit() { printf 'phase=%s\n' "$ZR_PHASE" >> "$FX_DIR/events"; }
zram_runtime_capability() { ZR_CAPABLE=true; [ "$FX_CASE" != deferred ] || ZR_CAPABLE=false; ZR_CAPABILITY_REASON=fixture_pressure; }
zram_runtime_snapshot() { ZR_OLD_PERSIST='60%'; ZR_OLD_REQUEST='60%'; ZR_OLD_ALGORITHM=lz77eh; ZR_OLD_DISKSIZE=1000; }
setprop() { printf 'property=%s\n' "$1" >> "$FX_DIR/events"; }
zram_runtime_wait_service() { return 0; }
zram_runtime_memory_ready() { return 0; }
zram_runtime_pressure_ready() { return 0; }
vm_zram_property_value() { printf '60%%'; }
vm_zram_is_active() { [ "$(cat "$FX_DIR/active")" = yes ]; }
swapoff() { printf swapoff >> "$FX_DIR/events"; printf no > "$FX_DIR/active"; }
vm_zram_active_state() { [ "$(cat "$FX_DIR/active")" = yes ] && printf active || printf inactive; }
zram_runtime_properties() { return 0; }
zram_runtime_build() { [ "$FX_CASE" != build_failed ]; }
zram_runtime_start_mmd() { return 0; }
vm_zram_capacity_matches() { return 0; }
vm_zram_read_algorithm() { printf lz77eh; }
vm_zram_read_requested_size() { printf '60%%'; }
vm_zram_read_requested_algorithm() { printf lz77eh; }
vm_zram_matches() { return 0; }
vm_zram_read_swap_total_kb() { printf 1000; }
memory_original_params() { printf '60 27386 200 100'; }
vm_preset_params() { printf '80 65536 200 100'; }
memory_apply_vm() {
    printf 'vm=%s,%s\n' "$1" "$5" >> "$FX_DIR/events"
    [ "$FX_CASE:$5" != vm_failed:preset ]
}
zram_runtime_rollback() { printf 'rollback=zram\n' >> "$FX_DIR/events"; return 0; }
log() { return 0; }
FIXTURE
PASS=0; FAIL=0
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok - %s\n' "$1"
    else FAIL=$((FAIL+1)); printf 'not ok - %s expected=%s actual=%s\n' "$1" "$2" "$3"; fi
}
for scenario in success deferred build_failed vm_failed; do
    FX_DIR="$WORK/$scenario"; mkdir -p "$FX_DIR" || exit 2
    : > "$FX_DIR/events"; printf yes > "$FX_DIR/active"
    FX_CASE="$scenario"; export FX_DIR FX_CASE
    /system/bin/sh "$WORK/scripts/memory_worker.sh" "$WORK" fixture
    result=$?
    phase=$(sed -n 's/^phase=//p' "$FX_DIR/events" | tail -1)
    case "$scenario" in
        success) check 'worker commits success after readback' success "$phase"; check 'success exit code' 0 "$result" ;;
        deferred) check 'preflight rejection has no device write' 0 "$(grep -c '^property=' "$FX_DIR/events")"; check 'preflight reports deferred' deferred "$phase" ;;
        build_failed) check 'setup failure restores prior swap' rollback_complete "$phase"; check 'rollback handler is called' 1 "$(grep -c '^rollback=zram' "$FX_DIR/events")" ;;
        vm_failed) check 'VM failure restores swap' rollback_complete "$phase"; check 'VM rollback executes in exit handler' 1 "$(grep -c '^vm=60,rollback' "$FX_DIR/events")" ;;
    esac
done
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
