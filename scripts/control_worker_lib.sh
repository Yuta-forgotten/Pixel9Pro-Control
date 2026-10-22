#!/system/bin/sh
# Screen-aware module work, hosted by service.sh --background-worker.
control_worker_main() {
    background_tasks_enabled || return 0
    NR_SWITCH_FILE="$MODDIR/.nr_screen_switch"
    NR_MODE_FILE="$MODDIR/.nr_saved_mode"
    THERMAL_HISTORY="$MODDIR/.thermal_history"
    HISTORY_INTERVAL_ON=60
    HISTORY_INTERVAL_OFF=900

    [ -f "$NR_SWITCH_FILE" ] || runtime_write_value "$NR_SWITCH_FILE" "$NR_SCREEN_SWITCH_DEFAULT" >/dev/null 2>&1 \
        || log -t pixel9pro_ctrl "WARNING: failed to initialize NR switch state"

    . "$MODDIR/webroot/cgi-bin/_thermal_cache.sh"
    . "$MODDIR/scripts/thermal_history_lib.sh" || exit 1

    # Automatic profile decisions are disposable. If another scheduler
    # transaction owns the lock, skip this decision and recompute next cycle.
    SO_TRANSITION_LOCK_MAX_ATTEMPTS=1
    SO_TRANSITION_LOCK_RETRY_SLEEP_S=0

    _multicast_write_verified() {
        case "$1" in on|off) ;; *) return 1 ;; esac
        ip link set wlan0 multicast "$1" 2>/dev/null || return 1
        IFS= read -r _mc_readback < /sys/class/net/wlan0/flags 2>/dev/null || return 1
        case "$_mc_readback" in 0x[0-9a-fA-F]*) ;; *) return 1 ;; esac
        _mc_actual=off
        [ $((_mc_readback & 4096)) -eq 0 ] || _mc_actual=on
        [ "$_mc_actual" = "$1" ]
    }

    _cleanup_nr() {
        [ "${_worker_cleaned:-0}" -eq 0 ] || return 0
        _worker_cleaned=1
        trap '' INT TERM HUP
        _worker_cleanup_result=ok
        if [ -n "${_worker_sleep_pid:-}" ] && [ -n "${_worker_sleep_ticks:-}" ] \
            && [ "$(service_start_ticks "$_worker_sleep_pid")" = "$_worker_sleep_ticks" ]; then
            kill -TERM "$_worker_sleep_pid" 2>/dev/null || true
            wait "$_worker_sleep_pid" 2>/dev/null || true
        fi
        if [ "${_nr_owned:-0}" -eq 1 ] && [ -n "$_nr_key" ]; then
            _nr_restore=$(nr_mode_read_saved "$NR_MODE_FILE" "$NR_SAVED_MODE_DEFAULT" 2>/dev/null)
            if nr_mode_lock_acquire "$MODDIR" \
                && [ -n "$_nr_restore" ] && nr_mode_restore_slot0_verified "$_nr_key" "$_nr_restore"; then
                _nr_owned=0
                log -t pixel9pro_ctrl "NR switch: worker exit, restored NR"
            else
                _worker_cleanup_result=failed
                log -t pixel9pro_ctrl "WARNING: worker exit NR restore failed"
            fi
            nr_mode_lock_release || _worker_cleanup_result=failed
        fi
        nr_mode_lock_release || _worker_cleanup_result=failed
        if [ "${_mc_changed:-0}" -eq 1 ]; then
            if ! _multicast_write_verified "$_mc_original"; then
                _worker_cleanup_result=failed
                log -t pixel9pro_ctrl "WARNING: multicast flag restore failed on worker exit"
            fi
        fi
        runtime_write_value "$MODDIR/.background_cleanup_state" "$SERVICE_BOOT_ID|$_worker_cleanup_result" \
            || log -t pixel9pro_ctrl "WARNING: worker cleanup receipt could not be saved"
        rm -f "$SERVICE_LOCK_DIR/owner" "$SERVICE_LOCK_DIR/stopping" 2>/dev/null
        rmdir "$SERVICE_LOCK_DIR" 2>/dev/null || true
    }
    trap '_cleanup_nr' EXIT
    _worker_signal() {
        _worker_stop_requested=1
        # Defer exit until the current policy verification/rollback finishes.
        [ "${_worker_safe_wait:-0}" -ne 1 ] || exit "$1"
    }
    background_worker_should_run() {
        [ "${_worker_stop_requested:-0}" -eq 0 ] && background_tasks_enabled
    }
    trap '_worker_signal 130' INT
    trap '_worker_signal 143' TERM
    trap '_worker_signal 129' HUP
    if [ "$(cat "$MODDIR/.background_boot_ready" 2>/dev/null)" != "$SERVICE_BOOT_ID" ]; then
        restore_boot_policies || return 1
    fi
    background_worker_should_run || return 0

    _write_standby_diag_state() {
        _diag_tmp="${STANDBY_DIAG_FILE}.tmp.$$"
        [ ! -d "$STANDBY_DIAG_FILE" ] || return 1
        {
            printf 'updated_at=%s\n' "$1"
            printf 'screen=%s\n' "$2"
            printf 'worker_mode=%s\n' "$3"
            printf 'next_sleep_secs=%s\n' "$4"
            printf 'burst_active=%s\n' "$5"
            printf 'nr_switch=%s\n' "$6"
            printf 'nr_state=%s\n' "$7"
            printf 'profile_policy=%s\n' "$8"
            printf 'active_profile=%s\n' "$9"
            printf 'idle_isolate=%s\n' "${10}"
            printf 'sim2_auto_manage=%s\n' "${11}"
            printf 'cycle_count=%s\n' "${12}"
            printf 'wake_recheck_secs=%s\n' "$UNIFIED_SCREEN_WAKE_RECHECK_S"
        } > "$_diag_tmp" 2>/dev/null \
            && mv "$_diag_tmp" "$STANDBY_DIAG_FILE" 2>/dev/null \
            && [ -f "$STANDBY_DIAG_FILE" ] && return 0
        rm -f "$_diag_tmp" 2>/dev/null
        return 1
    }

    _sleep_until_worker_cycle() {
        _sleep_remaining="$1"
        _sleep_recheck="$UNIFIED_SCREEN_WAKE_RECHECK_S"
        case "$_sleep_remaining" in ''|*[!0-9]*|0) return 0 ;; esac
        case "$_sleep_recheck" in ''|*[!0-9]*|0) _sleep_recheck=900 ;; esac

        if [ "${_screen:-off}" = "on" ] || [ "$_sleep_remaining" -le "$_sleep_recheck" ] 2>/dev/null; then
            sleep "$_sleep_remaining" &
            _worker_sleep_pid=$!
            _worker_sleep_ticks=$(service_start_ticks "$_worker_sleep_pid")
            _worker_safe_wait=1
            wait "$_worker_sleep_pid" 2>/dev/null || true
            _worker_safe_wait=0
            _worker_sleep_pid=""
            return 0
        fi

        while [ "$_sleep_remaining" -gt 0 ] 2>/dev/null; do
            _sleep_chunk="$_sleep_recheck"
            [ "$_sleep_chunk" -le "$_sleep_remaining" ] 2>/dev/null || _sleep_chunk="$_sleep_remaining"
            sleep "$_sleep_chunk" &
            _worker_sleep_pid=$!
            _worker_sleep_ticks=$(service_start_ticks "$_worker_sleep_pid")
            _worker_safe_wait=1
            wait "$_worker_sleep_pid" 2>/dev/null || true
            _worker_safe_wait=0
            _worker_sleep_pid=""
            _sleep_remaining=$((_sleep_remaining - _sleep_chunk))
            [ "$_sleep_remaining" -gt 0 ] 2>/dev/null || break

            display_state_read >/dev/null 2>&1 || true
            [ "$DISPLAY_STATE_INTERACTIVE" = "yes" ] && return 0
        done
        return 0
    }

    _bg_stop_state_get() {
        _bg_stop_pkg="$1"
        _bg_stop_since=0
        _bg_stop_done=0
        [ -s "$BG_STOP_STATE_FILE" ] || return 0
        _bg_stop_line=$(awk -F'|' -v p="$_bg_stop_pkg" '$1 == p { print; exit }' "$BG_STOP_STATE_FILE" 2>/dev/null)
        [ -n "$_bg_stop_line" ] || return 0
        _old_ifs="$IFS"
        IFS='|'
        set -- $_bg_stop_line
        IFS="$_old_ifs"
        case "$2" in ''|*[!0-9]*) _bg_stop_since=0 ;; *) _bg_stop_since="$2" ;; esac
        case "$3" in 1) _bg_stop_done=1 ;; *) _bg_stop_done=0 ;; esac
    }

    _bg_stop_state_set() {
        _bg_stop_pkg="$1"
        _bg_stop_since="$2"
        _bg_stop_done="$3"
        mkdir -p "${BG_STOP_STATE_FILE%/*}" 2>/dev/null || return 1
        [ ! -d "$BG_STOP_STATE_FILE" ] || return 1
        _bg_state_tmp="${BG_STOP_STATE_FILE}.tmp.$$"
        if [ -s "$BG_STOP_STATE_FILE" ]; then
            awk -F'|' -v p="$_bg_stop_pkg" '$1 != p' "$BG_STOP_STATE_FILE" > "$_bg_state_tmp" 2>/dev/null \
                || { rm -f "$_bg_state_tmp" 2>/dev/null; return 1; }
        else
            : > "$_bg_state_tmp" 2>/dev/null \
                || return 1
        fi
        printf '%s|%s|%s\n' "$_bg_stop_pkg" "$_bg_stop_since" "$_bg_stop_done" >> "$_bg_state_tmp" 2>/dev/null \
            && mv "$_bg_state_tmp" "$BG_STOP_STATE_FILE" 2>/dev/null \
            && [ -f "$BG_STOP_STATE_FILE" ] && return 0
        rm -f "$_bg_state_tmp" 2>/dev/null
        return 1
    }

    _enforce_stop_after_leave() {
        _bg_stop_next_due=0
        [ "$(bg_read_enabled)" = "on" ] || return 0
        [ "${_screen_off_isolate:-0}" -eq 1 ] 2>/dev/null && return 0
        [ -s "$BG_LIST_FILE" ] || return 0

        _fg_pkg=""
        if [ "$_screen" = "on" ] || [ "${_just_off:-0}" -eq 1 ] 2>/dev/null; then
            _fg_pkg=$(foreground_package_name)
        fi

        while IFS= read -r _line || [ -n "$_line" ]; do
            bg_parse_entry "$_line"
            [ -z "$_bg_pkg" ] && continue
            case "$_bg_pkg" in \#*) continue ;; esac
            [ "$_bg_policy" = "stop_after_leave" ] || continue

            if [ -n "$_fg_pkg" ] && [ "$_fg_pkg" = "$_bg_pkg" ]; then
                _bg_stop_state_set "$_bg_pkg" "$_now" 0 \
                    || log -t pixel9pro_ctrl "WARNING: failed to persist background-stop timer for $_bg_pkg"
                continue
            fi

            _bg_stop_state_get "$_bg_pkg"
            if [ "$_bg_stop_since" -eq 0 ] 2>/dev/null; then
                continue
            fi

            _delay_sec=$((_bg_delay * 60))
            _elapsed=$((_now - _bg_stop_since))
            if [ "$_elapsed" -ge "$_delay_sec" ] 2>/dev/null; then
                if [ "$_bg_stop_done" -ne 1 ]; then
                    am force-stop "$_bg_pkg" 2>/dev/null
                    _bg_stop_state_set "$_bg_pkg" "$_now" 1 \
                        || log -t pixel9pro_ctrl "WARNING: failed to persist background-stop completion for $_bg_pkg"
                    log -t pixel9pro_ctrl "L1: force-stopped $_bg_pkg after ${_bg_delay}m away from foreground"
                fi
            else
                _due=$((_delay_sec - _elapsed))
                [ "$_due" -lt 15 ] 2>/dev/null && _due=15
                if [ "$_bg_stop_next_due" -eq 0 ] || [ "$_due" -lt "$_bg_stop_next_due" ]; then
                    _bg_stop_next_due=$_due
                fi
            fi
        done < "$BG_LIST_FILE"
    }

    # NR is optional: do not issue Settings IPC or rewrite its lock while off.
    _nr_key=""
    _cur=""
    if [ "$(read_onoff_file "$NR_SWITCH_FILE" "$NR_SCREEN_SWITCH_DEFAULT")" = on ] \
        && nr_mode_lock_acquire "$MODDIR"; then
        nr_mode_detect_setting
        _nr_key="$NR_MODE_KEY"
        _cur="$NR_MODE_CURRENT"
        if nr_mode_is_valid_raw "$_cur" && nr_mode_is_nr_capable "$_cur"; then
            nr_mode_save_current "$NR_MODE_FILE" "$_cur" >/dev/null 2>&1 \
                || log -t pixel9pro_ctrl "WARNING: failed to persist current NR mode"
        fi
        nr_mode_lock_release || return 1
    fi

    _NR_LTE="$NR_LTE_MODE"
    _mc_state=""
    _mc_changed=0
    _mc_original=""
    _mc_flags=$(cat /sys/class/net/wlan0/flags 2>/dev/null)
    case "$_mc_flags" in
        0x[0-9a-fA-F]*)
            if [ $((_mc_flags & 4096)) -ne 0 ]; then _mc_original=on; else _mc_original=off; fi ;;
    esac
    _cur_slot0=$(nr_mode_slot0 "$_cur")
    case "$_cur_slot0" in
        ''|null|*[!0-9-]*) _nr_state="unknown" ;;
        *)
            if [ "$_cur_slot0" -lt "$_NR_LTE" ] 2>/dev/null || [ "$_cur_slot0" -eq "$_NR_LTE" ] 2>/dev/null; then
                _nr_state="lte"
            else
                _nr_state="5g"
            fi
            ;;
    esac
    _nr_off_since=0
    _nr_owned=0
    _nr_restored=0
    _prev_screen=""
    _just_off=0
    _sim2_check_count=0
    # _NR_DELAY: 屏幕熄灭后多久才切到 LTE-only。
    # 60s 会让短时间锁屏(口袋亮灭/查看消息)反复触发 modem 重注册,
    # 每次 attach/detach 持 s5100_wake_lock ~1-2s。300s 防抖,只在真待机时切。
    _NR_DELAY="$NR_SCREEN_OFF_DELAY_S"
    _NR_COOLDOWN="$NR_RESTORE_COOLDOWN_S"
    # _NR_LTE_POLL: 切换到 LTE 后,worker 多久醒一次检查屏幕状态。
    # 60s 节奏会让 alarmtimer.4.auto 与 suspend 流程挤兑(实测 71 次 failed_suspend)。
    # 300s 把 wakeup 密度降到 12 次/h,给 kernel 真正的 deep suspend 窗口。
    # 代价:屏幕点亮后 NR 恢复最多滞后 5 分钟(用户体感可接受,RIL 数据通道不受影响)。
    _NR_LTE_POLL="$NR_LTE_RECHECK_S"
    _thermal_last_sample=$(tail -n 1 "$THERMAL_HISTORY" 2>/dev/null | cut -d, -f1)
    _control_thermal_last_sample=0
    _thermal_status=""
    case "$_thermal_last_sample" in ''|*[!0-9]*) _thermal_last_sample=0 ;; esac
    _history_prev_screen=unknown
    _auto_hot_since=0
    _auto_cool_since=0
    _auto_charge_hot_since=0
    _auto_charge_cool_since=0
    _active_profile=$(profile_state_read_profile "$PROFILE_FILE" 'default')
    _cycle_count=0
    _idle_isolate_prev=""
    _health_last_run=0
    _late_settings_due=$(( $(service_uptime) + 120 ))

    while true; do
        background_worker_should_run || break
        _now=$(date +%s 2>/dev/null || echo 0)
        _uptime_now=$(service_uptime)
        if [ "$_late_settings_due" -gt 0 ] && [ "$_uptime_now" -ge "$_late_settings_due" ]; then
            apply_keep5g_standby_settings \
                || log -t pixel9pro_ctrl "WARNING: late-boot standby settings were only partially applied"
            background_worker_should_run || break
            restore_ntp_server
            _late_settings_due=0
        fi
        _cycle_count=$((_cycle_count + 1))
        _active_profile=$(profile_state_read_profile "$PROFILE_FILE" "$_active_profile")
        _sched_owner=$(read_valid_sched_owner)
        sbm_load_state
        _scheduler_profile_writable=0
        if [ "$SBM_PHASE" = "success" ] && [ "$SBM_EFFECTIVE_MODE" = "pixel" ] \
            && [ "$_sched_owner" = "pixel" ]; then
            _scheduler_profile_writable=1
        else
            _sched_owner=external
        fi

        # DeviceIdle tracks user interactivity across ON/AOD/OFF. DRM enabled
        # only identifies an attached encoder and remains enabled during DOZE.
        display_state_read >/dev/null 2>&1 || true
        background_worker_should_run || break
        _screen=$(display_state_legacy_screen)
        [ "$_screen" != "unknown" ] || _screen="off"
        _idle_isolate=$(read_onoff_file "$IDLE_ISOLATE_FILE" "$IDLE_ISOLATE_DEFAULT")
        _sim2_auto=$(read_onoff_file "$SIM2_AUTO_FILE" "$SIM2_AUTO_DEFAULT")
        _screen_off_isolate=0
        if [ "$_idle_isolate" = "on" ] && [ "$_screen" = "off" ]; then
            _screen_off_isolate=1
        fi

        if [ "$_idle_isolate" != "$_idle_isolate_prev" ]; then
            log -t pixel9pro_ctrl "Idle isolate: $_idle_isolate"
            _idle_isolate_prev="$_idle_isolate"
        fi

        # --- WiFi multicast: state-transition only ---
        if [ -n "$_mc_original" ] && [ "$_screen" != "$_mc_state" ]; then
            _mc_changed=1
            if [ "$_screen" = "off" ]; then
                _multicast_write_verified off || log -t pixel9pro_ctrl "WARNING: multicast off readback failed"
            else
                _multicast_write_verified on || log -t pixel9pro_ctrl "WARNING: multicast on readback failed"
            fi
            _mc_state="$_screen"
        fi

        # --- Screen transition tracking ---
        if [ "$_screen" = "off" ] && [ "$_prev_screen" = "on" ]; then
            _just_off=1
        elif [ "$_screen" = "on" ] && [ "$_prev_screen" = "off" ]; then
            _just_off=0
        fi

        # Health and owner arbitration are screen-on observations. The first
        # cycle after wake performs an immediate read; steady foreground work
        # repeats only at the low 300-second health cadence. The off recorder
        # never performs top-app or scheduler binder queries.
        if [ "$_screen" = "on" ]; then
            _health_due=0
            [ "$_health_last_run" -eq 0 ] 2>/dev/null && _health_due=1
            [ $((_now - _health_last_run)) -ge "$CPU_PROFILE_HEALTH_INTERVAL_S" ] 2>/dev/null && _health_due=1
            [ "$_prev_screen" = "off" ] && _health_due=1
            if [ "$_health_due" -eq 1 ] && [ "$CPU_PROFILE_AVAILABLE" -eq 1 ]; then
                sh "$MODDIR/scripts/scheduler_reconcile.sh" health "$MODDIR" >/dev/null 2>&1
                _scheduler_health_rc=$?
                [ "$_scheduler_health_rc" -eq 5 ] \
                    && log -t pixel9pro_ctrl "Scheduler health observed profile drift; no automatic repair (system writeback boundary)"
                _health_last_run=$_now
            fi
            _arbiter_handoff=$(cat "$GAME_HANDOFF_POLICY_FILE" 2>/dev/null | tr -d ' \n\r\t')
            _arbiter_lease_state=$(cat "/data/adb/fas_rs/.owner_state" 2>/dev/null | tr -d '\r\n')
            _arbiter_lease_active=0
            case "$_arbiter_lease_state" in *fas-rs:game:*) _arbiter_lease_active=1 ;; esac
            if [ -f "$MODDIR/scripts/owner_arbiter.sh" ] \
                && { [ "$_arbiter_handoff" = fas_rs ] || [ "$_arbiter_lease_active" -eq 1 ]; }; then
                SO_TRANSITION_LOCK_MAX_ATTEMPTS=1
                SO_TRANSITION_LOCK_RETRY_SLEEP_S=0
                export SO_TRANSITION_LOCK_MAX_ATTEMPTS SO_TRANSITION_LOCK_RETRY_SLEEP_S
                sh "$MODDIR/scripts/owner_arbiter.sh" tick "$MODDIR" on >/dev/null 2>&1
            fi
        fi
        _prev_screen="$_screen"
        background_worker_should_run || break

        # Check SIM2 every ~10 on-screen cycles. Boot performs one initial
        # application; screen-off avoids telephony IPC so suspend is not disturbed.
        if [ "$_screen" = "on" ] && [ "$_idle_isolate" != "on" ]; then
            _sim2_check_count=$((_sim2_check_count + 1))
            if [ "$_sim2_check_count" -ge 10 ]; then
                manage_sim2_radio
                _sim2_check_count=0
            fi
        fi

        # --- NR screen-off switch ---
        background_worker_should_run || break
        _nr_enabled=$(read_onoff_file "$NR_SWITCH_FILE" "$NR_SCREEN_SWITCH_DEFAULT")
        if { [ "$_nr_enabled" = on ] || [ "$_nr_owned" -eq 1 ]; } && nr_mode_lock_acquire "$MODDIR"; then
        # CGI and worker serialize the complete decision, not only Settings.
        _nr_enabled=$(read_onoff_file "$NR_SWITCH_FILE" "$NR_SCREEN_SWITCH_DEFAULT")
        if { [ -z "$_nr_key" ] || [ "$_nr_state" = unknown ]; } && [ "$_nr_enabled" = on ]; then
            nr_mode_detect_setting
            _nr_key="$NR_MODE_KEY"
            _cur="$NR_MODE_CURRENT"
            if nr_mode_is_nr_capable "$_cur"; then
                _nr_state=5g
            elif nr_mode_is_valid_raw "$_cur"; then
                _nr_state=lte
            else
                _nr_state=unknown
            fi
        fi
        if ! background_worker_should_run || [ "$_screen_off_isolate" -eq 1 ]; then
            _nr_off_since=0
        else
            if [ "$_nr_enabled" != "on" ]; then
                if [ "$_nr_owned" -eq 1 ]; then
                    _nr_restore=$(nr_mode_read_saved "$NR_MODE_FILE" "$NR_SAVED_MODE_DEFAULT" 2>/dev/null)
                    if [ -n "$_nr_restore" ] && nr_mode_restore_slot0_verified "$_nr_key" "$_nr_restore"; then
                        _nr_state="5g"
                        _nr_owned=0
                        _nr_restored=$_now
                        log -t pixel9pro_ctrl "NR switch: disabled, restored NR"
                    else
                        log -t pixel9pro_ctrl "WARNING: NR switch disabled but restore failed"
                    fi
                fi
                _nr_off_since=0
            elif [ "$_screen" = "off" ]; then
                if [ "$_nr_state" = "5g" ]; then
                    [ "$_nr_off_since" -eq 0 ] && _nr_off_since=$_now
                    _elapsed=$((_now - _nr_off_since))
                    _since_nr=$((_now - _nr_restored))
                    if [ "$_elapsed" -ge "$_NR_DELAY" ] && [ "$_since_nr" -ge "$_NR_COOLDOWN" ]; then
                        # tethering 检测: 只检查真正的热点/USB 接口是否 UP。
                        # wlan1/wlan2 是 bcmdhd P2P 虚拟接口, Wi-Fi 开启时就存在(state DOWN),
                        # 不代表 tethering。Android 17 Pixel 热点常见桥接接口是 ap_br_wlan*。
                        _tether=0
                        for _tif in swlan0 ap0 softap0 rndis0 ncm0 /sys/class/net/ap_br_wlan* /sys/class/net/ap_br_softap*; do
                            case "$_tif" in /sys/class/net/*) _tif="${_tif##*/}" ;; esac
                            if [ -d "/sys/class/net/$_tif" ]; then
                                _tif_state=$(cat "/sys/class/net/$_tif/operstate" 2>/dev/null)
                                [ "$_tif_state" = "up" ] && _tether=1 && break
                            fi
                        done
                        if [ "$_tether" -eq 0 ]; then
                            _cur=$(settings get global "$_nr_key" 2>/dev/null | tr -d ' \n\r')
                            if ! nr_mode_is_valid_raw "$_cur" || ! nr_mode_is_nr_capable "$_cur"; then
                                log -t pixel9pro_ctrl "WARNING: NR switch skipped invalid current mode ($_cur)"
                            elif ! nr_mode_save_current "$NR_MODE_FILE" "$_cur"; then
                                log -t pixel9pro_ctrl "WARNING: NR switch skipped because restore mode could not be persisted"
                            else
                                _lte_val=$(nr_mode_replace_slot0 "$_cur" "$_NR_LTE")
                            fi
                            if [ -n "${_lte_val:-}" ] && nr_mode_write_verified "$_nr_key" "$_lte_val"; then
                                _nr_state="lte"
                                _nr_owned=1
                                log -t pixel9pro_ctrl "NR switch: off ${_elapsed}s, switched to LTE ($_lte_val)"
                            elif [ -n "${_lte_val:-}" ]; then
                                log -t pixel9pro_ctrl "WARNING: NR switch to LTE failed ($_lte_val)"
                            fi
                            _lte_val=""
                        fi
                    fi
                fi
            else
                _nr_off_since=0
                if [ "$_nr_owned" -eq 1 ]; then
                    _nr_restore=$(nr_mode_read_saved "$NR_MODE_FILE" "$NR_SAVED_MODE_DEFAULT" 2>/dev/null)
                    if [ -n "$_nr_restore" ] && nr_mode_restore_slot0_verified "$_nr_key" "$_nr_restore"; then
                        _nr_state="5g"
                        _nr_owned=0
                        _nr_restored=$_now
                        log -t pixel9pro_ctrl "NR switch: screen on, restored NR"
                    else
                        log -t pixel9pro_ctrl "WARNING: screen on but NR restore failed"
                    fi
                fi
            fi
        fi

        nr_mode_lock_release || log -t pixel9pro_ctrl "WARNING: NR policy lock release failed"
        else
            _nr_enabled=$(read_onoff_file "$NR_SWITCH_FILE" "$NR_SCREEN_SWITCH_DEFAULT")
        fi

        # Thermal history is independent of the removed power-history policy.
        background_worker_should_run || break
        # Screen-off samples use sysfs and never start a Thermal HAL Binder dump.
        _worker_mode="deep_standby"
        [ "$_screen" = on ] && _worker_mode=screen_on
        _vs_temp=""
        _thermal_interval=$HISTORY_INTERVAL_OFF
        [ "$_screen" = on ] && _thermal_interval=$HISTORY_INTERVAL_ON
        _history_due=0
        [ "$_thermal_last_sample" -eq 0 ] 2>/dev/null && _history_due=1
        [ $((_now - _thermal_last_sample)) -ge "$_thermal_interval" ] 2>/dev/null && _history_due=1
        [ "$_screen" = on ] && [ "$_history_prev_screen" != on ] && _history_due=1
        _control_due=0
        [ "$_screen" = on ] && { [ "$_control_thermal_last_sample" -eq 0 ] || [ $((_now - _control_thermal_last_sample)) -ge 60 ] 2>/dev/null; } && _control_due=1
        if [ "$_history_due" -eq 1 ] || [ "$_control_due" -eq 1 ]; then
            [ "$_screen" = on ] && _worker_mode=screen_on
            _thermal_source=sysfs
            [ "$_screen" = on ] && _thermal_source=hal
            build_thermal_json "$_thermal_source" >/dev/null 2>&1
            _json="$THERMAL_BUILD_JSON"
            _thermal_status="$THERMAL_BUILD_STATUS"
            _thermal_source="$THERMAL_BUILD_SOURCE"
            _vs_temp=""
            if [ -n "$_json" ] && [ "$_json" != "[]" ]; then
                if ! runtime_write_value "$THERMAL_CACHE" "$_json"; then
                    log -t pixel9pro_ctrl "WARNING: failed to refresh thermal cache"
                fi
                _vs_temp=$(printf '%s' "$_json" | sed -n 's/.*"zone":"VIRTUAL-SKIN","temp":\([0-9]*\).*/\1/p')
                case "$_vs_temp" in ''|*[!0-9]*) _vs_temp="" ;; esac
            fi
            [ "$_screen" = on ] && _control_thermal_last_sample=$_now
            if [ "$_history_due" -eq 1 ]; then
                thermal_history_record "$_json" "$_now" "$_screen" "$_thermal_source" \
                    || log -t pixel9pro_ctrl "WARNING: failed to append temperature history"
                _thermal_last_sample=$_now
            fi
        fi

        # The master gate above controls this entire worker and the writer.
        background_worker_should_run || break
        _p_status=""
        IFS= read -r _p_status < /sys/class/power_supply/battery/status 2>/dev/null || _p_status=""
        case "$_p_status" in Charging|Full) _p_is_charging=1 ;; *) _p_is_charging=0 ;; esac
        if [ "$_screen_off_isolate" -eq 1 ]; then
            _worker_mode="idle_isolate"
            _auto_hot_since=0
            _auto_cool_since=0
            _auto_charge_hot_since=0
            _auto_charge_cool_since=0
        else
            if [ -z "$_vs_temp" ] && [ "$_screen" = "on" ]; then
                _vs_temp=$(sed -n 's/.*VIRTUAL-SKIN","temp":\([0-9]*\).*/\1/p' "$THERMAL_CACHE" 2>/dev/null | head -1)
                case "$_vs_temp" in
                    ''|*[!0-9]*) _vs_temp="" ;;
                esac
            fi

            # --- Slow auto profile policy ---
            _profile_policy=$(profile_state_read_policy)
            _manual_profile=$(profile_state_read_profile "$PROFILE_MANUAL_FILE" 'balanced')
            _target_profile=""
            _target_reason=""
            _sev=""

            if [ "$_sched_owner" = "external" ]; then
                _auto_hot_since=0
                _auto_cool_since=0
                _auto_charge_hot_since=0
                _auto_charge_cool_since=0
                _active_profile=$(profile_state_read_profile "$PROFILE_FILE" "$_active_profile")
            elif [ "$_profile_policy" = "manual" ]; then
                _auto_hot_since=0
                _auto_cool_since=0
                _auto_charge_hot_since=0
                _auto_charge_cool_since=0
                if [ "$_screen" = "on" ]; then
                    if apply_profile_state "$_manual_profile" "manual_policy" manual; then
                        _active_profile="$_manual_profile"
                    fi
                fi
            elif [ "$_screen" = "on" ]; then
                if [ "${_p_is_charging:-0}" -eq 1 ] 2>/dev/null; then
                    # 充电态: ADB/线充会抬高壳温, 单看系统 severity 反应偏晚。
                    # 因此拆成两道闸: severity>=MODERATE 立即收口; VIRTUAL-SKIN 体感热只慢切换。
                    _auto_hot_since=0
                    _auto_cool_since=0
                    # Reuse the latest <=60s thermal snapshot. Do not launch
                    # another HAL dump on every 15s policy cycle.
                    _sev="$_thermal_status"
                    case "$_sev" in ''|*[!0-9]*) _sev=-1 ;; esac
                    if [ "$_sev" -ge "$CPU_PROFILE_AUTO_CHARGING_THERMAL_STATUS_MIN" ] 2>/dev/null; then
                        _auto_charge_cool_since=0
                        _target_profile="battery"
                        _target_reason="charging_thermal_mitigation"
                    else
                        if [ -n "$_vs_temp" ] && [ "$_vs_temp" -ge "$CPU_PROFILE_AUTO_CHARGING_HOT_TEMP_MC" ] 2>/dev/null; then
                            [ "$_auto_charge_hot_since" -eq 0 ] && _auto_charge_hot_since=$_now
                            _auto_charge_cool_since=0
                        elif [ -n "$_vs_temp" ] && [ "$_vs_temp" -le "$CPU_PROFILE_AUTO_CHARGING_COOL_TEMP_MC" ] 2>/dev/null; then
                            [ "$_auto_charge_cool_since" -eq 0 ] && _auto_charge_cool_since=$_now
                            _auto_charge_hot_since=0
                        else
                            _auto_charge_hot_since=0
                            _auto_charge_cool_since=0
                        fi

                        if [ "$_active_profile" = "battery" ] && [ "$_auto_charge_cool_since" -gt 0 ] && [ $((_now - _auto_charge_cool_since)) -ge "$CPU_PROFILE_AUTO_CHARGING_COOL_HOLD_S" ]; then
                            _target_profile="balanced"
                            _target_reason="charging_comfort_cooldown"
                        elif [ "$_active_profile" = "battery" ]; then
                            _target_profile="battery"
                            _target_reason="charging_comfort_hot"
                        elif [ "$_auto_charge_hot_since" -gt 0 ] && [ $((_now - _auto_charge_hot_since)) -ge "$CPU_PROFILE_AUTO_CHARGING_HOT_HOLD_S" ]; then
                            _target_profile="battery"
                            _target_reason="charging_comfort_hot"
                        else
                            _target_profile="balanced"
                            _target_reason="charging_no_throttle"
                        fi
                    fi
                else
                    # Discharge uses the shared CPU profile contract. It enters
                    # battery before the previous 40.8C/90s gate so a normal
                    # long video/feed session does not first build a hot shell.
                    _auto_charge_hot_since=0
                    _auto_charge_cool_since=0
                    if [ -n "$_vs_temp" ] && [ "$_vs_temp" -ge "$CPU_PROFILE_AUTO_DISCHARGE_HOT_TEMP_MC" ] 2>/dev/null; then
                        [ "$_auto_hot_since" -eq 0 ] && _auto_hot_since=$_now
                        _auto_cool_since=0
                    elif [ -n "$_vs_temp" ] && [ "$_vs_temp" -le "$CPU_PROFILE_AUTO_DISCHARGE_COOL_TEMP_MC" ] 2>/dev/null; then
                        [ "$_auto_cool_since" -eq 0 ] && _auto_cool_since=$_now
                        _auto_hot_since=0
                    else
                        _auto_hot_since=0
                        _auto_cool_since=0
                    fi

                    if [ "$_active_profile" = "battery" ] && [ "$_auto_cool_since" -gt 0 ] && [ $((_now - _auto_cool_since)) -ge "$CPU_PROFILE_AUTO_DISCHARGE_COOL_HOLD_S" ]; then
                        _target_profile="balanced"
                        _target_reason="hot_cooldown"
                    elif [ "$_active_profile" = "battery" ]; then
                        # Keep battery inside the configured hot/cool deadband;
                        # otherwise one sample below the hot threshold would
                        # bypass the cool hold and make the profile oscillate.
                        _target_profile="battery"
                        _target_reason="steady_hot_guard"
                    elif [ "$_auto_hot_since" -gt 0 ] && [ $((_now - _auto_hot_since)) -ge "$CPU_PROFILE_AUTO_DISCHARGE_HOT_HOLD_S" ]; then
                        _target_profile="battery"
                        _target_reason="steady_hot_guard"
                    else
                        _target_profile="balanced"
                        _target_reason="auto_balanced"
                    fi
                fi

                if [ -n "$_target_profile" ]; then
                    if apply_profile_state "$_target_profile" "$_target_reason" auto; then
                        _active_profile="$_target_profile"
                    fi
                fi
            else
                # --- 息屏深度待机: 不做前台探测 / 自动调度 ---
                if apply_profile_state "balanced" "deep_standby_reset" auto; then
                    _active_profile="balanced"
                fi
                _auto_hot_since=0
                _auto_cool_since=0
                _auto_charge_hot_since=0
                _auto_charge_cool_since=0
            fi
        fi

        _history_prev_screen="$_screen"
        background_worker_should_run || break
        _enforce_stop_after_leave

        # --- Adaptive sleep ---
        if [ "$_screen" = "on" ]; then
            _next_sleep_secs=15
        elif [ "$_screen_off_isolate" -eq 1 ]; then
            _just_off=0
            _next_sleep_secs=900
        elif [ "$_just_off" -eq 1 ]; then
            _just_off=0
            _next_sleep_secs=900
        elif [ "$_nr_state" = "lte" ]; then
            _next_sleep_secs=$_NR_LTE_POLL
        elif [ "$_nr_enabled" = "on" ] && [ "$_nr_off_since" -gt 0 ] 2>/dev/null; then
            _next_sleep_secs=900
        else
            _next_sleep_secs=900
        fi
        if [ "$_screen" = on ] && [ "${_bg_stop_next_due:-0}" -gt 0 ] 2>/dev/null \
            && [ "$_bg_stop_next_due" -lt "$_next_sleep_secs" ] 2>/dev/null; then
            _next_sleep_secs="$_bg_stop_next_due"
        fi
        _diag_profile_policy=$(profile_state_read_policy)
        _write_standby_diag_state "$_now" "$_screen" "$_worker_mode" "$_next_sleep_secs" 0 "$_nr_enabled" "$_nr_state" "$_diag_profile_policy" "$_active_profile" "$_idle_isolate" "$_sim2_auto" "$_cycle_count" \
            || log -t pixel9pro_ctrl "WARNING: failed to persist standby diagnostics"
        _sleep_until_worker_cycle "$_next_sleep_secs"
    done
}
