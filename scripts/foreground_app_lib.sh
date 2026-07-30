#!/system/bin/sh

# 统一 WindowManager/ActivityTaskManager 的前台包名判定顺序。
foreground_package_name() {
    if [ "${OWNER_ARBITER_TEST_MODE:-0}" = "1" ]; then
        if [ -n "${OWNER_ARBITER_TEST_FOREGROUND_COUNTER_PATH:-}" ]; then
            _fg_count=$(cat "$OWNER_ARBITER_TEST_FOREGROUND_COUNTER_PATH" 2>/dev/null | tr -d ' \r\n\t')
            case "$_fg_count" in ''|*[!0-9]*) _fg_count=0 ;; esac
            printf '%s\n' $((_fg_count + 1)) > "$OWNER_ARBITER_TEST_FOREGROUND_COUNTER_PATH" 2>/dev/null || true
        fi
        printf '%s' "${OWNER_ARBITER_TEST_FOCUS_PKG:-com.android.launcher}"
        return
    fi

    _fg_window_dump=$(dumpsys window 2>/dev/null)
    _fg_pkg=""
    for _fg_prefix in "mFocusedApp=" "mCurrentFocus=" "mFocusedWindow=" "topResumedActivity=" "ResumedActivity:"; do
        _fg_pkg=$(printf '%s\n' "$_fg_window_dump" | awk -v prefix="$_fg_prefix" '
            {
                line = $0
                sub(/^[ \t]+/, "", line)
                if (index(line, prefix) == 1) print line
            }
        ' | sed -n '
            s/.*[[:space:]]u[0-9][0-9]*[[:space:]]\([^/ }][^/ }]*\)\/.*/\1/p
            s/.*[[:space:]]\([A-Za-z0-9_.$][A-Za-z0-9_.$]*\)\/.*/\1/p
        ' | head -n 1)
        [ -n "$_fg_pkg" ] && break
    done
    if [ -z "$_fg_pkg" ]; then
        _fg_pkg=$(dumpsys activity top 2>/dev/null | sed -n 's/^  ACTIVITY \([^/ ][^/ ]*\)\/.*/\1/p' | head -n 1)
    fi
    printf '%s' "$_fg_pkg" | tr -d ' \r\n\t'
}
