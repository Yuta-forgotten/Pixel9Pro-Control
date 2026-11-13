#!/system/bin/sh
# Explicit, one-shot system resolver cache invalidation. No network settings,
# third-party resolver state, firewall rules or persistent preferences change.
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"

require_loopback
require_json_post
read_json_body 128
cgi_json_schema 'action:string'
[ "$(cgi_json_field action)" = clear ] \
    || json_error '400 Bad Request' '无效的 DNS 缓存操作'
acquire_lock dns_cache

DNS_TOTAL=0
DNS_CLEARED=0
DNS_UNCONFIRMED=false
CGI_AUDIT_OPERATION=dns_cache_clear

dns_error() {
    _dns_status="$1"
    _dns_code="$2"
    _dns_message="$3"
    json_status_headers "$_dns_status"
    printf '{"ok":false,"action":"clear","scope":"system","completed":false,"cleared_networks":%s,"total_networks":%s,"result_unconfirmed":%s,"error_code":"%s","error":"%s","duration_ms":%s}\n' \
        "$DNS_CLEARED" "$DNS_TOTAL" "$DNS_UNCONFIRMED" "$_dns_code" \
        "$(json_escape "$_dns_message")" "$(cgi_duration_ms)"
    audit_log_event_async cgi "$CGI_AUDIT_OPERATION" failure "$_dns_code" "$(cgi_duration_ms)"
    exit 0
}

