#!/system/bin/sh

# Hybrid Mount only: small A/B transaction store for files that must be
# promoted before Hybrid Mount scans regular-module source.  This library does
# not mount, bind, or write /vendor.  It owns only the module-private pending
# state and the two allowlisted payloads consumed by post-fs-data.sh.

SLOT_ROOT="${PIXEL9PRO_SLOT_ROOT:-/data/adb/pixel9pro_control/slots}"
SLOT_LOCK="${SLOT_ROOT}.lock"

slot_init() {
    SLOT_ROOT="${PIXEL9PRO_SLOT_ROOT:-/data/adb/pixel9pro_control/slots}"
    SLOT_LOCK="${SLOT_ROOT}.lock"
    mkdir -p "$SLOT_ROOT" || return 1
    chmod 700 "$SLOT_ROOT" 2>/dev/null || true
}

slot_hash() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

slot_atomic_write() {
    _slot_file="$1"
    _slot_value="$2"
    _slot_tmp="${_slot_file}.tmp.$$"
    mkdir -p "${_slot_file%/*}" 2>/dev/null || return 1
    printf '%s' "$_slot_value" > "$_slot_tmp" 2>/dev/null \
        && sync \
        && mv -f "$_slot_tmp" "$_slot_file" 2>/dev/null \
        && [ "$(cat "$_slot_file" 2>/dev/null)" = "$_slot_value" ]
    _slot_rc=$?
    rm -f "$_slot_tmp" 2>/dev/null || true
    return "$_slot_rc"
}

slot_lock() {
    mkdir "$SLOT_LOCK" 2>/dev/null || return 1
    printf '%s\n' "$$" > "$SLOT_LOCK/pid" 2>/dev/null || true
}

slot_unlock() {
    rm -f "$SLOT_LOCK/pid" 2>/dev/null || true
    rmdir "$SLOT_LOCK" 2>/dev/null || true
}

slot_component_dir() {
    case "$1" in
        uecap|thermal) printf '%s/%s' "$SLOT_ROOT" "$1" ;;
        *) return 1 ;;
    esac
}

slot_current_value() {
    _slot_component_dir=$(slot_component_dir "$1") || return 1
    cat "$_slot_component_dir/active" 2>/dev/null | tr -d ' \n\r\t'
}

slot_pending_value() {
    _slot_component_dir=$(slot_component_dir "$1") || return 1
    cat "$_slot_component_dir/pending" 2>/dev/null | tr -d ' \n\r\t'
}

slot_inactive_value() {
    case "$(slot_current_value "$1")" in
        slot-a) printf slot-b ;;
        slot-b) printf slot-a ;;
        *) printf slot-a ;;
    esac
}

