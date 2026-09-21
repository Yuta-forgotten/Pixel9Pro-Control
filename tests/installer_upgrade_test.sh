#!/system/bin/sh
# Executes the production migration block only; never runs installer/device writes.
SOURCE_ROOT="$1"
TEST_ROOT="$2"
case "$TEST_ROOT" in /sdcard/Download/Pixel9Pro-Control-TestLab/runtime/*|/tmp/pixel9pro_*) ;; *) exit 64 ;; esac
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
printf 'off' > "$OLDDIR/.feature_power_export"
printf 'battery' > "$OLDDIR/.profile_manual"
printf 'balanced' > "$OLDDIR/.uecap_manual_mode"
sh "$BLOCK" || { printf 'not ok - migration block failed\n'; exit 1; }
for name in .thermal_policy .thermal_offset .scheduler_mode .feature_vm .feature_nr .feature_sim2 .feature_power_export .profile_manual .uecap_manual_mode; do
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
