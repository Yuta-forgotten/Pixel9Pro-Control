#!/system/bin/sh

MODDIR="${1:-${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}}"
. "$MODDIR/uecap_profile.sh"

STATE_DIR="$MODDIR/.uecap_policy_state"
LAST_BYTES_FILE="$STATE_DIR/last_bytes"
LAST_SIG_FILE="$STATE_DIR/last_sig"
CHURN_COUNT_FILE="$STATE_DIR/churn_count"
CHURN_WINDOW_FILE="$STATE_DIR/churn_window"
SPECIAL_UNTIL_FILE="$STATE_DIR/special_until"

mkdir -p "$STATE_DIR" 2>/dev/null
[ -f "$UECAP_POLICY_FILE" ] || uecap_set_policy auto
[ -f "$UECAP_MANUAL_MODE_FILE" ] || uecap_set_manual_mode special
[ -f "$UECAP_MODE_FILE" ] || uecap_set_mode special
[ -f "$UECAP_REASON_FILE" ] || uecap_set_reason boot_default_special

read_screen_on() {
    _scr=$(dumpsys display 2>/dev/null | grep "mScreenState=" | head -1 | sed 's/.*mScreenState=//' | tr -d ' ')
    [ -z "$_scr" ] && _scr=$(dumpsys power 2>/dev/null | grep "mWakefulness=" | head -1 | sed 's/.*mWakefulness=//' | tr -d ' ')
    case "$_scr" in
        OFF|Dozing|Asleep) echo 0 ;;
        *) echo 1 ;;
    esac
}

read_total_bytes() {
    _sum=0
    for _ifc in /sys/class/net/rmnet* /sys/class/net/ccmni*; do
        [ -d "$_ifc" ] || continue
        _rx=$(cat "$_ifc/statistics/rx_bytes" 2>/dev/null)
        _tx=$(cat "$_ifc/statistics/tx_bytes" 2>/dev/null)
        _sum=$((_sum + ${_rx:-0} + ${_tx:-0}))
    done
    echo "${_sum:-0}"
}

read_skin_temp() {
    if [ -f "$MODDIR/.thermal_cache.json" ]; then
        _temp=$(sed -n 's/.*VIRTUAL-SKIN","temp":\([0-9]*\).*/\1/p' "$MODDIR/.thermal_cache.json" | head -1)
        echo "${_temp:-0}"
    else
        echo 0
    fi
}

read_radio_snapshot() {
    _dump=$(dumpsys telephony.registry 2>/dev/null)
    _service=$(printf '%s\n' "$_dump" | grep -m1 'mServiceState={')
    _signal=$(printf '%s\n' "$_dump" | grep -m1 'mSignalStrength=SignalStrength')

    SNAP_REG=0
    SNAP_CA=0
    SNAP_CHANNEL=$(printf '%s' "$_service" | sed -n 's/.*mChannelNumber=\([-0-9]*\).*/\1/p')
    SNAP_BAND=$(printf '%s' "$_service" | sed -n 's/.*mBands = \[\([^]]*\)\].*/\1/p' | tr -d ' ')
    SNAP_RSRP=$(printf '%s' "$_signal" | sed -n 's/.*ssRsrp = \(-\?[0-9]*\).*/\1/p')
    SNAP_SINR=$(printf '%s' "$_signal" | sed -n 's/.*ssSinr = \(-\?[0-9]*\).*/\1/p')

    printf '%s' "$_service" | grep -q 'mDataRegState=0(IN_SERVICE)' && SNAP_REG=1
    printf '%s' "$_service" | grep -q 'isUsingCarrierAggregation=true' && SNAP_CA=1

    SNAP_SIG="${SNAP_CHANNEL:-x}|${SNAP_BAND:-x}|${SNAP_CA}|${SNAP_REG}"
}

