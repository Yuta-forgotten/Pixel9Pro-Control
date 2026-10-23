#!/system/bin/sh
# Invoked by the trusted manager asset page. Keep the production CGI runtime
# on the root manager's BusyBox, just as its module hooks and httpd use it.
case "$1" in
    audit_log.sh|auth.sh|bg_restrict.sh|check_baseband.sh|info.sh|nr_switch.sh|ntp.sh|optimize.sh|owner_arbiter.sh|profile.sh|reboot.sh|set_thermal.sh|standby_guard.sh|status.sh|swap.sh|theme.sh|thermal.sh|uecap.sh) ;;
    *) exit 64 ;;
esac
_cd_root=${0%/scripts/cgi_dispatch.sh}
for _cd_bb in /data/adb/ap/bin/busybox /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /sbin/busybox; do
    [ -x "$_cd_bb" ] || continue
    export ASH_STANDALONE=1
    export PATH="${_cd_bb%/*}:/system/bin:/system/xbin:/vendor/bin"
    if [ "${REQUEST_METHOD:-}" = GET ]; then
        exec "$_cd_bb" timeout -k 1 60 "$_cd_bb" sh "$_cd_root/webroot/cgi-bin/$1"
    fi
    exec "$_cd_bb" sh "$_cd_root/webroot/cgi-bin/$1"
done
exit 127
