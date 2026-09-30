# Decode Android BatteryStats check-in history into a compact event ledger.
# BatteryStats is the platform owner of this history, so the module can recover
# screen-off changes after its shell worker was suspended or killed.

BEGIN {
    FS = ","
    OFS = "\t"
    abs_ms = 0
    have_time = 0
    segment = 0
    sequence = 0
    level = "null"
    charge_uah = "null"
    temp_mc = "null"
    voltage_uv = "null"
    status = "Unknown"
    screen = "unknown"
    idle = "unknown"
    events = 0
    anchors = 0
    changed = 0
}

function emit_event(quality,  ts_sec) {
    if (!have_time) return
    ts_sec = int(abs_ms / 1000)
    if (ts_sec <= 0) return
    printf "event\t%d\t%d.%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", ts_sec, segment, sequence, level, charge_uah, temp_mc, voltage_uv, status, screen, idle, quality
    events++
}

function set_status(value) {
    if (value == "d") status = "Discharging"
    else if (value == "c") status = "Charging"
    else if (value == "f") status = "Full"
    else if (value == "n") status = "NotCharging"
    else status = "Unknown"
}

function parse_field(field,  key, value) {
    split(field, pair, "=")
    key = pair[1]
    value = substr(field, length(key) + 2)
    if (key == "Bl" && value ~ /^[0-9]+$/) { level = value; changed = 1 }
    else if (key == "Bcc" && value ~ /^[0-9]+$/) { charge_uah = value * 1000; changed = 1 }
    else if (key == "Bt" && value ~ /^-?[0-9]+$/) { temp_mc = value * 100; changed = 1 }
    else if (key == "Bv" && value ~ /^[0-9]+$/) { voltage_uv = value * 1000; changed = 1 }
    else if (key == "Bs") { set_status(value); changed = 1 }
    else if (key == "di") {
        if (value == "off") idle = "none"
        else if (value == "light") idle = "light"
        else if (value == "full") idle = "deep"
        else idle = "unknown"
        changed = 1
    }
    else if (key == "+S") { screen = "on"; changed = 1 }
    else if (key == "-S") { screen = "off"; changed = 1 }
    else if (key == "S") { screen = value == "1" ? "on" : "off"; changed = 1 }
}

$1 != "9" || $2 != "h" { next }

{
    first = $3
    delta = first
    colon = index(first, ":")
    suffix = ""
    anchor_only = 0
    changed = 0
    if (colon > 0) {
        delta = substr(first, 1, colon - 1)
        suffix = substr(first, colon + 1)
    }

    if (suffix == "START") {
        segment++
        sequence++
        next
    }
    if (index(suffix, "RESET:TIME:") == 1 || index(suffix, "TIME:") == 1) {
        anchor_only = 1
        time_text = suffix
        sub(/^RESET:TIME:/, "", time_text)
        sub(/^TIME:/, "", time_text)
        if (time_text ~ /^[0-9]+$/) {
            abs_ms = time_text + 0
            have_time = 1
            segment++
            sequence++
            anchors++
        }
    } else if (suffix == "RESET" || suffix == "SHUTDOWN" || suffix == "*OVERFLOW*") {
        segment++
        sequence++
        next
    } else if (delta ~ /^[0-9]+$/) {
        if (!have_time) next
        abs_ms += delta + 0
    } else {
        next
    }

    for (i = 4; i <= NF; i++) parse_field($i)
    if (!anchor_only && changed) emit_event("ok")
    sequence++
}

END {
    printf "meta\tschema=1\tevents=%d\tanchors=%d\tsegments=%d\n", events, anchors, segment
}