# Stage a regular-module source file.  mode=remove creates a tombstone so a
# previous overlay is removed during the next pre-mount promotion.
slot_stage_file() {
    _slot_component="$1"
    _slot_source="$2"
    _slot_rel="$3"
    _slot_mode="$4"
    _slot_device="$5"
    _slot_build="$6"
    _slot_context="$7"
    _slot_component_dir=$(slot_component_dir "$_slot_component") || return 1
    slot_init || return 1
    slot_lock || return 1
    _slot_cleanup=1
    _slot_slot=$(slot_inactive_value "$_slot_component")
    _slot_dir="$_slot_component_dir/$_slot_slot"
    _slot_file="$_slot_dir/payload"
    rm -f "$_slot_dir.tmp.$$"/* 2>/dev/null || true
    rmdir "$_slot_dir.tmp.$$" 2>/dev/null || true
    mkdir -p "$_slot_dir.tmp.$$" || { slot_unlock; return 1; }
    if [ "$_slot_mode" = remove ]; then
        : > "$_slot_dir.tmp.$$/remove" || { rm -f "$_slot_dir.tmp.$$"/*; rmdir "$_slot_dir.tmp.$$"; slot_unlock; return 1; }
        _slot_hash=none
    else
        [ -f "$_slot_source" ] || { rm -f "$_slot_dir.tmp.$$"/*; rmdir "$_slot_dir.tmp.$$"; slot_unlock; return 1; }
        cp -f "$_slot_source" "$_slot_dir.tmp.$$/payload" || { rm -f "$_slot_dir.tmp.$$"/*; rmdir "$_slot_dir.tmp.$$"; slot_unlock; return 1; }
        chmod 0644 "$_slot_dir.tmp.$$/payload" 2>/dev/null || true
        _slot_hash=$(slot_hash "$_slot_dir.tmp.$$/payload")
        [ -n "$_slot_hash" ] || { rm -f "$_slot_dir.tmp.$$"/*; rmdir "$_slot_dir.tmp.$$"; slot_unlock; return 1; }
    fi
    _slot_manifest=$(printf 'component=%s\nslot=%s\nmode=%s\nrelative=%s\ndevice=%s\nbuild=%s\ncontext=%s\nhash=%s\ncreated_boot=%s' \
        "$_slot_component" "$_slot_slot" "$_slot_mode" "$_slot_rel" "$_slot_device" \
        "$_slot_build" "$_slot_context" "$_slot_hash" \
        "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d ' \n\r\t')")
    slot_atomic_write "$_slot_dir.tmp.$$/manifest" "$_slot_manifest" \
        || { rm -f "$_slot_dir.tmp.$$"/*; rmdir "$_slot_dir.tmp.$$"; slot_unlock; return 1; }
    rm -f "$_slot_dir"/* 2>/dev/null || true
    rmdir "$_slot_dir" 2>/dev/null || true
    mv "$_slot_dir.tmp.$$" "$_slot_dir" || { rm -f "$_slot_dir.tmp.$$"/*; rmdir "$_slot_dir.tmp.$$"; slot_unlock; return 1; }
    slot_atomic_write "$_slot_component_dir/pending" "$_slot_slot" || { slot_unlock; return 1; }
    rm -f "$_slot_component_dir/rollback_pending" 2>/dev/null || true
    sync
    slot_unlock
    return 0
}

slot_promote_pending() {
    _slot_component="$1"
    _slot_target="$2"
    _slot_component_dir=$(slot_component_dir "$_slot_component") || return 1
    _slot_slot=$(slot_pending_value "$_slot_component")
    [ "$_slot_slot" = slot-a ] || [ "$_slot_slot" = slot-b ] || return 0
    _slot_dir="$_slot_component_dir/$_slot_slot"
    _slot_manifest="$_slot_dir/manifest"
    [ -r "$_slot_manifest" ] || return 1
    _slot_mode=$(sed -n 's/^mode=//p' "$_slot_manifest" | head -n 1)
    _slot_hash=$(sed -n 's/^hash=//p' "$_slot_manifest" | head -n 1)
    _slot_context=$(sed -n 's/^context=//p' "$_slot_manifest" | head -n 1)
    case "$_slot_context" in
        vendor_configs_file) _slot_context=u:object_r:vendor_configs_file:s0 ;;
        vendor_fw_file) _slot_context=u:object_r:vendor_fw_file:s0 ;;
    esac
    mkdir -p "${_slot_target%/*}" || return 1
    if [ "$_slot_mode" = remove ]; then
        rm -f "$_slot_target" || return 1
    else
        [ -f "$_slot_dir/payload" ] || return 1
        _slot_tmp="${_slot_target}.pending.$$"
        cp -f "$_slot_dir/payload" "$_slot_tmp" || return 1
        chmod 0644 "$_slot_tmp" || return 1
        if [ -n "$_slot_context" ] && [ "$_slot_context" != none ]; then
            chcon "$_slot_context" "$_slot_tmp" 2>/dev/null || return 1
            [ "$(ls -Zd "$_slot_tmp" 2>/dev/null | awk '{print $1}')" = "$_slot_context" ] || {
                rm -f "$_slot_tmp"
                return 1
            }
        fi
        [ "$(slot_hash "$_slot_tmp")" = "$_slot_hash" ] || { rm -f "$_slot_tmp"; return 1; }
        mv -f "$_slot_tmp" "$_slot_target" || return 1
    fi
    slot_atomic_write "$_slot_component_dir/active" "$_slot_slot" || return 1
    rm -f "$_slot_component_dir/pending" 2>/dev/null || true
    slot_atomic_write "$_slot_component_dir/promoted" "$_slot_slot" || return 1
    sync
    return 0
}

slot_mark_verified() {
    _slot_component_dir=$(slot_component_dir "$1") || return 1
    _slot_active=$(slot_current_value "$1")
    [ "$_slot_active" = slot-a ] || [ "$_slot_active" = slot-b ] || return 1
    slot_atomic_write "$_slot_component_dir/last-good" "$_slot_active" \
        && rm -f "$_slot_component_dir/promoted" 2>/dev/null
}

slot_mark_rollback_pending() {
    _slot_component_dir=$(slot_component_dir "$1") || return 1
    slot_atomic_write "$_slot_component_dir/rollback_pending" 1
}

slot_rollback_pending() {
    _slot_component_dir=$(slot_component_dir "$1") || return 1
    [ "$(cat "$_slot_component_dir/rollback_pending" 2>/dev/null | tr -d ' \n\r\t')" = 1 ]
}

slot_rollback_last_good() {
    _slot_component="$1"
    _slot_target="$2"
    _slot_component_dir=$(slot_component_dir "$_slot_component") || return 1
    _slot_good=$(cat "$_slot_component_dir/last-good" 2>/dev/null | tr -d ' \n\r\t')
    [ "$_slot_good" = slot-a ] || [ "$_slot_good" = slot-b ] || return 1
    _slot_dir="$_slot_component_dir/$_slot_good"
    _slot_mode=$(sed -n 's/^mode=//p' "$_slot_dir/manifest" | head -n 1)
    if [ "$_slot_mode" = remove ]; then
        rm -f "$_slot_target" || return 1
    else
        cp -f "$_slot_dir/payload" "${_slot_target}.rollback.$$" || return 1
        mv -f "${_slot_target}.rollback.$$" "$_slot_target" || return 1
    fi
    slot_atomic_write "$_slot_component_dir/active" "$_slot_good"
}
