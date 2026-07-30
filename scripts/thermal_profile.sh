#!/system/bin/sh

# Shared thermal-offset contract for the installer and WebUI CGI.
#
# Current policy:
#   - accepted offsets: -2 / 0 / +2 / +4 / +6 degrees C; default: +4
#   - always regenerate from the selected device stock JSON
#   - adjust the eight VIRTUAL-SKIN control sensors only
#   - keep a numeric SHUTDOWN slot (the seventh HotThreshold entry) at stock
#   - clamp earlier entries against the next severity's stock HotHysteresis
#
# Pixel Thermal HAL rejects an earlier threshold above
# (next threshold - next HotHysteresis). See ParseSensorInfo in AOSP
# hardware/google/pixel/thermal/utils/thermal_info.cpp. A plain translation can
# overlap a fixed 55/59 shutdown severity, so higher offsets taper near it.

THERMAL_ALLOWED_OFFSETS="-2 0 2 4 6"
THERMAL_DEFAULT_OFFSET=4
THERMAL_TARGET_SENSORS="VIRTUAL-SKIN VIRTUAL-SKIN-HINT VIRTUAL-SKIN-SOC VIRTUAL-SKIN-CPU-LIGHT-ODPM VIRTUAL-SKIN-CPU-MID VIRTUAL-SKIN-CPU-ODPM VIRTUAL-SKIN-CPU-HIGH VIRTUAL-SKIN-GPU"
THERMAL_TARGET_SENSOR_COUNT=8
THERMAL_SEVERITY_SLOT_COUNT=7
THERMAL_SHUTDOWN_SLOT=7
THERMAL_MIN_SEVERITY_GAP_C=0.5

thermal_is_valid_offset() {
    _tp_candidate="$1"
    for _tp_allowed_offset in $THERMAL_ALLOWED_OFFSETS; do
        [ "$_tp_candidate" = "$_tp_allowed_offset" ] && return 0
    done
    return 1
}

thermal_normalize_offset() {
    _tp_value="$1"
    _tp_fallback="${2:-$THERMAL_DEFAULT_OFFSET}"
    thermal_is_valid_offset "$_tp_fallback" || _tp_fallback="$THERMAL_DEFAULT_OFFSET"
    if thermal_is_valid_offset "$_tp_value"; then
        printf '%s' "$_tp_value"
    else
        printf '%s' "$_tp_fallback"
    fi
}

thermal_print_ui_contract_json() {
    printf '{"offsets":['
    _tp_contract_first=1
    for _tp_contract_offset in $THERMAL_ALLOWED_OFFSETS; do
        [ "$_tp_contract_first" -eq 1 ] && _tp_contract_first=0 || printf ','
        printf '%s' "$_tp_contract_offset"
    done
    printf '],"default_offset":%s}' "$THERMAL_DEFAULT_OFFSET"
}

thermal_format_offset() {
    case "$1" in
        -2) printf '%s' '-2°C' ;;
        0)  printf '%s' '0°C' ;;
        2)  printf '%s' '+2°C' ;;
        4)  printf '%s' '+4°C' ;;
        6)  printf '%s' '+6°C' ;;
        *)  return 1 ;;
    esac
}

thermal_profile_name() {
    case "$1" in
        -2) printf '%s' '提前介入' ;;
        0)  printf '%s' '原厂阈值' ;;
        2)  printf '%s' '轻度放宽' ;;
        4)  printf '%s' '日常放宽' ;;
        6)  printf '%s' '最大放宽' ;;
        *)  return 1 ;;
    esac
}

