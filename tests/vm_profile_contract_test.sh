#!/system/bin/sh

SOURCE_ROOT="$1"
LIB="$SOURCE_ROOT/scripts/vm_profile_lib.sh"
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

check_eq 'optimized profile params' '100 131072 200 60' "$(vm_profile_params optimized)"
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
    *'"zram_target":{"algorithm":"lz77eh","size_bytes":11945377792}'*) check_eq 'ZRAM target is exported' yes yes ;;
    *) check_eq 'ZRAM target is exported' yes no ;;
esac
_vm_contract_complete=yes
case "$_contract" in *'"optimized"'*) ;; *) _vm_contract_complete=no ;; esac
case "$_contract" in *'"stock"'*) ;; *) _vm_contract_complete=no ;; esac
case "$_contract" in *'"limits"'*) ;; *) _vm_contract_complete=no ;; esac
check_eq 'VM profiles and limits are exported' yes "$_vm_contract_complete"

printf '1..%s\n' "$TOTAL"
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
