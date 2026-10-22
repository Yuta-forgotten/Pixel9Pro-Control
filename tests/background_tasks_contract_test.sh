#!/bin/sh
# Host-only process/CGI fixture. No Android settings or device are touched.
set -u
SOURCE_ROOT="$1"
TEST_ROOT="$2"
MODULE="$TEST_ROOT/module"
mkdir -p "$MODULE/scripts" "$MODULE/webroot/cgi-bin" || exit 2
for lib in background_tasks_lib.sh runtime_defaults_lib.sh; do
    cp "$SOURCE_ROOT/scripts/$lib" "$MODULE/scripts/" || exit 2
done
for cgi in _common.sh standby_guard.sh; do
    cp "$SOURCE_ROOT/webroot/cgi-bin/$cgi" "$MODULE/webroot/cgi-bin/" || exit 2
done
cp "$SOURCE_ROOT/tests/fixtures/background_worker.sh" "$MODULE/service.sh" || exit 2
export PIXEL9PRO_MODDIR="$MODULE"
. "$MODULE/scripts/background_tasks_lib.sh" || exit 2
fixture_cleanup() {
    rm -f "$MODULE/hold-stop"
    background_tasks_stop >/dev/null 2>&1 || true
    [ -z "${innocent_pid:-}" ] || kill "$innocent_pid" 2>/dev/null || true
    [ -z "${writer_pid:-}" ] || kill "$writer_pid" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap fixture_cleanup EXIT
printf fixture-token > "$MODULE/.webui_token"
printf on > "$MODULE/.idle_isolate_mode"

post() {
    _test_body="$1"
    printf '%s' "$_test_body" | REQUEST_METHOD=POST REMOTE_ADDR=127.0.0.1 \
        CONTENT_TYPE=application/json CONTENT_LENGTH="${#_test_body}" \
        HTTP_X_PIXEL9PRO_TOKEN=fixture-token sh "$MODULE/webroot/cgi-bin/standby_guard.sh"
}
printf '@@start\n%s\n' "$(post '{"idle_isolate_mode":"off"}')"
background_worker_alive || exit 1
first_pid=$BG_WORKER_PID
background_tasks_start || exit 1
[ "$BG_WORKER_PID" = "$first_pid" ] || exit 1
printf '@@stop\n%s\n' "$(post '{"idle_isolate_mode":"on"}')"
background_worker_alive && exit 1
[ ! -d "$MODULE/.background_worker.lock" ] || exit 1
if [ -r "$MODULE/last-sleep" ]; then
    kill -0 "$(cat "$MODULE/last-sleep")" 2>/dev/null && exit 1
fi

# PID reuse / stale start ticks must never signal an unrelated process.
sleep 60 &
innocent_pid=$!
mkdir "$MODULE/.background_worker.lock" || exit 2
printf 'pid=%s\nboot_id=%s\nstart_ticks=1\n' "$innocent_pid" "$(cat /proc/sys/kernel/random/boot_id)" > "$MODULE/.background_worker.lock/owner"
background_tasks_stop || exit 1
kill -0 "$innocent_pid" 2>/dev/null || exit 1
rm "$MODULE/.background_worker.lock/owner"
rmdir "$MODULE/.background_worker.lock"

printf '@@restart\n%s\n' "$(post '{"idle_isolate_mode":"off"}')"
background_worker_alive || exit 1
: > "$MODULE/hold-stop"
printf '@@pending\n%s\n' "$(post '{"idle_isolate_mode":"on"}')"
background_worker_alive || exit 1
rm "$MODULE/hold-stop"
printf '@@settled\n%s\n' "$(post '{"idle_isolate_mode":"on"}')"
background_worker_alive && exit 1

printf '%s|failed' "$(cat /proc/sys/kernel/random/boot_id)" > "$MODULE/.background_cleanup_state"
printf '@@cleanup_failed\n%s\n' "$(post '{"idle_isolate_mode":"on"}')"
[ "$(cat "$MODULE/.idle_isolate_mode")" = on ] || exit 1
rm "$MODULE/.background_cleanup_state"

# A foreground writer already past its entry gate is part of stop completion.
sh "$MODULE/service.sh" --history-writer >/dev/null 2>&1 &
writer_pid=$!
attempt=0
while [ ! -s "$MODULE/.thermal_history.lock/owner" ]; do
    attempt=$((attempt + 1)); [ "$attempt" -lt 30 ] || exit 1
    sleep 0.1
done
[ "$(background_tasks_state)" = stopping ] || exit 1
( sleep 0.3; kill -TERM "$writer_pid" ) >/dev/null 2>&1 &
printf '@@writer_settled\n%s\n' "$(post '{"idle_isolate_mode":"on"}')"
wait "$writer_pid" 2>/dev/null || true
writer_pid=""
[ ! -d "$MODULE/.thermal_history.lock" ] || exit 1

# Missing worker launcher must fail and restore the previously paused intent.
mv "$MODULE/service.sh" "$MODULE/service.disabled"
printf '@@failed_start\n%s\n' "$(post '{"idle_isolate_mode":"off"}')"
[ "$(cat "$MODULE/.idle_isolate_mode")" = on ] || exit 1
exit 0
