#!/system/bin/sh

# Verified adapter for the observed meta-overlayfs 1.3.1 install hook.
# Never replace a live content tree. Copy into an isolated sibling, check
# every regular file and its canonical vendor label, then rename once.

meta_module_hash() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

meta_module_check_tree() {
    _mm_src="$1"
    _mm_dst="$2"
    [ -d "$_mm_src" ] && [ -d "$_mm_dst" ] || return 1
    find "$_mm_src" -type f -print | while IFS= read -r _mm_file; do
        _mm_rel=${_mm_file#"$_mm_src/"}
        _mm_copy="$_mm_dst/$_mm_rel"
        [ -f "$_mm_copy" ] || exit 1
        [ "$(meta_module_hash "$_mm_file")" = "$(meta_module_hash "$_mm_copy")" ] || exit 1
        case "${_mm_src##*/}/$_mm_rel" in
            vendor/etc/thermal_info_config.json|system/vendor/etc/thermal_info_config.json)
                _mm_ctx=u:object_r:vendor_configs_file:s0 ;;
            vendor/firmware/uecapconfig/*.binarypb|system/vendor/firmware/uecapconfig/*.binarypb)
                _mm_ctx=u:object_r:vendor_fw_file:s0 ;;
            *) exit 1 ;;
        esac
        chcon "$_mm_ctx" "$_mm_copy" 2>/dev/null || exit 1
        [ "$(ls -Zd "$_mm_copy" 2>/dev/null | awk '{print $1}')" = "$_mm_ctx" ] || exit 1
        chmod 0644 "$_mm_copy" || exit 1
    done
}

meta_module_copy_content() (
    [ "${MODID:-}" = pixel9pro_control ] || return 1
    _mm_mount="${MNT_DIR:-/data/adb/metamodule/mnt}"
    mountpoint -q "$_mm_mount" || return 1
    _mm_final="$_mm_mount/pixel9pro_control"
    [ ! -e "$_mm_final" ] && [ ! -L "$_mm_final" ] || return 1
    _mm_lock="$_mm_mount/.pixel9pro_control.install.lock"
    mkdir "$_mm_lock" || return 1
    _mm_work="$_mm_mount/.pixel9pro_control.install.$$"
    [ ! -e "$_mm_work" ] && [ ! -L "$_mm_work" ] || { rmdir "$_mm_lock"; return 1; }
    trap 'rm -rf "$_mm_work"; rmdir "$_mm_lock" 2>/dev/null' EXIT
    mkdir "$_mm_work" || return 1
    chmod 0755 "$_mm_mount" "$_mm_work" || return 1
    for _mm_partition in system vendor; do
        [ -d "$MODPATH/$_mm_partition" ] || continue
        cp -af "$MODPATH/$_mm_partition" "$_mm_work/" || return 1
        copy_selinux_contexts "$MODPATH/$_mm_partition" "$_mm_work/$_mm_partition"
        meta_module_check_tree "$MODPATH/$_mm_partition" "$_mm_work/$_mm_partition" || return 1
    done
    find "$_mm_work" -type d -exec chmod 0755 '{}' \; || return 1
    find "$_mm_work" -type l -print | while IFS= read -r _mm_link; do
        [ "$_mm_link" = "$_mm_work/system/vendor" ] \
            && [ "$(readlink "$_mm_link")" = ../vendor ] || exit 1
    done || return 1
    for _mm_vendor in "$_mm_work/vendor" "$_mm_work/system/vendor"; do
        [ -d "$_mm_vendor" ] || continue
        chcon u:object_r:vendor_file:s0 "$_mm_vendor" || return 1
        if [ -d "$_mm_vendor/etc" ]; then
            chcon -R u:object_r:vendor_configs_file:s0 "$_mm_vendor/etc" || return 1
        fi
        if [ -d "$_mm_vendor/firmware" ]; then
            chcon -R u:object_r:vendor_fw_file:s0 "$_mm_vendor/firmware" || return 1
        fi
    done
    sync || return 1
    [ ! -e "$_mm_final" ] && [ ! -L "$_mm_final" ] || return 1
    mv "$_mm_work" "$_mm_final" || return 1
    ui_print "- Control content image verified and committed"
)

meta_module_prepare_hook() {
    _mm_target="$1"
    _mm_hook="$_mm_target/metainstall.sh"
    _mm_marker='# pixel9pro-meta-context-v2'
    [ -d "$_mm_target" ] && [ -f "$_mm_hook" ] || return 1
    [ "$(sed -n 's/^id=//p' "$_mm_target/module.prop" | tr -d '\r')" = meta-overlayfs ] || return 2
    [ "$(sed -n 's/^versionCode=//p' "$_mm_target/module.prop" | tr -d '\r')" = 13100 ] || return 2
    _mm_current_hash=$(meta_module_hash "$_mm_hook")
    _mm_original_hash=faadbf01b84638d3d11f806d4ede5fac421192d8f4d31d8c17e279cc62aa2dc3
    _mm_v1_hash=45099d5e419a0781fd44b553f2c789c7984915b4c32db3545e593ab4626ab63d

    _mm_backup="$_mm_target/metainstall.sh.codex.orig"
    if [ ! -e "$_mm_backup" ]; then
        [ "$_mm_current_hash" = "$_mm_original_hash" ] || return 2
        cp -p "$_mm_hook" "$_mm_backup" || return 1
    fi
    [ "$(meta_module_hash "$_mm_backup")" = "$_mm_original_hash" ] || return 2
    _mm_tmp="$_mm_hook.codex.tmp.$$"
    sed \
        -e "1a\\$_mm_marker" \
        -e 's/set_perm "$MNT_DIR" 0 0 0755 0644/chmod 0755 "$MNT_DIR"/' \
        -e 's/set_perm "$MOD_IMG_DIR" 0 0 0755 0644/chmod 0755 "$MOD_IMG_DIR"/' \
        -e '/^    post_install_to_image$/c\    if [ "$MODID" = pixel9pro_control ]; then\n        . "$MODPATH/scripts/metamodule_compat.sh" || abort "Control adapter missing"\n        meta_module_copy_content || abort "Control content verification failed"\n    else\n        post_install_to_image\n    fi' \
        "$_mm_backup" > "$_mm_tmp" || { rm -f "$_mm_tmp"; return 1; }
    _mm_expected_hash=$(meta_module_hash "$_mm_tmp")
    case "$_mm_current_hash" in
        "$_mm_original_hash"|"$_mm_v1_hash"|"$_mm_expected_hash") ;;
        *) rm -f "$_mm_tmp"; return 2 ;;
    esac
    if ! sh -n "$_mm_tmp" || ! chmod 0755 "$_mm_tmp" \
        || ! chcon --reference="$_mm_hook" "$_mm_tmp"; then
        rm -f "$_mm_tmp"; return 1
    fi
    META_HOOK_PREVIOUS="$_mm_hook.previous.$$"
    META_HOOK_PATH="$_mm_hook"
    META_HOOK_EXPECTED_HASH="$_mm_expected_hash"
    cp -ap "$_mm_backup" "$META_HOOK_PREVIOUS" || { rm -f "$_mm_tmp"; return 1; }
    mv "$_mm_tmp" "$_mm_hook" || { rm -f "$_mm_tmp"; return 1; }
    [ "$(meta_module_hash "$_mm_hook")" = "$_mm_expected_hash" ] || return 1
    # The old hook may already be sourced by the installer in this process.
    post_install_to_image() {
        meta_module_copy_content || abort "Control content verification failed"
    }
}

meta_module_finish_hook() {
    [ -n "${META_HOOK_PREVIOUS:-}" ] && [ -f "$META_HOOK_PREVIOUS" ] || return 0
    if [ "$1" = success ]; then
        rm -f "$META_HOOK_PREVIOUS"
        return $?
    fi
    [ "$(meta_module_hash "$META_HOOK_PATH")" = "$META_HOOK_EXPECTED_HASH" ] || return 1
    _mm_restore_hash=$(meta_module_hash "$META_HOOK_PREVIOUS")
    mv "$META_HOOK_PREVIOUS" "$META_HOOK_PATH" || return 1
    [ "$(meta_module_hash "$META_HOOK_PATH")" = "$_mm_restore_hash" ]
}
