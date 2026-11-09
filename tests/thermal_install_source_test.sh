#!/system/bin/sh
# Current-source/upgrade fixtures; no system mount, HAL or property writes.
SOURCE_ROOT="$1"
WORK="$2"
mkdir -p "$WORK" || exit 2
PASS=0; FAIL=0
check() {
    if [ "$2" = "$3" ]; then PASS=$((PASS+1)); printf 'ok - %s\n' "$1"
    else FAIL=$((FAIL+1)); printf 'not ok - %s expected=%s actual=%s\n' "$1" "$2" "$3"; fi
}
awk '/^if \[ "\$THERMAL_POLICY" = custom \]; then$/ {capture=1} capture{print} capture && /^fi$/{exit}' "$SOURCE_ROOT/customize.sh" > "$WORK/generation.sh"
[ -s "$WORK/generation.sh" ] || exit 2
for scenario in fresh_system fresh_custom same_build ota_changed slot_changed missing_meta active_overlay malformed_source read_error; do
    (
        CASE_ROOT="$WORK/$scenario"
        mkdir -p "$CASE_ROOT/new" "$CASE_ROOT/old" "$CASE_ROOT/tmp" || exit 2
        TMPDIR="$CASE_ROOT/tmp"
        . "$SOURCE_ROOT/scripts/state_io_lib.sh" \
            && . "$SOURCE_ROOT/scripts/thermal_profile.sh" \
            && . "$SOURCE_ROOT/scripts/thermal_policy_lib.sh" || exit 2
        # /sdcard fixture storage cannot represent private 0600 modes.
        state_atomic_write() { printf '%s' "$2" > "$1" && [ "$(cat "$1")" = "$2" ]; }
        getprop() { [ "$1" = ro.build.fingerprint ] && printf 'fixture/new-build'; }
        thermal_policy_selected_config() { printf thermal_info_config.json; }
        thermal_policy_read_original() {
            printf '%s\n' "$1" >> "$CASE_ROOT/reads"
            case "$scenario" in
                read_error) printf 'original vendor read: simulated EACCES\n' >&2; return 13 ;;
                malformed_source) printf '{"Sensors":invalid}\n'; return 0 ;;
                *) cat "$SOURCE_ROOT/tests/fixtures/thermal/caiman.json" ;;
            esac
        }
        thermal_policy_init "$CASE_ROOT/new"
        device=caiman; OLDDIR="$CASE_ROOT/old"; offset=2
        OUT_JSON="$THERMAL_SOURCE_FILE"; OFFSET_FILE="$THERMAL_OFFSET_FILE"
        ui_print() { printf '%s\n' "$*"; }; abort() { exit 1; }
        installer_write() { printf '%s' "$2" > "$1"; }
        thermal_policy_label_source() { return 0; }
        printf 'id=pixel9pro_control\n' > "$OLDDIR/module.prop"
        printf custom > "$OLDDIR/.thermal_policy"
        mkdir -p "$CASE_ROOT/new/payloads/thermal/caiman"
        printf 'old-source\n' > "$CASE_ROOT/new/payloads/thermal/caiman/stock.json"
        printf 'fingerprint=fixture/old-build\nsha256=obsolete\n' > "$CASE_ROOT/new/payloads/thermal/caiman/stock.json.meta"
        [ "$scenario" != missing_meta ] || rm -f "$CASE_ROOT/new/payloads/thermal/caiman/stock.json.meta"
        if [ "$scenario" = fresh_system ]; then
            THERMAL_POLICY=system; offset=0
            . "$WORK/generation.sh" || exit 1
            [ ! -e "$CASE_ROOT/reads" ] && [ ! -e "$OUT_JSON" ] || exit 1
        elif [ "$scenario" = malformed_source ] || [ "$scenario" = read_error ]; then
            before=$(sha256sum "$CASE_ROOT/new/payloads/thermal/caiman/stock.json")
            if thermal_policy_prepare_snapshot caiman; then printf 'invalid original source accepted\n' >&2; exit 1; fi
            [ "$before" = "$(sha256sum "$CASE_ROOT/new/payloads/thermal/caiman/stock.json")" ] || exit 1
            [ "$(cat "$OLDDIR/.thermal_policy")" = custom ] || exit 1
        else
            thermal_policy_prepare_snapshot caiman || exit 1
            cmp -s "$SOURCE_ROOT/tests/fixtures/thermal/caiman.json" "$CASE_ROOT/new/payloads/thermal/caiman/stock.json" || exit 1
            [ "$(sed -n 's/^fingerprint=//p' "$CASE_ROOT/new/payloads/thermal/caiman/stock.json.meta")" = fixture/new-build ] || exit 1
            if [ "$scenario" = fresh_custom ]; then
                THERMAL_POLICY=custom
                . "$WORK/generation.sh" || exit 1
                [ -s "$OUT_JSON" ] && [ "$THERMAL_POLICY" = custom ] && [ "$offset" = 2 ] || exit 1
            fi
        fi
    ) > "$WORK/$scenario.stdout" 2> "$WORK/$scenario.stderr"
    rc=$?
    check "$scenario uses current original source or reports its real failure" 0 "$rc"
done
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
