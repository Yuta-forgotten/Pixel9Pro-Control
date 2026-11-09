#!/system/bin/sh
SOURCE_ROOT="$1"
. "$SOURCE_ROOT/scripts/memory_lib.sh" || exit 2
PASS=0; FAIL=0
expect() {
    local result=no
    zram_runtime_recovery_owned && result=yes
    if [ "$result" = "$2" ]; then PASS=$((PASS+1)); printf 'ok - %s\n' "$1"
    else FAIL=$((FAIL+1)); printf 'not ok - %s expected=%s actual=%s\n' "$1" "$2" "$result"; fi
}
ZR_OLD_REQUEST=1000; ZR_OLD_DISKSIZE=1000; ZR_OLD_ALGORITHM=lz77eh
ZR_RECOVERY_SIZE=2000; ZR_RECOVERY_ALGORITHM=lz4
vm_zram_read_requested_size() { printf '%s' "$LIVE_SIZE"; }
vm_zram_read_requested_algorithm() { printf '%s' "$LIVE_ALGO"; }
vm_zram_active_state() { printf '%s' "$ACTIVE"; }
vm_zram_read_disksize() { printf '%s' "$ACTUAL_SIZE"; }
vm_zram_read_algorithm() { printf '%s' "$ACTUAL_ALGO"; }
vm_zram_capacity_matches() { [ "$ACTIVE" = active ] && [ "$ACTUAL_SIZE" = "$1" ]; }
vm_zram_size_to_bytes() { printf '%s' "$1"; }
ACTIVE=active;LIVE_SIZE=1000;LIVE_ALGO=lz77eh;ACTUAL_SIZE=1000;ACTUAL_ALGO=lz77eh
expect 'recovery recognizes original owned configuration' yes
LIVE_SIZE=2000;LIVE_ALGO=lz4;ACTUAL_SIZE=2000;ACTUAL_ALGO=lz4
expect 'recovery recognizes interrupted target configuration' yes
LIVE_SIZE=3000;LIVE_ALGO=zstd;ACTUAL_SIZE=3000;ACTUAL_ALGO=zstd
expect 'recovery preserves a third-party replacement' no
LIVE_SIZE=2000;LIVE_ALGO=lz4;ACTUAL_SIZE=3000;ACTUAL_ALGO=zstd
expect 'unchanged request does not authorize resetting a different active device' no
ACTIVE=inactive;ACTUAL_SIZE=0;ACTUAL_ALGO=lz4
expect 'owned reset device can be recovered' yes
ACTUAL_SIZE=1500
expect 'unknown partial device is not overwritten' no
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
