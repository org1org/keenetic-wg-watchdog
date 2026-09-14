#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
WORKER="$REPO_DIR/keenetic-wg-watchdog.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/keenetic-wg-tests.XXXXXX")
PASS_COUNT=0
TEST_SHELL=${TEST_SHELL:-dash}
[ "$TEST_SHELL" != busybox ] || TEST_SHELL='busybox sh'
trap 'rm -rf "$TEST_ROOT"' EXIT HUP INT TERM

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'ok %s - %s\n' "$PASS_COUNT" "$1"
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    grep -F -- "$2" "$1" >/dev/null 2>&1 || fail "$3: нет '$2'"
}

assert_empty() {
    [ ! -s "$1" ] || fail "$2"
}

new_case() {
    CASE_DIR="$TEST_ROOT/case-$((PASS_COUNT + 1))"
    CONFIG_DIR="$CASE_DIR/config"
    STATE_DIR="$CASE_DIR/state"
    RUN_DIR="$CASE_DIR/run"
    MOCK_DIR="$CASE_DIR/mock"
    MOCK_BIN="$CASE_DIR/bin"
    mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$RUN_DIR" "$MOCK_DIR" "$MOCK_BIN"
    for mock in ndmc ping curl logger sleep date; do
        cp "$SCRIPT_DIR/mocks/$mock" "$MOCK_BIN/$mock"
    done
    chmod 755 "$MOCK_BIN"/*
    : > "$MOCK_DIR/ping.log"
    : > "$MOCK_DIR/curl.log"
    : > "$MOCK_DIR/logger.log"
    : > "$MOCK_DIR/sleep.log"
}

write_config() {
    enabled=${1:-yes}
    {
        printf 'JOB_ID=Wireguard0-test\n'
        printf 'LOCAL_INTERFACE=Wireguard0\n'
        printf 'PEER_PUBLIC_KEY_B64=%s\n' "$(printf 'test-peer-public-key' | base64 | tr -d '\n')"
        printf 'TARGET_IP=172.16.6.2\n'
        printf 'ROUTER_URL_B64=%s\n' "$(printf 'https://198.51.100.20:8443' | base64 | tr -d '\n')"
        printf 'ROUTER_USER_B64=%s\n' "$(printf 'watchdog' | base64 | tr -d '\n')"
        printf 'ROUTER_PASSWORD_B64=%s\n' "$(printf 'secret! password' | base64 | tr -d '\n')"
        printf 'REMOTE_INTERFACE=Wireguard0\n'
        printf 'PING_COUNT=3\nPING_TIMEOUT=3\nFAILURE_THRESHOLD=2\n'
        printf 'RESTART_DELAY=3\nRECOVERY_CHECK_DELAY=15\nRESTART_COOLDOWN=1800\n'
        printf 'ENABLED=%s\n' "$enabled"
    } > "$CONFIG_DIR/Wireguard0-test.conf"
    chmod 600 "$CONFIG_DIR/Wireguard0-test.conf"
}

run_worker() {
    scenario=$1 now=$2
    shift 2
    MOCK_SCENARIO="$scenario" MOCK_NOW="$now" MOCK_DIR="$MOCK_DIR" \
    KEENETIC_WG_CONFIG_DIR="$CONFIG_DIR" KEENETIC_WG_STATE_DIR="$STATE_DIR" \
    KEENETIC_WG_RUN_DIR="$RUN_DIR" KEENETIC_WG_NDMC="$MOCK_BIN/ndmc" \
    KEENETIC_WG_PING="$MOCK_BIN/ping" KEENETIC_WG_CURL="$MOCK_BIN/curl" \
    KEENETIC_WG_LOGGER="$MOCK_BIN/logger" KEENETIC_WG_SLEEP="$MOCK_BIN/sleep" \
    KEENETIC_WG_DATE="$MOCK_BIN/date" \
        $TEST_SHELL "$WORKER" "$@"
}

new_case
write_config
run_worker healthy 1000 --job Wireguard0-test --check >/dev/null
assert_contains "$STATE_DIR/Wireguard0-test.state" 'LAST_RESULT=healthy' 'исправный пир'
assert_empty "$MOCK_DIR/curl.log" 'исправный пир не должен обращаться к API'
pass 'исправный пир не перезапускается'

new_case
write_config
run_worker fail_then_recover 2000 --job Wireguard0-test --check >/dev/null
assert_contains "$STATE_DIR/Wireguard0-test.state" 'LAST_RESULT=failure:1:2' 'первая ошибка'
assert_empty "$MOCK_DIR/curl.log" 'первая ошибка не должна обращаться к API'
run_worker fail_then_recover 2060 --job Wireguard0-test --check >/dev/null
assert_contains "$STATE_DIR/Wireguard0-test.state" 'LAST_RESULT=recovered' 'восстановление'
assert_contains "$MOCK_DIR/curl.log" '/rci/interface/Wireguard0 | {"down":true}' 'команда down'
assert_contains "$MOCK_DIR/curl.log" '/rci/interface/Wireguard0 | {"up":true}' 'команда up'
pass 'порог ошибок и удалённый перезапуск работают'

new_case
write_config
sed -i 's/^FAILURE_THRESHOLD=2$/FAILURE_THRESHOLD=1/' "$CONFIG_DIR/Wireguard0-test.conf"
run_worker down 3000 --job Wireguard0-test --force >/dev/null || true
: > "$MOCK_DIR/curl.log"
run_worker down 3060 --job Wireguard0-test --check >/dev/null || true
assert_contains "$STATE_DIR/Wireguard0-test.state" 'LAST_RESULT=cooldown:' 'cooldown'
assert_empty "$MOCK_DIR/curl.log" 'cooldown должен блокировать API'
pass 'cooldown блокирует повторный перезапуск'

new_case
write_config no
run_worker healthy 4000 --job Wireguard0-test --check >/dev/null
assert_empty "$MOCK_DIR/ping.log" 'выключенное задание не должно выполнять ping'
assert_empty "$MOCK_DIR/curl.log" 'выключенное задание не должно обращаться к API'
pass 'выключенное задание пропускается'

new_case
write_config
MOCK_RUNNING_CONFIG='interface Wireguard0
 description Empty' run_worker down 5000 --job Wireguard0-test --check >/dev/null 2>&1 || true
assert_contains "$STATE_DIR/Wireguard0-test.state" 'LAST_RESULT=peer_missing' 'удалённый пир в локальной конфигурации отсутствует'
assert_empty "$MOCK_DIR/curl.log" 'удалённый локально пир не должен запускать API'
pass 'удалённое локальное задание безопасно останавливается'

new_case
write_config
run_worker healthy 6000 --test-api Wireguard0-test > "$CASE_DIR/api-output"
assert_contains "$CASE_DIR/api-output" 'интерфейс Wireguard0 найден' 'проверка API'
pass 'проверка API и интерфейса работает'

printf '1..%s\n' "$PASS_COUNT"