update_churn() {
    _sig="$1"
    _now="$2"
    _last_sig=$(cat "$LAST_SIG_FILE" 2>/dev/null)
    _count=$(cat "$CHURN_COUNT_FILE" 2>/dev/null)
    _window=$(cat "$CHURN_WINDOW_FILE" 2>/dev/null)
    [ -n "$_count" ] || _count=0
    [ -n "$_window" ] || _window=$_now

    if [ $((_now - _window)) -gt 300 ]; then
        _count=0
        _window=$_now
    fi

    if [ -n "$_last_sig" ] && [ "$_sig" != "$_last_sig" ]; then
        _count=$((_count + 1))
    fi

    printf '%s' "$_sig" > "$LAST_SIG_FILE"
    printf '%s' "$_count" > "$CHURN_COUNT_FILE"
    printf '%s' "$_window" > "$CHURN_WINDOW_FILE"
    echo "$_count"
}

while true; do
    _policy=$(uecap_current_policy)
    if [ "$_policy" = "manual" ]; then
        _manual=$(uecap_current_manual_mode)
        if [ "$(uecap_current_mode)" != "$_manual" ]; then
            uecap_apply_mode "$_manual" 2>/dev/null
        fi
        uecap_set_reason manual_locked
        sleep 30
        continue
    fi

    _now=$(date +%s 2>/dev/null || echo 0)
    _screen_on=$(read_screen_on)
    _bytes=$(read_total_bytes)
    _prev_bytes=$(cat "$LAST_BYTES_FILE" 2>/dev/null)
    [ -n "$_prev_bytes" ] || _prev_bytes=$_bytes
    printf '%s' "$_bytes" > "$LAST_BYTES_FILE"
    _delta_bytes=$((_bytes - _prev_bytes))
    [ "$_delta_bytes" -lt 0 ] && _delta_bytes=0

    read_radio_snapshot
    _temp=$(read_skin_temp)
    _churn=$(update_churn "$SNAP_SIG" "$_now")

    _weak=0
    _borderline=0
    [ -n "$SNAP_RSRP" ] && [ "$SNAP_RSRP" -le -98 ] 2>/dev/null && _weak=1
    [ -n "$SNAP_SINR" ] && [ "$SNAP_SINR" -le 5 ] 2>/dev/null && _weak=1
    [ -n "$SNAP_RSRP" ] && [ "$SNAP_RSRP" -le -95 ] 2>/dev/null && _borderline=1
    [ -n "$SNAP_SINR" ] && [ "$SNAP_SINR" -le 8 ] 2>/dev/null && _borderline=1

    _demand=0
    [ "$_screen_on" -eq 1 ] && [ "$_delta_bytes" -ge 524288 ] && _demand=1

    _reason=stable_special
    _target=special
    _trigger=0
    _hold_until=$(cat "$SPECIAL_UNTIL_FILE" 2>/dev/null)
    [ -n "$_hold_until" ] || _hold_until=0

    if [ "$SNAP_REG" -eq 1 ] && [ "$_screen_on" -eq 1 ] && [ "$_weak" -eq 1 ]; then
        _trigger=1
        _reason=screen_on_weak_signal
    elif [ "$SNAP_REG" -eq 1 ] && [ "$_demand" -eq 1 ] && [ "$_borderline" -eq 1 ]; then
        _trigger=1
        _reason=active_data_borderline_signal
    elif [ "$SNAP_REG" -eq 1 ] && [ "$_screen_on" -eq 1 ] && [ "$_churn" -ge 3 ]; then
        _trigger=1
        _reason=high_mobility_cell_churn
    elif [ "$SNAP_REG" -eq 1 ] && [ "$SNAP_CA" -eq 1 ] && [ "$_demand" -eq 1 ] && [ "$_temp" -lt 43000 ]; then
        _trigger=1
        _reason=ca_throughput_window
    fi

    if [ "$_trigger" -eq 1 ]; then
        _target=special
        _hold_until=$((_now + 900))
        printf '%s' "$_hold_until" > "$SPECIAL_UNTIL_FILE"
    elif [ "$_hold_until" -gt "$_now" ] 2>/dev/null; then
        _target=special
        _reason=hold_after_trigger
    fi

    if [ "$(uecap_current_mode)" != "$_target" ]; then
        if uecap_apply_mode "$_target" 2>/dev/null; then
            uecap_set_reason "$_reason"
        fi
    else
        uecap_set_reason "$_reason"
    fi

    if [ "$_screen_on" -eq 1 ]; then
        sleep 15
    else
        sleep 45
    fi
done
