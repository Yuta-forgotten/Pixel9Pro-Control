#!/bin/sh
# Controlled collector: an off-screen production worker must request sysfs.
build_thermal_json() {
    [ "$1" = sysfs ] || { printf 'unexpected HAL request\n' >&2; exit 9; }
    printf '%s\n' "$1" >> "$MODDIR/collector_calls"
    THERMAL_BUILD_JSON='[{"zone":"VIRTUAL-SKIN","temp":38500},{"zone":"battery","temp":33000}]'
    THERMAL_BUILD_STATUS=""
    THERMAL_BUILD_SOURCE=sysfs
}
