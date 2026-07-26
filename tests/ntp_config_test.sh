#!/system/bin/sh

SOURCE_ROOT="$1"
TEST_ROOT="$2"
LIB="$SOURCE_ROOT/scripts/ntp_config_lib.sh"
NTP_CONFIG_FILE="$SOURCE_ROOT/config/ntp_servers.tsv"
PASS=0
FAIL=0
TOTAL=0

ok() { TOTAL=$((TOTAL + 1)); PASS=$((PASS + 1)); printf 'ok %s - %s\n' "$TOTAL" "$1"; }
not_ok() { TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1)); printf 'not ok %s - %s\n' "$TOTAL" "$1"; }

mkdir -p "$TEST_ROOT" || exit 2
. "$LIB" || exit 2
printf 'TAP version 13\n'

if ntp_config_validate; then ok 'catalog validates'; else not_ok 'catalog validates'; fi
[ "$(ntp_server_default)" = 'ntp.aliyun.com' ] && ok 'default comes from catalog' || not_ok 'default comes from catalog'
[ "$(ntp_server_hosts | wc -l | tr -d ' ')" = '4' ] && ok 'catalog exposes four hosts' || not_ok 'catalog exposes four hosts'
ntp_server_is_allowed time.android.com && ok 'known host is allowed' || not_ok 'known host is allowed'
if ntp_server_is_allowed invalid.example; then not_ok 'unknown host is rejected'; else ok 'unknown host is rejected'; fi
_json=$(ntp_servers_json)
case "$_json" in
    *'"id":"ntp.aliyun.com"'*'"name":"阿里云"'*) ok 'catalog renders JSON' ;;
    *) not_ok 'catalog renders JSON' ;;
esac

_bad="$TEST_ROOT/ntp_invalid.tsv"
cp "$NTP_CONFIG_FILE" "$_bad" || exit 2
printf 'ntp.aliyun.com\tduplicate\tduplicate default\tyes\n' >> "$_bad"
NTP_CONFIG_FILE="$_bad"
if ntp_config_validate; then not_ok 'duplicate/default conflict is rejected'; else ok 'duplicate/default conflict is rejected'; fi

printf '1..%s\n' "$TOTAL"
printf '# pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
