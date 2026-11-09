#!/system/bin/sh
SOURCE_ROOT="$1"
WORK="$2"
mkdir -p "$WORK/fas" || exit 2
. "$SOURCE_ROOT/scripts/scheduler_owner_lib.sh" || exit 2
scheduler_owner_init "$WORK" "$WORK/fas"
PASS=0; FAIL=0
reject() {
    if "$@" >/dev/null 2>&1; then FAIL=$((FAIL+1)); printf 'not ok - invalid state accepted\n'
    else PASS=$((PASS+1)); printf 'ok - invalid state rejected explicitly\n'; fi
}
printf unknown > "$SO_EFFECTIVE_FILE"
reject so_read_effective_owner
printf unknown > "$SO_DESIRED_FILE"
reject so_read_desired_owner
printf unknown > "$SO_HANDOFF_FILE"
reject so_read_handoff_policy
printf unknown > "$SO_HANDOFF_SOURCE_FILE"
reject so_read_handoff_source
reject so_migrate_state
[ "$(cat "$SO_DESIRED_FILE")" = unknown ] || exit 1
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
