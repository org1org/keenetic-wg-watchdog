#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
REPO_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)
WORKER="$REPO_DIR/keenetic-wg-watchdog.sh"
MANAGER="$REPO_DIR/keenetic-wg-watchdog-manager.sh"
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

assert_not_contains() {
    grep -F -- "$2" "$1" >/dev/null 2>&1 && fail "$3: найдено '$2'"
    return 0
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
        printf 'ROUTER_URL_B64=%s\n' "$(printf 'http://rci.branch.keenetic.pro' | base64 | tr -d '\n')"
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
MOCK_RUNNING_CONFIG='interface Wireguard0
    description WG-Server
    wireguard listen-port 36666
    wireguard peer first-real-format-key= !WG-Bekker
        allow-ips 172.16.88.7 255.255.255.255
        allow-ips 192.168.8.0 255.255.255.0
        connect
    !
    wireguard peer second-real-format-key= !WG-Svetlogore
        allow-ips 172.16.88.6 255.255.255.255
        connect
    !
    up
!'
MOCK_RUNNING_CONFIG="$MOCK_RUNNING_CONFIG" KEENETIC_WG_NDMC="$MOCK_BIN/ndmc" \
    $TEST_SHELL "$MANAGER" --list-peers Wireguard0 > "$CASE_DIR/peers"
assert_contains "$CASE_DIR/peers" 'first-real-format-key=' 'реальный формат: первый пир'
assert_contains "$CASE_DIR/peers" '172.16.88.7' 'реальный формат: адрес первого пира'
assert_contains "$CASE_DIR/peers" 'WG-Bekker' 'реальный формат: имя первого пира'
assert_contains "$CASE_DIR/peers" 'second-real-format-key=' 'реальный формат: второй пир'
assert_contains "$CASE_DIR/peers" 'WG-Svetlogore' 'реальный формат: имя второго пира'
pass 'manager распознаёт реальный формат running-config Keenetic'

new_case
MOCK_RUNNING_CONFIG='interface Wireguard0
 description "WG-Server"
 wireguard
  peer
   key peer-one-public-key
   comment "WG-Bekker"
   allow-ips 172.16.6.2 255.255.255.255
  !
  peer peer-two-public-key
   comment "WG-Work"
   allow-ips 172.16.6.3/32
  !
 !
!'
MOCK_RUNNING_CONFIG="$MOCK_RUNNING_CONFIG" KEENETIC_WG_NDMC="$MOCK_BIN/ndmc" \
    $TEST_SHELL "$MANAGER" --list-peers Wireguard0 > "$CASE_DIR/peers"
assert_contains "$CASE_DIR/peers" 'peer-one-public-key' 'вложенный формат: первый пир'
assert_contains "$CASE_DIR/peers" '172.16.6.2' 'вложенный формат: адрес первого пира'
assert_contains "$CASE_DIR/peers" 'WG-Bekker' 'вложенный формат: имя первого пира'
assert_contains "$CASE_DIR/peers" 'peer-two-public-key' 'вложенный формат: второй пир'
assert_contains "$CASE_DIR/peers" '172.16.6.3' 'вложенный формат: CIDR второго пира'
pass 'manager распознаёт вложенный формат пиров актуальной KeeneticOS'

new_case
MOCK_RUNNING_CONFIG='interface Wireguard0 wireguard peer flat-peer-public-key allow-ips 172.16.6.4/32
interface Wireguard0 wireguard peer flat-peer-public-key comment "WG-Flat"'
MOCK_RUNNING_CONFIG="$MOCK_RUNNING_CONFIG" KEENETIC_WG_NDMC="$MOCK_BIN/ndmc" \
    $TEST_SHELL "$MANAGER" --list-peers Wireguard0 > "$CASE_DIR/peers"
assert_contains "$CASE_DIR/peers" 'flat-peer-public-key' 'однострочный формат: пир'
assert_contains "$CASE_DIR/peers" '172.16.6.4' 'однострочный формат: адрес'
assert_contains "$CASE_DIR/peers" 'WG-Flat' 'однострочный формат: имя'
[ "$(wc -l < "$CASE_DIR/peers" | tr -d " ")" = 1 ] || fail 'однострочный пир продублирован'
pass 'manager объединяет однострочные команды одного пира'

new_case
write_config
MOCK_RUNNING_CONFIG='interface Wireguard0
 wireguard
  peer
   key test-peer-public-key
   allow-ips 172.16.6.2/32
  !
 !
!' run_worker healthy 5500 --job Wireguard0-test --check >/dev/null
assert_contains "$STATE_DIR/Wireguard0-test.state" 'LAST_RESULT=healthy' 'проверка вложенного пира worker'
pass 'worker подтверждает наличие пира во вложенном формате'

new_case
write_config
run_worker healthy 6000 --test-api Wireguard0-test > "$CASE_DIR/api-output"
assert_contains "$CASE_DIR/api-output" 'интерфейс Wireguard0 найден' 'проверка API'
assert_contains "$CASE_DIR/api-output" 'облачный Digest' 'вывод режима авторизации'
assert_contains "$MOCK_DIR/curl.log" 'auth=digest' 'облачная авторизация'
assert_not_contains "$MOCK_DIR/curl.log" '/auth' 'облачный API не должен использовать веб-сессию'
assert_not_contains "$MOCK_DIR/curl.log" 'secret! password' 'пароль не должен попадать в аргументы и журнал'
pass 'облачная Digest-авторизация является основным режимом'

new_case
write_config
run_worker direct_api 7000 --test-api Wireguard0-test > "$CASE_DIR/api-output"
assert_contains "$CASE_DIR/api-output" 'интерфейс Wireguard0 найден' 'прямой API fallback'
assert_contains "$CASE_DIR/api-output" 'прямой RCI' 'вывод fallback-режима'
assert_contains "$MOCK_DIR/curl.log" '/auth' 'fallback на прямую авторизацию'
pass 'прямая RCI-авторизация остаётся запасным режимом'

new_case
write_config
run_worker cloud_auth_error 8000 --test-api Wireguard0-test > "$CASE_DIR/api-output" 2>&1 && fail 'ошибка облачной авторизации должна завершать проверку'
assert_contains "$CASE_DIR/api-output" 'право HTTP Proxy' 'подсказка при ошибке облачной авторизации'
assert_not_contains "$MOCK_DIR/curl.log" '/auth' 'Digest challenge не должен переключаться на веб-сессию'
pass 'ошибка облачной авторизации диагностируется без ложного fallback'

new_case
INSTALL_ROOT="$CASE_DIR/opt"
mkdir -p "$INSTALL_ROOT/bin" "$INSTALL_ROOT/etc/init.d"
cat > "$MOCK_BIN/opkg" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$MOCK_BIN/ndmc" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$MOCK_BIN/pidof" <<'EOF'
#!/bin/sh
exit 1
EOF
cat > "$MOCK_BIN/install" <<'EOF'
#!/bin/sh
printf 'устаревшая команда install вызвана\n' >&2
exit 127
EOF
cat > "$MOCK_BIN/id" <<'EOF'
#!/bin/sh
[ "${1:-}" = -u ] && { printf '0\n'; exit 0; }
exit 1
EOF
cat > "$INSTALL_ROOT/etc/init.d/S10cron" <<EOF
#!/bin/sh
printf '%s\\n' "\$1" >> "$CASE_DIR/cron-init.log"
EOF
chmod 755 "$MOCK_BIN/opkg" "$MOCK_BIN/ndmc" "$MOCK_BIN/pidof" \
    "$MOCK_BIN/install" "$MOCK_BIN/id" "$INSTALL_ROOT/etc/init.d/S10cron"
PATH="$MOCK_BIN:$PATH" KEENETIC_WG_OPT_ROOT="$INSTALL_ROOT" \
    KEENETIC_WG_OPKG="$MOCK_BIN/opkg" KEENETIC_WG_PIDOF="$MOCK_BIN/pidof" \
    KEENETIC_WG_ID="$MOCK_BIN/id" \
    $TEST_SHELL "$REPO_DIR/install.sh" > "$CASE_DIR/install-output"
[ -x "$INSTALL_ROOT/bin/keenetic-wg-watchdog" ] || fail 'worker не установлен'
[ -x "$INSTALL_ROOT/bin/keenetic-wg-watchdog-manager" ] || fail 'manager не установлен'
[ -L "$INSTALL_ROOT/bin/kwg" ] || fail 'ссылка kwg не создана'
assert_contains "$INSTALL_ROOT/etc/crontab" 'keenetic-wg-watchdog --run' 'задание cron'
assert_contains "$CASE_DIR/install-output" 'Готово' 'результат установки'
pass 'установщик не зависит от отсутствующей в Entware команды install'

printf '1..%s\n' "$PASS_COUNT"
