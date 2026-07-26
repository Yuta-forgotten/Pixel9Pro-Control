#!/system/bin/sh

SOURCE_ROOT="$1"
TEST_ROOT="$2"
LIB="$SOURCE_ROOT/scripts/thermal_profile.sh"
STOCK="$SOURCE_ROOT/system/vendor/etc/thermal_stock.json"
STOCK_XL="$SOURCE_ROOT/system/vendor/etc/thermal_stock_xl.json"

PASS=0
FAIL=0
TOTAL=0

ok() {
    TOTAL=$((TOTAL + 1))
    PASS=$((PASS + 1))
    printf 'ok %s - %s\n' "$TOTAL" "$1"
}

not_ok() {
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    printf 'not ok %s - %s\n' "$TOTAL" "$1"
}

assert_eq() {
    _name="$1"
    _expected="$2"
    _actual="$3"
    if [ "$_expected" = "$_actual" ]; then
        ok "$_name"
    else
        not_ok "$_name (expected=$_expected actual=$_actual)"
    fi
}

hot_threshold_values() {
    awk -v target="$2" '
        /"Name":/ {
            name = $0
            sub(/.*"Name": *"/, "", name)
            sub(/".*/, "", name)
        }
        name == target && /"HotThreshold"/ && /\[/ && /\]/ {
            line=$0
            sub(/^[^[]*\[/, "", line)
            sub(/\].*$/, "", line)
            count=split(line, values, ",")
            for (i=1; i<=count; i++) {
                value=values[i]
                gsub(/[ \t]/, "", value)
                print value
            }
            exit
        }
        name == target && /"HotThreshold"/ { in_hot = 1; next }
        in_hot && /\]/ { exit }
        in_hot {
            value = $0
            gsub(/[ ,\t]/, "", value)
            print value
        }
    ' "$1"
}

first_hot_threshold() {
    hot_threshold_values "$1" "$2" | awk '
        /^-?[0-9]+([.][0-9]+)?$/ { print $0 + 0; exit }
    '
}

hot_threshold_slot_raw() {
    hot_threshold_values "$1" "$2" | sed -n "${3}p"
}

hot_threshold_slot() {
    _slot_value=$(hot_threshold_slot_raw "$1" "$2" "$3")
    case "$_slot_value" in
        ''|'"NAN"') return 1 ;;
        *) awk -v value="$_slot_value" 'BEGIN { print value + 0 }' ;;
    esac
}

assert_target_thresholds_ordered() {
    _ordered=yes
    for _ordered_sensor in VIRTUAL-SKIN VIRTUAL-SKIN-HINT VIRTUAL-SKIN-SOC \
        VIRTUAL-SKIN-CPU-LIGHT-ODPM VIRTUAL-SKIN-CPU-MID VIRTUAL-SKIN-CPU-ODPM \
        VIRTUAL-SKIN-CPU-HIGH VIRTUAL-SKIN-GPU; do
        _ordered_values=$(hot_threshold_values "$1" "$_ordered_sensor")
        [ "$(printf '%s\n' "$_ordered_values" | wc -l | tr -d ' ')" = 7 ] || _ordered=no
        printf '%s\n' "$_ordered_values" | awk '
            /^-?[0-9]+([.][0-9]+)?$/ {
                numeric=$0+0
                if (set && numeric <= previous) exit 1
                previous=numeric
                set=1
            }
        ' || _ordered=no
    done
    if [ "$_ordered" = yes ]; then
        ok "$2"
    else
        not_ok "$2"
    fi
}

mkdir -p "$TEST_ROOT" || exit 2
. "$LIB" || exit 2
printf 'TAP version 13\n'

assert_eq 'normalizes invalid offset to module default' 4 "$(thermal_normalize_offset 8 4)"
if thermal_is_valid_offset 6; then
    ok 'accepts +6 offset'
else
    not_ok 'accepts +6 offset'
fi

for _variant in pro xl; do
    case "$_variant" in pro) _stock="$STOCK" ;; xl) _stock="$STOCK_XL" ;; esac
    for _offset in -2 0 2 4 6; do
        _out="$TEST_ROOT/thermal_${_variant}_${_offset}.json"
        if thermal_generate_config "$_stock" "$_out" "$_offset"; then
            ok "generates $_variant offset $_offset"
        else
            not_ok "generates $_variant offset $_offset"
            continue
        fi
        assert_target_thresholds_ordered "$_out" "$_variant offset $_offset remains strictly ordered"
        for _sensor in VIRTUAL-SKIN VIRTUAL-SKIN-HINT VIRTUAL-SKIN-SOC; do
            _shutdown=$(hot_threshold_slot_raw "$_stock" "$_sensor" 7)
            case "$_shutdown" in
                NAN|'"NAN"'|'') ;;
                *) assert_eq "$_variant $_sensor shutdown $_offset" "$_shutdown" "$(hot_threshold_slot_raw "$_out" "$_sensor" 7)" ;;
            esac
        done
        if [ "$_variant" = "pro" ]; then
            assert_eq "VIRTUAL-SKIN first threshold $_offset" "$((39 + _offset))" "$(first_hot_threshold "$_out" VIRTUAL-SKIN)"
            assert_eq "HINT first threshold $_offset" "$((37 + _offset))" "$(first_hot_threshold "$_out" VIRTUAL-SKIN-HINT)"
            assert_eq "CPU-HIGH first threshold $_offset" "$((41 + _offset))" "$(first_hot_threshold "$_out" VIRTUAL-SKIN-CPU-HIGH)"
            case "$_offset" in
                -2) _skin_slot6=50; _soc_slot6=54 ;;
                0)  _skin_slot6=52; _soc_slot6=56 ;;
                2)  _skin_slot6=54; _soc_slot6=58 ;;
                4|6) _skin_slot6=54.5; _soc_slot6=58.5 ;;
            esac
            assert_eq "VIRTUAL-SKIN slot 6 remains ordered $_offset" "$_skin_slot6" "$(hot_threshold_slot "$_out" VIRTUAL-SKIN 6)"
            assert_eq "SOC slot 6 remains ordered $_offset" "$_soc_slot6" "$(hot_threshold_slot "$_out" VIRTUAL-SKIN-SOC 6)"
        fi
    done
done

_invalid_out="$TEST_ROOT/thermal_invalid.json"
if thermal_generate_config "$STOCK" "$_invalid_out" 8; then
    not_ok 'generation rejects unknown +8 offset'
else
    ok 'generation rejects unknown +8 offset'
fi

printf '1..%s\n' "$TOTAL"
printf '# pass=%s fail=%s root=%s\n' "$PASS" "$FAIL" "$TEST_ROOT"
[ "$FAIL" -eq 0 ]
