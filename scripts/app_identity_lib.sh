#!/system/bin/sh
# UID/package identity helpers. The TSV catalog is parsed as data and is never
# sourced or evaluated as shell code.

APP_IDENTITY_FILE="${APP_IDENTITY_FILE:-$MODDIR/config/app_identities.tsv}"

app_identity_parse_row() {
    _identity_raw=$(printf '%s' "$1" | tr -d '\r')
    _identity_old_ifs="$IFS"
    IFS='|'
    set -- $_identity_raw
    IFS="$_identity_old_ifs"
    _identity_kind="$1"
    _identity_key="$2"
    _identity_label="$3"
    _identity_category="$4"
    _identity_restriction_tier="$5"
    _identity_canonical="$6"
}

app_identity_lookup_row() {
    _lookup_kind="$1"
    _lookup_key="$2"
    [ -s "$APP_IDENTITY_FILE" ] || return 1
    awk -F'[|]' -v kind="$_lookup_kind" -v key="$_lookup_key" '
        $0 !~ /^#/ && $1 == kind && $2 == key { print; found=1; exit }
        END { exit found ? 0 : 1 }
    ' "$APP_IDENTITY_FILE" 2>/dev/null
}

app_identity_load_package() {
    _identity_row=$(app_identity_lookup_row package "$1") || _identity_row=""
    if [ -n "$_identity_row" ]; then
        app_identity_parse_row "$_identity_row"
        return 0
    fi
    _identity_kind="package"
    _identity_key="$1"
    _identity_label=""
    _identity_category=""
    _identity_restriction_tier="hidden"
    _identity_canonical=""
    return 1
}
