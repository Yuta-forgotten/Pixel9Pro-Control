#!/system/bin/sh
# Focused fixtures in caller-provided controlled scratch. No system writes.
SOURCE_ROOT="$1"
WORK="$2"
[ -d "$WORK" ] || exit 2
MODDIR="$WORK"
. "$SOURCE_ROOT/scripts/state_io_lib.sh" || exit 2
. "$SOURCE_ROOT/scripts/memory_lib.sh" || exit 2
vm_zram_init_limits || exit 2
PASS=0
FAIL=0
check_eq() {
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok - %s\n' "$1"
    else FAIL=$((FAIL+1)); printf 'not ok - %s expected=%s actual=%s\n' "$1" "$2" "$3"; fi
}
SDK_FIXTURE=37
getprop() {
    case "$1" in
        ro.build.version.sdk) printf '%s' "$SDK_FIXTURE" ;;
        ro.build.fingerprint) printf fixture-build ;;
        mmd.zram.enabled|mmd.setup_complete) printf true ;;
        init.svc.mmd) printf running ;;
        mmd.zram.num_devices) printf 1 ;;
    esac
}
vm_zram_current_boot_id() { printf fixture-boot; }
vm_current_params() { printf '60 27386 200 100'; }
vm_zram_mem_total_bytes() { printf 16332042240; }
vm_zram_vendor_alias_supported() { return 0; }
vm_capture_baseline || exit 2
check_eq 'system restore uses the observed boot baseline' '60 27386 200 100' "$(vm_baseline_params)"
if vm_zram_mmd_ready; then check_eq 'mmd readiness without removed aconfig property' yes yes
else check_eq 'mmd readiness without removed aconfig property' yes no; fi
SDK_FIXTURE=36
if vm_zram_target_supported; then check_eq 'API 36 disables MMD capacity mutation' no yes
else check_eq 'API 36 disables MMD capacity mutation' no no; fi
SDK_FIXTURE=37
VM_ZRAM_SIZE_STEP_BYTES=4096
check_eq 'percentage conversion on page boundary' 8166019072 "$(vm_zram_size_to_bytes '50%')"
vm_zram_is_active() { return 0; }
vm_zram_read_disksize() { printf '%s' "$SIZE_FIXTURE"; }
SIZE_FIXTURE=8166023168
if vm_zram_capacity_matches '50%'; then check_eq 'percentage round-up by one page' yes yes
else check_eq 'percentage round-up by one page' yes no; fi
SIZE_FIXTURE=8166027264
if vm_zram_capacity_matches '50%'; then check_eq 'larger mismatch rejected' no yes
else check_eq 'larger mismatch rejected' no no; fi
VM_ZRAM_SIZE_STEP_BYTES=16384
check_eq '16KiB kernel alignment' 1500004352 "$(vm_zram_normalize_capacity 1500 mb)"
if vm_zram_size_is_valid 1500000256; then check_eq '4KiB alignment rejected on 16KiB kernel' no yes
else check_eq '4KiB alignment rejected on 16KiB kernel' no no; fi
if vm_zram_normalize_capacity 1500.123 mb >/dev/null; then check_eq 'overprecision rejected before writes' no yes
else check_eq 'overprecision rejected before writes' no no; fi
vm_zram_is_active() { return 1; }
vm_zram_read_algorithm() { printf lz77eh; }
SIZE_FIXTURE=1500004352
if vm_zram_matches lz77eh 1500004352; then check_eq 'inactive swap is not a match' no yes
else check_eq 'inactive swap is not a match' no no; fi
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
