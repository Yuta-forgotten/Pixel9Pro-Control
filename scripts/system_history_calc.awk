# Convert ordered BatteryStats snapshot totals into a bounded interval series.
# Input: ts<TAB>boot_id<TAB>total_mah<TAB>screen<TAB>doze<TAB>clock
# Output: meta/point/gap records consumed by system_history.sh.

BEGIN {
    FS = "\t"
    OFS = "\t"
    prev_ts = 0
    prev_total = 0
    prev_boot = ""
    prev_clock = ""
    raw = 0
    valid = 0
    coverage = 0
    gaps = 0
    updated = 0
}

function emit_gap(start, finish, reason) {
    gaps++
    printf "gap\t%d\t%d\t%s\n", start, finish, reason
}

{
    ts = $1 + 0
    boot = $2
    total = $3 + 0
    screen = ($4 != "" ? $4 : "unknown")
    doze = ($5 != "" ? $5 : "unknown")
    clock = ($6 != "" ? $6 : "unknown")
    if (ts <= 0 || ts > end_ts) next
    raw++
    if (ts > updated) updated = ts

    point_valid = 0
    rate = ""
    interval = 0
    quality = "baseline"
    if (prev_ts > 0 && ts > prev_ts && prev_ts <= end_ts && ts >= start_ts) {
        interval = ts - prev_ts
        if (boot != prev_boot || clock != prev_clock) {
            quality = "identity_changed"
            emit_gap(prev_ts, ts, quality)
        } else if (interval > max_gap) {
            quality = "interval_too_long"
            emit_gap(prev_ts, ts, quality)
        } else if (total < prev_total) {
            quality = "counter_reset"
            emit_gap(prev_ts, ts, quality)
        } else {
            rate = (total - prev_total) * 3600 / interval
            point_valid = 1
            quality = "ok"
            valid++
            coverage += interval
        }
    }
    if (ts >= start_ts && ts <= end_ts) {
        printf "point\t%d\t%s\t%s\t%s\t%.6f\t%s\t%d\t%d\t%s\n", ts, boot, screen, doze, total, rate, interval, point_valid, quality
    }
    prev_ts = ts
    prev_total = total
    prev_boot = boot
    prev_clock = clock
}

END {
    status = (valid > 0 ? "available" : "unavailable")
    quality = (valid == 0 ? "unavailable" : (gaps > 0 ? "partial" : "complete"))
    reason = (valid > 0 ? (gaps > 0 ? "gaps_or_counter_reset" : "ok") : "need_two_same_identity_snapshots")
    printf "meta\t%s\t%s\t%s\t%d\t%d\t%d\t%d\n", status, quality, reason, coverage, valid, raw, updated, gaps
}
