#!/system/bin/sh

# Exercise the production request parser without invoking any thermal writes.
MOD="${1:-${0%/tests/*}}"
PARSER=$(sed -n '/^parse_thermal_json() {/,/^}/p; /^thermal_json_field() {/,/^}/p' "$MOD/webroot/cgi-bin/set_thermal.sh")
[ -n "$PARSER" ] || exit 2
eval "$PARSER"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$((PASS + FAIL))" "$1"; }
not_ok() { FAIL=$((FAIL + 1)); printf 'not ok %s - %s\n' "$((PASS + FAIL))" "$1"; }
valid() {
    if parse_thermal_json "$2" && [ "$(thermal_json_field "$3")" = "$4" ]; then
        ok "$1"
    else
        not_ok "$1"
    fi
}
invalid() {
    if parse_thermal_json "$2"; then
        not_ok "$1"
    elif [ -z "$THERMAL_JSON_FIELDS" ]; then
        ok "$1"
    else
        not_ok "$1 (partial fields escaped failed parse)"
    fi
}
for offset in -2 0 2 4 6; do
    valid "integer offset $offset" "{\"offset\":$offset}" offset "$offset"
done
valid 'custom policy with whitespace and arbitrary field order' '
 { "offset" : 2, "policy" : "custom" }
' policy custom
valid 'system policy without offset' '{"policy":"system"}' policy system
valid 'repair action' '{"action":"repair_system"}' action repair_system
valid 'cancel action and exact pending id' '{"pending_id":"123.456","action":"cancel_pending"}' pending_id 123.456
invalid 'fraction is not an integer offset' '{"offset":2.5}'
invalid 'exponent is not an integer offset' '{"offset":2e3}'
invalid 'garbage after number' '{"offset":2garbage}'
invalid 'duplicate offset' '{"offset":2,"offset":4}'
invalid 'nested offset' '{"nested":{"offset":4}}'
invalid 'array offset' '{"offset":[2]}'
invalid 'string offset' '{"offset":"2"}'
invalid 'boolean offset' '{"offset":true}'
invalid 'null offset' '{"offset":null}'
invalid 'leading zero' '{"offset":02}'
invalid 'plus sign' '{"offset":+2}'
invalid 'missing offset value' '{"offset":}'
invalid 'trailing comma' '{"offset":2,}'
invalid 'missing comma' '{"offset":2 "policy":"custom"}'
invalid 'trailing body' '{"offset":2}{}'
invalid 'unterminated object' '{"offset":2'
invalid 'escaped key' '{"off\u0073et":2}'
invalid 'duplicate action cannot shadow repair' '{"action":"repair_system","action":"cancel_pending"}'
invalid 'duplicate policy' '{"policy":"custom","policy":"system"}'
invalid 'nested action' '{"action":{"action":"repair_system"}}'
invalid 'untyped policy' '{"policy":2}'
invalid 'escaped pending id' '{"pending_id":"123\u002e456"}'
invalid 'unknown field' '{"offset":2,"other":4}'
invalid 'empty request' '{}'
invalid 'pending id without an action' '{"pending_id":"123.456"}'
invalid 'action cannot mix desired policy fields' '{"action":"repair_system","offset":2}'
printf 'thermal request contracts: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
