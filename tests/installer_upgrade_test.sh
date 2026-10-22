#!/system/bin/sh
# Executes the production migration block only; never runs installer/device writes.
SOURCE_ROOT="$1"
TEST_ROOT="$2"
case "$TEST_ROOT" in /sdcard/Download/Pixel9Pro-Control-TestLab/runtime/*|/tmp/pixel9pro_*|"$SOURCE_ROOT"/tmp/installer-stock-*) ;; *) exit 64 ;; esac
mkdir -p "$TEST_ROOT/old" "$TEST_ROOT/new" || exit 2
export OLDDIR="$TEST_ROOT/old" MODPATH="$TEST_ROOT/new"
BLOCK="$TEST_ROOT/migrate.sh"
printf '_migration_failed=0\n' > "$BLOCK"
awk '/^    for _sf in / { capture=1 } capture { print } capture && /^    done$/ { exit }' "$SOURCE_ROOT/customize.sh" >> "$BLOCK"
printf '[ "$_migration_failed" -eq 0 ]\n' >> "$BLOCK"
grep -q '^    for _sf in ' "$BLOCK" || exit 2
printf 'custom' > "$OLDDIR/.thermal_policy"
printf '2' > "$OLDDIR/.thermal_offset"
printf 'off' > "$OLDDIR/.scheduler_mode"
printf 'disabled' > "$OLDDIR/.feature_vm"
printf 'off' > "$OLDDIR/.feature_nr"
printf 'off' > "$OLDDIR/.feature_sim2"
printf 'battery' > "$OLDDIR/.profile_manual"
printf 'balanced' > "$OLDDIR/.uecap_manual_mode"
printf off > "$OLDDIR/.idle_isolate_mode"
printf custom > "$OLDDIR/.swap_mode"
printf 'swappiness=100\nmin_free_kbytes=32768\nwatermark_scale_factor=20\nvfs_cache_pressure=100\n' > "$OLDDIR/.swap_custom"
printf manual > "$OLDDIR/.profile_policy"
printf balanced > "$OLDDIR/.current_profile"
sh "$BLOCK" || { printf 'not ok - migration block failed\n'; exit 1; }
for name in .thermal_policy .thermal_offset .scheduler_mode .feature_vm .feature_nr .feature_sim2 .profile_manual .uecap_manual_mode .idle_isolate_mode .swap_mode .swap_custom .profile_policy .current_profile; do
    cmp -s "$OLDDIR/$name" "$MODPATH/$name" || { printf 'not ok - %s lost\n' "$name"; exit 1; }
    printf 'ok - %s preserved\n' "$name"
done
printf 'system' > "$OLDDIR/.thermal_policy"
printf '0' > "$OLDDIR/.thermal_offset"
sh "$BLOCK" || exit 1
[ "$(cat "$MODPATH/.thermal_policy")" = system ] && [ "$(cat "$MODPATH/.thermal_offset")" = 0 ] || exit 1
printf 'ok - system policy is not converted to custom\n'
rm -f "$MODPATH/.thermal_policy"
mkdir "$MODPATH/.thermal_policy" || exit 2
if sh "$BLOCK"; then printf 'not ok - failed copy was accepted\n'; exit 1; fi
printf 'ok - failed migration rejects installation\n'

# Replay the production custom generation branch against a clean staging tree.
# It has no system/vendor directory until that branch creates one.
GEN="$TEST_ROOT/generate.sh"
awk '/^if \[ "\$THERMAL_POLICY" = custom \]; then$/ { capture=1 } capture { print } capture && /^fi$/ { exit }' "$SOURCE_ROOT/customize.sh" > "$GEN"
[ -s "$GEN" ] || exit 2
. "$SOURCE_ROOT/scripts/thermal_profile.sh" || exit 2
. "$SOURCE_ROOT/scripts/thermal_policy_lib.sh" || exit 2
thermal_policy_init "$TEST_ROOT/fresh"
device=caiman
mkdir -p "$THERMAL_POLICY_ROOT/payloads/thermal/$device" || exit 2
cp "$SOURCE_ROOT/tests/fixtures/thermal/caiman.json" "$THERMAL_POLICY_ROOT/payloads/thermal/$device/stock.json" || exit 2
OUT_JSON="$THERMAL_OVERLAY_FILE"
OFFSET_FILE="$THERMAL_OFFSET_FILE"
THERMAL_POLICY=custom
offset=2
installer_write() { printf '%s' "$2" > "$1"; }
ui_print() { :; }
abort() { exit 1; }
. "$GEN" || exit 1
[ -s "$OUT_JSON" ] && [ "$THERMAL_POLICY" = custom ] && [ "$offset" = 2 ] || exit 1
printf 'ok - clean staging creates the custom thermal directory and config\n'

# A disable marker is a next-boot request, not evidence that the old thermal
# overlay is absent from the installer's current mount namespace.
snapshot_case() (
    _case="$1"
    _case_root="$TEST_ROOT/snapshot-$_case"
    _case_old="$_case_root/old"
    _case_new="$_case_root/new"
    mkdir -p "$_case_old" "$_case_new" "$_case_root/tmp" || exit 2
    TMPDIR="$_case_root/tmp"
    getprop() { [ "$1" = ro.build.fingerprint ] && printf 'fixture/fingerprint/same-build'; }
    . "$SOURCE_ROOT/scripts/thermal_profile.sh" || exit 2
    . "$SOURCE_ROOT/scripts/thermal_policy_lib.sh" || exit 2
    thermal_policy_init "$_case_new" || exit 2
    [ "$_case" = fresh ] || printf 'id=pixel9pro_control\n' > "$_case_old/module.prop"
    # Preserve the actual capture/validation code; only map the read-only
    # Android vendor source to the explicit stock fixture on the host.
    eval "$(sed -n '/^thermal_policy_capture_stock() {/,/^}/p' "$SOURCE_ROOT/scripts/thermal_policy_lib.sh" \
        | sed '1s/thermal_policy_capture_stock/fixture_capture_stock/')"
    thermal_policy_capture_stock() {
        if [ "$1" = /vendor/etc/thermal_info_config.json ]; then
            printf 'vendor\n' >> "$_case_root/captures"
            fixture_capture_stock "$SOURCE_ROOT/tests/fixtures/thermal/caiman.json" "$2"
        else
            fixture_capture_stock "$@"
        fi
    }
    # Directory-level overlays do not produce a thermal_info_config.json
    # mountpoint; model that namespace without consulting the host mounts.
    awk() {
        if [ "$#" -eq 2 ] && [ "$2" = /proc/self/mountinfo ]; then
            printf '1 0 0:1 / /vendor rw - overlay overlay rw\n' | command awk "$1"
        else
            command awk "$@"
        fi
    }
    case "$_case" in
        provenance)
            mkdir -p "$_case_old/payloads/thermal/caiman" "$_case_old/system/vendor/etc" || exit 2
            cp "$SOURCE_ROOT/tests/fixtures/thermal/caiman.json" "$_case_old/payloads/thermal/caiman/stock.json" || exit 2
            thermal_policy_stock_record_provenance "$_case_old/payloads/thermal/caiman/stock.json" || exit 2
            printf custom > "$_case_old/.thermal_policy"
            printf custom-output > "$_case_old/system/vendor/etc/thermal_info_config.json"
            ;;
        disabled-source|disabled-custom)
            : > "$_case_old/disable"
            printf custom > "$_case_old/.thermal_policy"
            if [ "$_case" = disabled-source ]; then
                mkdir -p "$_case_old/system/vendor/etc" || exit 2
                printf custom-output > "$_case_old/system/vendor/etc/thermal_info_config.json"
            fi
            ;;
        system)
            printf system > "$_case_old/.thermal_policy"
            ;;
        fresh) ;;
        *) exit 2 ;;
    esac
    if thermal_policy_prepare_snapshot caiman "$_case_old" yes; then
        case "$_case" in disabled-*|system) printf 'not ok - unproven upgrade vendor was recaptured as stock\n'; exit 1 ;; esac
        _snapshot=$(thermal_policy_snapshot_path caiman) || exit 2
        cmp -s "$SOURCE_ROOT/tests/fixtures/thermal/caiman.json" "$_snapshot" || exit 1
        thermal_policy_stock_provenance_valid "$_snapshot" || exit 1
        if [ "$_case" = provenance ]; then
            [ ! -e "$_case_root/captures" ] || exit 1
        else
            [ "$(cat "$_case_root/captures")" = vendor ] || exit 1
        fi
    else
        case "$_case" in disabled-*|system) ;; *) printf 'not ok - valid stock path rejected\n'; exit 1 ;; esac
        [ ! -e "$_case_root/captures" ] || exit 1
        [ ! -e "$_case_new/payloads/thermal/caiman/stock.json" ] || exit 1
    fi
    printf 'ok - stock preparation %s\n' "$_case"
)
for _snapshot_case in provenance disabled-source disabled-custom system fresh; do
    snapshot_case "$_snapshot_case" || exit 1
done
