#!/system/bin/sh
# One-shot browser capability bootstrap. Kernel socket UID + a local package
# trust list identifies the app; exact Origin/Host prevents web-origin CSRF.
# No watcher, periodic package scan, extra service, or client prompt is needed.

browser_session_peer_uid() {
    case "${REMOTE_PORT:-}" in ''|*[!0-9]*|0) return 1 ;; esac
    [ "$REMOTE_PORT" -le 65535 ] 2>/dev/null || return 1
    _bs_client_port=$(printf '%04X' "$REMOTE_PORT") || return 1
    _bs_server_port=$(printf '%04X' "$WEBUI_PORT") || return 1
    awk -v client="$_bs_client_port" -v server="$_bs_server_port" '
        function loopback(address) {
            return address=="0100007F" || address=="0000000000000000FFFF00000100007F" || address=="00000000000000000000000001000000"
        }
        $4=="01" && $8 ~ /^[0-9]+$/ {
            split($2,local,":"); split($3,remote,":")
            if (local[2]==client && remote[2]==server && loopback(local[1]) && loopback(remote[1])) owners[$8]=1
        }
        END { for (uid in owners) { result=uid; count++ }; if (count!=1) exit 1; print result }
    ' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

browser_session_authorize() {
    BROWSER_SESSION_ERROR=browser_identity_unavailable
    _bs_uid=$(browser_session_peer_uid) || return 1
    case "$_bs_uid" in ''|*[!0-9]*) return 1 ;; esac
    _bs_config="$MODDIR/config/webui_browsers.tsv"
    [ -f "$_bs_config" ] && [ -r "$_bs_config" ] && [ ! -L "$_bs_config" ] || return 1
    _bs_packages=$(timeout -k 1 4 /system/bin/pm list packages -U --user 0 2>/dev/null) || return 1
    [ -n "$_bs_packages" ] || return 1
    BROWSER_SESSION_ERROR=browser_not_trusted
    printf '%s\n' "$_bs_packages" | awk -v uid="$_bs_uid" '
        NR==FNR { if ($0 !~ /^#/ && $0!="") { split($0,row,"|"); trusted[row[1]]=1 }; next }
        /^package:/ {
            n=split($0,fields," "); package=fields[1]; sub(/^package:/,"",package)
            for (i=2;i<=n;i++) if (fields[i]=="uid:" uid && trusted[package]) found=1
        }
        END { exit found ? 0 : 1 }
    ' "$_bs_config" -
}
