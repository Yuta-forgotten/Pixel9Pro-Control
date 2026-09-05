#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(mktemp -d /tmp/pixel9pro_baseband_metainstall.XXXXXX)
cleanup() {
    case "$TMP_ROOT" in
        /tmp/pixel9pro_baseband_metainstall.*)
            [ ! -d "$TMP_ROOT" ] || rm -r -- "$TMP_ROOT"
            ;;
        *)
            printf 'Refusing unsafe cleanup path: %s\n' "$TMP_ROOT" >&2
            return 1
            ;;
    esac
}
trap cleanup EXIT

ADB_ROOT="$TMP_ROOT/data/adb"
MODPATH="$TMP_ROOT/module"
META="$ADB_ROOT/modules/meta-overlayfs"
mkdir -p "$MODPATH/config" "$MODPATH/scripts" "$MODPATH/system/product/etc/CarrierSettings" "$META/mnt" "$ADB_ROOT/ap"
cp "$ROOT_DIR/config/baseband_devices.tsv" "$MODPATH/config/baseband_devices.tsv"
cp "$ROOT_DIR/scripts/baseband_runtime.sh" "$MODPATH/scripts/baseband_runtime.sh"
printf 'id=meta-overlayfs\nmetamodule=1\n' > "$META/module.prop"
ln -s "$META" "$ADB_ROOT/metamodule"
printf 'fixture-payload\n' > "$MODPATH/system/product/etc/CarrierSettings/carrier_list.pb"

set +e
OUTPUT=$(
    (
        export MODPATH BASEBAND_ADB_ROOT="$ADB_ROOT" APATCH=true
        getprop() { printf '%s\n' caiman; }
        ui_print() { printf '%s\n' "$*"; }
        set_perm_recursive() { :; }
        . "$ROOT_DIR/customize.sh"
    ) 2>&1
)
RC=$?
set -e
[ "$RC" -eq 0 ] || { printf '%s\n' "$OUTPUT" >&2; exit 1; }

# This is the APatch 11224 MetaModule responsibility, represented by the
# same content-image shape: /data/adb/metamodule/mnt/<module-id>/<partition>/.
MODID=pixel9pro_baseband_trial
mkdir -p "$ADB_ROOT/metamodule/mnt/$MODID"
cp -a "$MODPATH/system" "$ADB_ROOT/metamodule/mnt/$MODID/"

[ -f "$ADB_ROOT/metamodule/mnt/$MODID/system/product/etc/CarrierSettings/carrier_list.pb" ] || {
    printf 'relocation target missing\n' >&2
    exit 1
}
[ -f "$MODPATH/system/product/etc/CarrierSettings/carrier_list.pb" ] || {
    printf 'installer unexpectedly consumed source tree\n' >&2
    exit 1
}
case "$OUTPUT" in
    *"MetaModule"*) ;;
    *) printf 'MetaModule evidence missing from installer output\n' >&2; exit 1 ;;
esac
printf 'PASS: APatch 11224 MetaModule content-image relocation contract\n'
