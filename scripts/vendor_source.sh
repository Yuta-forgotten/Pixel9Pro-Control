#!/system/bin/sh
# Read this device's original vendor files in a private mount namespace.
# Only this short-lived process loses module overlays; init/apps keep theirs.

if [ "${1:-}" != --isolated ]; then
    exec /system/bin/unshare -m /system/bin/sh "$0" --isolated "$@"
fi
shift
action="${1:---memory}"
[ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ] || exit 1
/system/bin/mount -o rprivate none / || exit 1
while :; do
    target=$(awk '$0 ~ / - overlay / && ($5=="/vendor" || index($5,"/vendor/")==1) {
        # Newer covering mounts hide older submounts. Remove the newest layer
        # first so a hidden lower /vendor/etc is not unmounted prematurely.
        if($1>mount_id) {mount_id=$1;target=$5}
    } END {print target}' /proc/self/mountinfo)
    [ -n "$target" ] || break
    /system/bin/umount "$target" || exit 1
done
source=$(awk '$2=="/vendor" && $4 ~ /^ro,/ && ($3=="ext4" || $3=="erofs") {print $1;exit}' /proc/mounts)
[ -n "$source" ] || exit 1
if [ "$action" = --file ]; then
    case "${2:-}" in /vendor/etc/*) ;; *) printf 'source path must be under /vendor/etc\n' >&2; exit 2 ;; esac
    case "$2" in *'..'*|*'//'*) printf 'invalid source path\n' >&2; exit 2 ;; esac
    exec /system/bin/cat "$2"
fi
[ "$action" = --memory ] || { printf 'unknown original-source request\n' >&2; exit 2; }
printf 'schema=3\ndevice=%s\nfingerprint=%s\npage_size=%s\nsource=original_vendor_namespace\nsource_device=%s\n' \
    "$(getprop ro.product.device)" "$(getprop ro.build.fingerprint)" "$(getconf PAGESIZE)" "$source"
awk -v page="$(getconf PAGESIZE)" '
    $1=="setprop" && $2=="mmd.zram.size" && $3 ~ /zram_swap_size_v2:-/ {
        value=$3;sub(/^.*:-/,"",value);sub(/}.*/,"",value);size=value
    }
    $1=="setprop" && $2=="mmd.zram.comp_algorithm" && $3 ~ /zram_comp_algorithm:-/ {
        value=$3;sub(/^.*:-/,"",value);sub(/}.*/,"",value);algorithm=value
    }
    $1=="write" && $2=="/proc/sys/vm/swappiness" {sw=$3}
    $1=="write" && $2=="/proc/sys/vm/min_free_kbytes" {mfk=$3}
    $1=="write" && $2=="/proc/sys/vm/watermark_scale_factor" {wsf=$3}
    END {
        if(size=="" || sw=="" || mfk=="" || wsf=="") exit 1
        # The board explicitly selects lzo-rle instead of EH on 16K kernels.
        if(page==16384) algorithm="lzo-rle"
        if(algorithm=="") exit 1
        printf "size=%s\nalgorithm=%s\nswappiness=%s\nmin_free_kbytes=%s\nwatermark_scale_factor=%s\n",size,algorithm,sw,mfk,wsf
        # Kernel dcache default; checked against this kernel commit and the
        # Linux VM documentation. It is not a value sampled from /proc/sys.
        printf "vfs_cache_pressure=100\nvfs_source=kernel_dcache_default\n"
    }' /vendor/etc/init/hw/init.*.board.rc /vendor/etc/init/init.pixel-mm-gs.rc \
        /vendor/etc/init/pixel-mm-gki.rc /vendor/etc/init/init.watermark-scale-factor.rc || exit 1