# service(1) prints the Binder reply as hex words plus an ASCII column. Require
# the complete Parcel and validate its exception header, not the process status.
dns_parcel_words() {
    LC_ALL=C awk '
        /^Result: Parcel\(/ {
            if (started++) bad=1
            sub(/^Result: Parcel\(/, "")
        }
        started {
            if ($0 ~ /\)[[:space:]]*$/) finished=1
            sub(/\047.*$/, "")
            sub(/^[[:space:]]*0x[[:xdigit:]]+:[[:space:]]*/, "")
            gsub(/[()]/, "")
            for (i=1;i<=NF;i++) {
                word=tolower($i)
                if (length(word)!=8 || word !~ /^[0-9a-f]+$/) bad=1
                else words=words (count++ ? " " : "") word
            }
        }
        END {
            if (bad || started!=1 || !finished || !count) exit 1
            print words
        }
    '
}

DNS_SERVICE_BIN=/system/bin/service
DNS_DUMPSYS_BIN=/system/bin/dumpsys
for _dns_bin in "$DNS_SERVICE_BIN" "$DNS_DUMPSYS_BIN"; do
    [ -x "$_dns_bin" ] \
        || dns_error '503 Service Unavailable' DNS_SERVICE_UNAVAILABLE '系统 DNS 清理服务不可用'
done
command -v timeout >/dev/null 2>&1 \
    || dns_error '503 Service Unavailable' DNS_SERVICE_UNAVAILABLE '系统 DNS 清理服务不可用'

# Keep the entire operation below the existing 30s frontend mutation deadline,
# including the shared body-reader budget. There is no automatic retry.
IFS=' ' read -r _dns_started _dns_unused < /proc/uptime
DNS_DEADLINE=$((${_dns_started%%.*} + 20))
dns_remaining() {
    IFS=' ' read -r _dns_now _dns_unused < /proc/uptime
    DNS_REMAINING=$((DNS_DEADLINE - ${_dns_now%%.*}))
    [ "$DNS_REMAINING" -gt 0 ]
}

_dns_services=$(timeout -k 1 3 "$DNS_SERVICE_BIN" list 2>/dev/null) \
    || dns_error '503 Service Unavailable' DNS_SERVICE_UNAVAILABLE '无法读取系统 DNS 服务'
printf '%s\n' "$_dns_services" | awk '
    $2=="dnsresolver:" && $3=="[android.net.IDnsResolver]" { found=1 }
    END { exit !found }
' || dns_error '503 Service Unavailable' DNS_INTERFACE_UNSUPPORTED '当前系统不支持此清理方式'

# Frozen IDnsResolver V4 introduced flushNetworkCache as method 11. Stable
# AIDL preserves existing method IDs in subsequent versions (device: V18).
# https://android.googlesource.com/platform/packages/modules/DnsResolver/+/refs/heads/android17-release/aidl_api/dnsresolver_aidl_interface/4/android/net/IDnsResolver.aidl
# https://source.android.com/docs/core/architecture/aidl/stable-aidl#versioning-interfaces
DNS_GET_INTERFACE_VERSION=16777215
DNS_FLUSH_NETWORK_CACHE=11
_dns_reply=$(timeout -k 1 3 "$DNS_SERVICE_BIN" call dnsresolver "$DNS_GET_INTERFACE_VERSION" 2>/dev/null) \
    || dns_error '503 Service Unavailable' DNS_INTERFACE_UNAVAILABLE '无法读取系统 DNS 清理能力'
_dns_words=$(printf '%s\n' "$_dns_reply" | dns_parcel_words) \
    || dns_error '503 Service Unavailable' DNS_INTERFACE_UNAVAILABLE '无法确认系统 DNS 清理能力'
set -- $_dns_words
[ "$#" -eq 2 ] && [ "$1" = 00000000 ] \
    || dns_error '503 Service Unavailable' DNS_INTERFACE_UNAVAILABLE '无法确认系统 DNS 清理能力'
_dns_version=$(printf '%d' "0x$2")
[ "$_dns_version" -ge 4 ] && [ "$_dns_version" -le 2147483647 ] \
    || dns_error '503 Service Unavailable' DNS_INTERFACE_UNSUPPORTED '当前系统不支持此清理方式'

# dumpsys can exit 0 after its own timeout with a partial listing. Keep that
# timeout longer than the outer deadline, which produces a failing exit status.
_dns_dump=$(timeout -k 1 4 "$DNS_DUMPSYS_BIN" -t 10 dnsresolver 2>/dev/null) \
    || dns_error '503 Service Unavailable' DNS_NETWORKS_UNAVAILABLE '无法读取系统 DNS 缓存'
# Network IDs come only from the resolver owner, never from a request or a
# saved default network. A disconnect during clearing is reported as incomplete.
_dns_networks=$(printf '%s\n' "$_dns_dump" | LC_ALL=C awk '
    /^NetId:/ {
        if (NF!=2 || $2 !~ /^[0-9]+$/ || $2<1 || $2>65535) { bad=1; next }
        id=sprintf("%d",$2)
        if (!seen[id]++) print id
    }
    END { if (bad) exit 1 }
') || dns_error '503 Service Unavailable' DNS_NETWORKS_INVALID '无法确认系统 DNS 缓存范围'
[ -n "$_dns_networks" ] \
    || dns_error '409 Conflict' DNS_NO_NETWORKS '当前没有可清理的系统 DNS 缓存'
for _dns_net in $_dns_networks; do DNS_TOTAL=$((DNS_TOTAL + 1)); done

for _dns_net in $_dns_networks; do
    dns_remaining \
        || dns_error '503 Service Unavailable' DNS_CLEAR_TIMEOUT '清理未全部完成，请稍后检查'
    if ! _dns_reply=$(timeout -k 1 "$DNS_REMAINING" "$DNS_SERVICE_BIN" call dnsresolver "$DNS_FLUSH_NETWORK_CACHE" i32 "$_dns_net" 2>/dev/null); then
        # Killing the client cannot cancel a Binder call already accepted by
        # the service. Do not claim failure or replay an unconfirmed operation.
        DNS_UNCONFIRMED=true
        dns_error '503 Service Unavailable' DNS_CLEAR_UNCONFIRMED '清理结果未确认，请稍后检查'
    fi
    if ! _dns_words=$(printf '%s\n' "$_dns_reply" | dns_parcel_words); then
        DNS_UNCONFIRMED=true
        dns_error '503 Service Unavailable' DNS_CLEAR_UNCONFIRMED '清理结果未确认，请稍后检查'
    fi
    if [ "$_dns_words" != 00000000 ]; then
        case "$_dns_words" in
            ffffffff\ *)
                dns_error '503 Service Unavailable' DNS_CLEAR_DENIED '系统未允许清理 DNS 缓存' ;;
            fffffff8\ *|fffffff9\ *)
                dns_error '503 Service Unavailable' DNS_CLEAR_FAILED '系统未完成清理，请检查网络连接后重试' ;;
            *)
                DNS_UNCONFIRMED=true
                dns_error '503 Service Unavailable' DNS_CLEAR_UNCONFIRMED '清理结果未确认，请稍后检查' ;;
        esac
    fi
    DNS_CLEARED=$((DNS_CLEARED + 1))
done

# flushNetworkCache is synchronous: a void Binder OK is the service completion
# receipt. A second dump cannot prove an empty cache while apps keep resolving.
# Cache invalidation has no rollback and no persistent setting to commit.
json_headers
printf '{"ok":true,"action":"clear","scope":"system","completed":true,"cleared_networks":%s,"total_networks":%s,"duration_ms":%s}\n' \
    "$DNS_CLEARED" "$DNS_TOTAL" "$(cgi_duration_ms)"
audit_log_event_async cgi "$CGI_AUDIT_OPERATION" success dns_cache_cleared "$(cgi_duration_ms)"
