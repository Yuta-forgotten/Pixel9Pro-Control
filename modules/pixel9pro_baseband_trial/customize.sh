set_perm_recursive $MODPATH 0 0 0755 0644

detect_root_impl() {
    if [ "${APATCH:-}" = "true" ] || [ -d /data/adb/ap ]; then
        echo "APatch"
    elif [ "${KSU:-}" = "true" ] || [ -d /data/adb/ksu ]; then
        echo "KernelSU"
    elif [ -d /data/adb/magisk ]; then
        echo "Magisk"
    else
        echo "Unknown"
    fi
}

detect_ksu_metamodule() {
    for base in /data/adb/modules /data/adb/modules_update; do
        [ -d "$base" ] || continue
        for dir in "$base"/*; do
            [ -d "$dir" ] || continue
            _name=$(basename "$dir")
            case "$_name" in
                meta-overlayfs|meta_overlayfs|hybrid_mount|hybrid-mount|HybridMount|overlayfs|overlayfs_ksu)
                    echo "$_name"
                    return 0
                    ;;
            esac
            _prop="$dir/module.prop"
            [ -f "$_prop" ] || continue
            _id=$(sed -n 's/^id=//p' "$_prop" 2>/dev/null | head -n 1 | tr 'A-Z' 'a-z')
            _mod=$(sed -n 's/^name=//p' "$_prop" 2>/dev/null | head -n 1 | tr 'A-Z' 'a-z')
            case "$_id $_mod" in
                *meta-overlayfs*|*hybrid\ mount*|*overlayfs*)
                    echo "$_name"
                    return 0
                    ;;
            esac
        done
    done
    return 1
}

ROOT_IMPL=$(detect_root_impl)

ui_print ""
ui_print "  ▸ Pixel 9 Pro 基带配置模块"
ui_print ""
ui_print "  Root ............... $ROOT_IMPL"
ui_print "  VoLTE .............. 启用"
ui_print "  Wi-Fi Calling ...... 启用"
ui_print "  CarrierSettings .... 全球运营商配置"
ui_print "  China MCFG ......... 移动/联通/电信/广电"
ui_print ""
ui_print "  ⚠ UECap binarypb 由 pixel9pro_control 管理"
ui_print "  ⚠ 本模块不含 binarypb，两模块路径不冲突"
if [ "$ROOT_IMPL" = "KernelSU" ]; then
    _meta=$(detect_ksu_metamodule)
    if [ -n "$_meta" ]; then
        ui_print "  ✓ KSU metamodule ... $_meta"
    else
        ui_print "  ⚠ 未检测到常见 KSU metamodule"
        ui_print "    本模块虽可安装，但 CarrierSettings / MCFG overlay"
        ui_print "    在 KernelSU 下可能不会真正挂载"
        ui_print "    建议先安装 meta-overlayfs / Hybrid Mount 并重启"
        ui_print "    然后再回来覆盖安装本模块"
    fi
fi
ui_print ""
