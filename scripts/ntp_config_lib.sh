#!/system/bin/sh

# NTP allowlist helpers shared by installer, boot service, and CGI.
# The TSV catalog is the only host/default source; consumers never source it.

NTP_CONFIG_FILE="${NTP_CONFIG_FILE:-$MODDIR/config/ntp_servers.tsv}"

ntp_config_validate() {
    awk '
        BEGIN { FS="\t"; valid=1; rows=0; defaults=0 }
        /^#/ || /^[ \t]*$/ { next }
        {
            rows++
            if (NF != 4 || $1 !~ /^[A-Za-z0-9.-]+$/ || $2 == "" || $3 == "") valid=0
            if ($4 != "yes" && $4 != "no") valid=0
            if (seen[$1]++) valid=0
            if ($4 == "yes") defaults++
        }
        END { exit (valid && rows > 0 && defaults == 1) ? 0 : 1 }
    ' "$NTP_CONFIG_FILE" 2>/dev/null
}

ntp_server_default() {
    _ntp_default=$(awk 'BEGIN { FS="\t" } $0 !~ /^#/ && $4 == "yes" { print $1; exit }' "$NTP_CONFIG_FILE" 2>/dev/null)
    [ -n "$_ntp_default" ] || return 1
    printf '%s' "$_ntp_default"
}

ntp_server_is_allowed() {
    [ -n "$1" ] || return 1
    awk -v host="$1" '
        BEGIN { FS="\t" }
        $0 !~ /^#/ && $1 == host { found=1; exit }
        END { exit found ? 0 : 1 }
    ' "$NTP_CONFIG_FILE" 2>/dev/null
}

ntp_server_normalize() {
    if ntp_server_is_allowed "$1"; then
        printf '%s' "$1"
    else
        ntp_server_default
    fi
}

ntp_server_hosts() {
    awk 'BEGIN { FS="\t" } $0 !~ /^#/ && NF == 4 { print $1 }' "$NTP_CONFIG_FILE" 2>/dev/null
}

ntp_server_label() {
    awk -v host="$1" 'BEGIN { FS="\t" } $0 !~ /^#/ && $1 == host { print $2; exit }' "$NTP_CONFIG_FILE" 2>/dev/null
}

ntp_servers_json() {
    awk '
        BEGIN { FS="\t"; printf "[" }
        function esc(value) {
            gsub(/\\/, "\\\\", value)
            gsub(/"/, "\\\"", value)
            return value
        }
        $0 !~ /^#/ && NF == 4 {
            if (count++) printf ","
            printf "{\"id\":\"%s\",\"name\":\"%s\",\"desc\":\"%s\"}", esc($1), esc($2), esc($3)
        }
        END { printf "]" }
    ' "$NTP_CONFIG_FILE" 2>/dev/null
}
