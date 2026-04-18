#!/system/bin/sh
##############################################################
# CGI: /cgi-bin/energy.sh
# GET → 按需解析 dumpsys batterystats, 返回功耗摘要和 Top 10 应用
# 执行约 2-3s, 仅用户点击时调用, 不参与轮询
# batterystats 输出可达数 MB, 全程使用管道和临时文件, 不存变量
##############################################################
. "${PIXEL9PRO_MODDIR:-/data/adb/modules/pixel9pro_control}/webroot/cgi-bin/_common.sh"
require_loopback
[ "$REQUEST_METHOD" = "GET" ] || json_error '405 Method Not Allowed' 'GET only'
json_headers

_tmp="/data/local/tmp/.energy_$$"
trap 'rm -f "${_tmp}"_*' EXIT

pm list packages -U 2>/dev/null > "${_tmp}_pkg"

dumpsys batterystats 2>/dev/null | awk '
/^  Estimated power use/,/^  *\(/ { print "EST:" $0 }
/^  UID / { print "UID:" $0 }
/Time on battery:/ && !seen_bat { print "BAT:" $0; seen_bat=1 }
/Screen off discharge:/ && !seen_soff { print "SOFF:" $0; seen_soff=1 }
/Screen on discharge:/ && !seen_son { print "SON:" $0; seen_son=1 }
' > "${_tmp}_bs"

awk -v pkgfile="${_tmp}_pkg" '
BEGIN {
    while ((getline line < pkgfile) > 0) {
        sub(/^package:/, "", line)
        split(line, p, " uid:")
        if (p[2]+0 > 0) pm[p[2]+0] = p[1]
    }
    close(pkgfile)
    an = 0
}

/^BAT:/ { sub(/.*battery: /, ""); sub(/ \(.*/, ""); bat_time = $0; next }
/^SOFF:/ { match($0, /[0-9]+/); scroff = substr($0, RSTART, RLENGTH)+0; next }
/^SON:/ { match($0, /[0-9]+/); scron = substr($0, RSTART, RLENGTH)+0; next }

/^EST:/ {
    line = substr($0, 5)
    if (line ~ /Capacity:/) {
        n = split(line, w, " ")
        for (i = 1; i <= n; i++) {
            if (w[i] == "Capacity:") { v = w[i+1]; gsub(/,/, "", v); cap = v+0 }
            if (w[i] == "drain:" && w[i-1] == "Computed") { v = w[i+1]; gsub(/,/, "", v); drain = v+0 }
        }
    }
    if (line ~ /^    screen:/ && !gs) { split(line, w); gs = w[2]+0 }
    if (line ~ /^    cpu:/ && !gc) { split(line, w); gc = w[2]+0 }
    if (line ~ /^    mobile_radio:/ && !gm) { split(line, w); gm = w[2]+0 }
    if (line ~ /^    wifi:/ && !gw) { split(line, w); gw = w[2]+0 }
    if (line ~ /^    wakelock:/ && !gk) { split(line, w); gk = w[2]+0 }
    next
}

/^UID:/ {
    line = substr($0, 5)
    split(line, w)
    uid_s = w[2]; gsub(/:/, "", uid_s)
    mah = w[3]+0
    if (index(uid_s, "u0a") == 1) { n = uid_s; sub(/u0a/, "", n); n = n+10000 }
    else { n = uid_s+0 }
    pk = pm[n]
    if (pk == "") {
        if (n == 0) pk = "android (root)"
        else if (n == 1000) pk = "android (system)"
        else if (n == 1001) pk = "android (radio)"
        else pk = uid_s
    }
    ap[an] = pk; am[an] = mah; an++
    next
}

END {
    gsub(/"/, "\\\"", bat_time)
    printf "{\"cap\":%d,\"drain\":%.0f,\"scroff\":%d,\"scron\":%d,\"bat_time\":\"%s\",", cap, drain, scroff, scron, bat_time
    printf "\"screen\":%.0f,\"cpu\":%.0f,\"cell\":%.0f,\"wifi\":%.0f,\"wakelock\":%.0f,\"apps\":[", gs, gc, gm, gw, gk
    top = an; if (top > 10) top = 10
    for (i = 0; i < top; i++) {
        if (i) printf ","
        gsub(/"/, "\\\"", ap[i])
        printf "{\"pkg\":\"%s\",\"mah\":%.0f}", ap[i], am[i]
    }
    printf "]}"
}
' "${_tmp}_bs"
