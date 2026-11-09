#!/system/bin/sh
SOURCE_ROOT="$1"
WORK="$2"
mkdir -p "$WORK" || exit 2
sed -n '/^cgi_parse_json() {/,/^}/p' "$SOURCE_ROOT/webroot/cgi-bin/_common.sh" > "$WORK/parser.sh"
sed -n '/^parse_memory_fields() {/,/^request_size() {/p' "$SOURCE_ROOT/webroot/cgi-bin/swap.sh" | sed '$d' >> "$WORK/parser.sh"
. "$WORK/parser.sh" || exit 2
PASS=0; FAIL=0
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok - %s\n' "$1"
    else FAIL=$((FAIL+1)); printf 'not ok - %s expected=%s actual=%s\n' "$1" "$2" "$3"; fi
}
parse() { cgi_parse_json "$1" && parse_memory_fields; }
parse '{"mode":"boot_save","algorithm":""}' || exit 2
check 'empty optional compressor is preserved' '' "$(field algorithm)"
parse '{"auto_apply":"off","mode":"boot_save"}' || exit 2
check 'field order does not change auto-off meaning' off "$(field auto_apply)"
check 'auto-off request has exactly two fields' 2 "$REQUEST_FIELD_COUNT"
parse '{"mode":"custom","swappiness":80,"min_free_kbytes":65536,"watermark_scale_factor":200,"vfs_cache_pressure":100}' || exit 2
check 'numeric VM input retains integer value' 65536 "$(field min_free_kbytes)"
if parse '{"mode":"custom","mode":"boot_save"}'; then check 'duplicate keys rejected by common parser' rejected accepted
else check 'duplicate keys rejected by common parser' rejected rejected; fi
if parse '{"mode":"custom","unexpected":"value"}'; then check 'unsupported fields are rejected' rejected accepted
else check 'unsupported fields are rejected' rejected rejected; fi
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