thermal_generate_config() (
    _tp_stock="$1"
    _tp_out="$2"
    _tp_offset="$3"
    _tp_tmp="${_tp_out}.tmp.$$"

    [ -f "$_tp_stock" ] || return 10
    [ -n "$_tp_out" ] || return 11
    [ ! -d "$_tp_out" ] || return 11
    thermal_is_valid_offset "$_tp_offset" || return 12

    rm -f "$_tp_tmp" 2>/dev/null
    _tp_targets="|$(printf '%s' "$THERMAL_TARGET_SENSORS" | tr ' ' '|')|"
    awk -v off="$_tp_offset" -v targets="$_tp_targets" \
        -v expected_targets="$THERMAL_TARGET_SENSOR_COUNT" \
        -v severity_slots="$THERMAL_SEVERITY_SLOT_COUNT" \
        -v shutdown_slot="$THERMAL_SHUTDOWN_SLOT" \
        -v min_gap="$THERMAL_MIN_SEVERITY_GAP_C" '
    function is_target(name) {
        return index(targets, "|" name "|") > 0
    }
    function is_numeric(raw) {
        return raw ~ /^-?[0-9]+([.][0-9]+)?$/
    }
    function clear_hot(i) {
        for (i = 1; i <= hot_item_count; i++) {
            delete hot_raw[i]
            delete hot_line[i]
            delete hot_numeric[i]
            delete hot_output[i]
            delete hot_hysteresis[i]
        }
        hot_item_count = 0
    }
    function clear_scan_hysteresis(i) {
        for (i = 1; i <= scan_hysteresis_count; i++) {
            delete scan_hysteresis_raw[i]
        }
        scan_hysteresis_count = 0
    }
    function finish_scan_hysteresis(i, raw) {
        if (scan_hysteresis_count != severity_slots || hysteresis_seen[scan_name]) {
            invalid_count++
        } else {
            hysteresis_seen[scan_name] = 1
            hysteresis_sensor_count++
            for (i = 1; i <= scan_hysteresis_count; i++) {
                raw = scan_hysteresis_raw[i]
                gsub(/[ \t]/, "", raw)
                sub(/,$/, "", raw)
                if (!is_numeric(raw) || raw + 0 < 0) {
                    invalid_count++
                } else {
                    stock_hysteresis[scan_name, i] = raw + 0
                }
            }
        }
        clear_scan_hysteresis()
    }
    function prepare_hot(i, value, next_set, next_value, next_index, required_gap,
                         limit, previous_set, previous_value) {
        if (hot_item_count != severity_slots) {
            invalid_count++
            return
        }

        for (i = 1; i <= hot_item_count; i++) {
            if (hot_raw[i] == "\"NAN\"") {
                hot_numeric[i] = 0
            } else if (is_numeric(hot_raw[i])) {
                hot_numeric[i] = 1
                hot_output[i] = hot_raw[i] + 0 + off
            } else {
                hot_numeric[i] = 0
                invalid_count++
            }
            if ((name SUBSEP i) in stock_hysteresis) {
                hot_hysteresis[i] = stock_hysteresis[name, i]
            } else {
                hot_hysteresis[i] = 0
                invalid_count++
            }
        }

        # The final severity maps to SHUTDOWN. Preserve its stock value.
        if (hot_numeric[shutdown_slot]) {
            hot_output[shutdown_slot] = hot_raw[shutdown_slot] + 0
        }

        next_set = 0
        next_index = 0
        for (i = hot_item_count; i >= 1; i--) {
            if (!hot_numeric[i]) continue
            value = hot_output[i]
            if (next_set) {
                required_gap = hot_hysteresis[next_index]
                if (required_gap < min_gap) required_gap = min_gap
                limit = next_value - required_gap
                if (value > limit) value = limit
            }
            hot_output[i] = value
            next_value = value
            next_index = i
            next_set = 1
        }

        previous_set = 0
        for (i = 1; i <= hot_item_count; i++) {
            if (!hot_numeric[i]) continue
            value = hot_output[i]
            if (previous_set && value <= previous_value) invalid_count++
            if (previous_set && previous_value > value - hot_hysteresis[i]) invalid_count++
            previous_value = value
            previous_set = 1
        }
    }
    function rendered_value(i) {
        if (!hot_numeric[i]) return hot_raw[i]
        if (hot_output[i] == hot_raw[i] + 0) return hot_raw[i]
        return sprintf("%.1f", hot_output[i])
    }
    NR == FNR {
        if (/"Name":/) {
            scan_name = $0
            sub(/.*"Name": *"/, "", scan_name)
            sub(/".*/, "", scan_name)
            scan_target = is_target(scan_name)
        }
        if (scan_target && /"HotHysteresis"/ && /\[/ && /\]/) {
            clear_scan_hysteresis()
            scan_line = $0
            scan_bracket_start = index(scan_line, "[")
            scan_rest = substr(scan_line, scan_bracket_start + 1)
            scan_bracket_end = index(scan_rest, "]")
            scan_inner = substr(scan_rest, 1, scan_bracket_end - 1)
            scan_hysteresis_count = split(scan_inner, scan_values, ",")
            for (i = 1; i <= scan_hysteresis_count; i++) {
                scan_hysteresis_raw[i] = scan_values[i]
            }
            finish_scan_hysteresis()
            next
        }
        if (scan_target && /"HotHysteresis"/ && /\[/ && !/\]/) {
            clear_scan_hysteresis()
            in_scan_hysteresis = 1
            next
        }
        if (in_scan_hysteresis) {
            if (/\]/) {
                finish_scan_hysteresis()
                in_scan_hysteresis = 0
                next
            }
            scan_hysteresis_count++
            scan_hysteresis_raw[scan_hysteresis_count] = $0
        }
        next
    }
    /"Name":/ {
        name = $0
        sub(/.*"Name": *"/, "", name)
        sub(/".*/, "", name)
        target = is_target(name)
        if (target && !target_seen[name]) {
            target_seen[name] = 1
            target_count++
        }
    }
    target && /"HotThreshold"/ && /\[/ && /\]/ {
        hot_count++
        clear_hot()
        line = $0
        bracket_start = index(line, "[")
        prefix = substr(line, 1, bracket_start - 1)
        rest = substr(line, bracket_start + 1)
        bracket_end = index(rest, "]")
        inner = substr(rest, 1, bracket_end - 1)
        suffix = substr(rest, bracket_end)
        hot_item_count = split(inner, values, ",")
        for (i = 1; i <= hot_item_count; i++) {
            hot_raw[i] = values[i]
            gsub(/[ \t]/, "", hot_raw[i])
        }
        prepare_hot()
        result = ""
        for (i = 1; i <= hot_item_count; i++) {
            result = result (i > 1 ? ", " : "") rendered_value(i)
        }
        print prefix "[" result suffix
        clear_hot()
        next
    }
    target && /"HotThreshold"/ && /\[/ && !/\]/ {
        hot_count++
        clear_hot()
        in_hot = 1
        print
        next
    }
    in_hot {
        if (/\]/) {
            prepare_hot()
            for (i = 1; i <= hot_item_count; i++) {
                if (!hot_numeric[i]) {
                    print hot_line[i]
                    continue
                }
                indent = hot_line[i]
                sub(/[^ \t].*/, "", indent)
                trailing = (hot_line[i] ~ /,[ \t]*$/) ? "," : ""
                printf "%s%s%s\n", indent, rendered_value(i), trailing
            }
            print
            clear_hot()
            in_hot = 0
            next
        }
        hot_item_count++
        hot_line[hot_item_count] = $0
        hot_raw[hot_item_count] = $0
        gsub(/[ \t]/, "", hot_raw[hot_item_count])
        sub(/,$/, "", hot_raw[hot_item_count])
        next
    }
    { print }
    END {
        if (in_scan_hysteresis || in_hot || hysteresis_sensor_count != expected_targets \
            || target_count != expected_targets || hot_count != expected_targets \
            || invalid_count != 0) exit 42
    }
    ' "$_tp_stock" "$_tp_stock" > "$_tp_tmp"
    _tp_rc=$?

    if [ "$_tp_rc" -ne 0 ] || [ ! -s "$_tp_tmp" ]; then
        rm -f "$_tp_tmp" 2>/dev/null
        return 20
    fi
    mv "$_tp_tmp" "$_tp_out" 2>/dev/null && [ -f "$_tp_out" ] || {
        rm -f "$_tp_tmp" 2>/dev/null
        return 21
    }
)
