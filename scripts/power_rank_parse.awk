# Parse `dumpsys batterystats --charged --checkin` into a snapshot ledger.
# Output is tab-delimited and intentionally contains no raw dumpsys text.
#   meta|start_clock_ms
#   app|uid|package_or_uid|mAh
#   component|name|name|mAh

BEGIN {
    FS = ","
    OFS = "\t"
    clock = ""
}

function safe(value,  out) {
    out = value
    gsub(/[\t\r\n|]/, " ", out)
    gsub(/\"/, "'", out)
    return substr(out, 1, 160)
}

# Metadata records are emitted by the collector through -v boot/capture.
$4 == "bt" && $3 == "l" && $10 ~ /^[0-9]+$/ && clock == "" {
    clock = $10
}

$3 == "i" && $4 == "uid" && $5 ~ /^[0-9]+$/ && $6 != "" {
    package_for[$5] = safe($6)
    next
}

$3 == "l" && $4 == "pwi" && $5 == "uid" && $2 ~ /^[0-9]+$/ && $6 ~ /^[0-9]+(\.[0-9]+)?$/ {
    # pwi uid fields are: consumed power, system flag, screen power,
    # proportional power. The first mAh value is the UID total.
    value = $6 + 0
    if (value >= 0) app[$2] = value
    next
}

$3 == "l" && $4 == "pwi" && $5 != "uid" && $5 != "" && $6 ~ /^[0-9]+(\.[0-9]+)?$/ {
    value = $6 + 0
    if (value >= 0) component[$5] = value
    next
}

END {
    printf "meta\t%s\t%s\t%s\n", safe(boot_id), capture_ts, clock
    for (uid in app) {
        label = package_for[uid]
        if (label == "") label = "uid_" uid
        printf "app\t%s\t%s\t%.6f\n", uid, label, app[uid]
    }
    for (name in component) {
        printf "component\t%s\t%s\t%.6f\n", name, name, component[name]
    }
}
