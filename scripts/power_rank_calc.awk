# Reduce sorted snapshot ledgers to window-local cumulative deltas.
# Input records: meta<TAB>boot<TAB>capture<TAB>start_clock, app, component.
# Output records are a small stable protocol consumed by power_rank.sh.

BEGIN {
    FS = "\t"
    OFS = "\t"
    have = 0
    snapshot_count = 0
    valid_intervals = 0
    coverage = 0
    updated = 0
    identity_gaps = 0
}

function clear_current(  key) {
    for (key in cur_app) delete cur_app[key]
    for (key in cur_app_label) delete cur_app_label[key]
    for (key in cur_component) delete cur_component[key]
}

function clear_previous(  key) {
    for (key in prev_app) delete prev_app[key]
    for (key in prev_app_label) delete prev_app_label[key]
    for (key in prev_component) delete prev_component[key]
}

function quote_field(value,  out) {
    out = value
    gsub(/[\r\n\t|]/, " ", out)
    return substr(out, 1, 160)
}

function pair_delta(  key, delta, dt, in_window, same_identity, reason) {
    if (!have_prev) return
    dt = cur_ts - prev_ts
    in_window = (prev_ts >= start_ts && cur_ts <= end_ts && cur_ts > prev_ts)
    if (!in_window) return
    if (prev_boot != cur_boot || prev_clock != cur_clock) {
        identity_gaps++
        gap_n++; gap_start[gap_n] = prev_ts; gap_end[gap_n] = cur_ts; gap_reason[gap_n] = "identity_changed"
        return
    }
    if (dt > max_gap) {
        identity_gaps++
        gap_n++; gap_start[gap_n] = prev_ts; gap_end[gap_n] = cur_ts; gap_reason[gap_n] = "interval_too_long"
        return
    }
    valid_intervals++
    coverage += dt
    for (key in cur_app) {
        if (!(key in prev_app)) continue
        observed_items++
        delta = cur_app[key] - prev_app[key]
        if (delta < 0) {
            identity_gaps++
            gap_n++; gap_start[gap_n] = prev_ts; gap_end[gap_n] = cur_ts; gap_reason[gap_n] = "counter_reset"
            continue
        }
        app_total[key] += delta
        app_label[key] = cur_app_label[key]
    }
    for (key in cur_component) {
        if (!(key in prev_component)) continue
        observed_items++
        delta = cur_component[key] - prev_component[key]
        if (delta < 0) continue
        component_total[key] += delta
        component_label[key] = key
    }
}

$1 == "meta" {
    if (have_current) {
        if (have_prev) pair_delta()
        clear_previous()
        for (key in cur_app) { prev_app[key] = cur_app[key]; prev_app_label[key] = cur_app_label[key] }
        for (key in cur_component) prev_component[key] = cur_component[key]
        prev_ts = cur_ts; prev_boot = cur_boot; prev_clock = cur_clock; have_prev = 1
        clear_current()
        cur_boot = $2; cur_ts = $3 + 0; cur_clock = $4
        have_current = 1
        if (cur_ts >= start_ts && cur_ts <= end_ts) snapshot_count++
        if (cur_ts > updated) updated = cur_ts
        next
    }
    clear_current()
    cur_boot = $2; cur_ts = $3 + 0; cur_clock = $4
    have_current = 1
    if (cur_ts >= start_ts && cur_ts <= end_ts) snapshot_count++
    if (cur_ts > updated) updated = cur_ts
    next
}

$1 == "app" && have_current && $2 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+(\.[0-9]+)?$/ {
    cur_app[$2] = $4 + 0
    cur_app_label[$2] = quote_field($3)
    next
}

$1 == "component" && have_current && $4 ~ /^[0-9]+(\.[0-9]+)?$/ {
    cur_component[$2] = $4 + 0
    next
}

END {
    if (have_current && have_prev) pair_delta()
    valid = (valid_intervals > 0 && observed_items > 0)
    status = valid ? "available" : "unavailable"
    quality = valid ? (identity_gaps ? "partial" : "complete") : "unavailable"
    if (valid) reason = identity_gaps ? "gaps_or_counter_reset" : "ok"
    else if (valid_intervals > 0) reason = "no_power_items"
    else reason = "need_two_same_identity_snapshots"
    printf "meta\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\n", status, quality, reason, coverage, valid_intervals, snapshot_count, updated, updated
    for (i = 1; i <= gap_n; i++) printf "gap\t%d\t%d\t%s\n", gap_start[i], gap_end[i], gap_reason[i]
    for (key in app_total) if (app_total[key] > 0) printf "app\t%s\t%s\t%.6f\n", key, app_label[key], app_total[key]
    for (key in component_total) if (component_total[key] > 0) printf "component\t%s\t%s\t%.6f\n", key, component_label[key], component_total[key]
}
