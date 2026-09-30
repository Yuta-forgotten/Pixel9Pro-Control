#!/system/bin/sh

SOURCE_ROOT="$1"
LIB="$SOURCE_ROOT/scripts/vm_profile_lib.sh"
SERVICE="$SOURCE_ROOT/service.sh"
PASS=0
FAIL=0
TOTAL=0

check_eq() {
    TOTAL=$((TOTAL + 1))
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
        printf 'ok %s - %s\n' "$TOTAL" "$1"
    else
        FAIL=$((FAIL + 1))
        printf 'not ok %s - %s expected=%s actual=%s\n' "$TOTAL" "$1" "$2" "$3"
    fi
}

. "$LIB" || exit 2
printf 'TAP version 13\n'

check_eq 'optimized profile params' '100 65536 100 100' "$(vm_profile_params optimized)"
check_eq 'stock profile params' '150 27386 50 100' "$(vm_profile_params stock)"
if vm_is_uint_range 200 "$VM_SWAPPINESS_MIN" "$VM_SWAPPINESS_MAX"; then
    check_eq 'upper swappiness limit accepted' yes yes
else
    check_eq 'upper swappiness limit accepted' yes no
fi
if vm_is_uint_range 201 "$VM_SWAPPINESS_MIN" "$VM_SWAPPINESS_MAX"; then
    check_eq 'out-of-range swappiness rejected' yes no
else
    check_eq 'out-of-range swappiness rejected' yes yes
fi
_contract=$(vm_contract_json)
case "$_contract" in
    *'"zram_target":{"algorithm":"lz77eh","size_bytes":0'*'policy":"explicit_user_request_only"'*) check_eq 'ZRAM target and ownership policy are exported' yes yes ;;
    *) check_eq 'ZRAM target and ownership policy are exported' yes no ;;
esac
_vm_contract_complete=yes
case "$_contract" in *'"optimized"'*) ;; *) _vm_contract_complete=no ;; esac
case "$_contract" in *'"stock"'*) ;; *) _vm_contract_complete=no ;; esac
case "$_contract" in *'"limits"'*) ;; *) _vm_contract_complete=no ;; esac
check_eq 'VM profiles and limits are exported' yes "$_vm_contract_complete"

if grep -Fq 'system|stock|disabled)' "$SERVICE" \
    && grep -Fq 'no VM or ZRAM write' "$SERVICE" \
    && grep -Fq 'optimized)' "$SERVICE"; then
    check_eq 'system mode is observe-only and optimized mode is explicit' yes yes
else
    check_eq 'system mode is observe-only and optimized mode is explicit' yes no
fi

# Run the production matcher with read-only node fixtures, rather than matching
# an escaped awk source string. These overrides never write sysfs/procfs.
if (
    VM_FIXTURE_SIZE_BYTES=8153493504
    cat() {
        case "$1" in
            /sys/block/zram0/comp_algorithm) printf 'lz4 [lz77eh]\n' ;;
            /sys/block/zram0/disksize) printf '%s\n' "$VM_FIXTURE_SIZE_BYTES" ;;
            *) command cat "$@" ;;
        esac
    }
    awk() {
        if [ "$2" = /proc/swaps ]; then
            { printf 'Filename Type Size Used Priority\n'; [ "$VM_FIXTURE_ACTIVE" = yes ] && printf '/dev/block/zram0 partition 1000 0 -2\n'; } | command awk "$1"
        else command awk "$@"; fi
    }
    VM_FIXTURE_ACTIVE=no
    ! vm_zram_matches "$VM_ZRAM_ALGO" "$VM_FIXTURE_SIZE_BYTES" || exit 1
    VM_FIXTURE_ACTIVE=yes
    vm_zram_matches "$VM_ZRAM_ALGO" "$VM_FIXTURE_SIZE_BYTES" || exit 1
    ! vm_zram_matches wrong "$VM_FIXTURE_SIZE_BYTES"
); then
    check_eq 'production matcher rejects inactive swap and wrong algorithm' yes yes
else
    check_eq 'production matcher rejects inactive swap and wrong algorithm' yes no
fi

printf '1..%s\n' "$TOTAL"
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
