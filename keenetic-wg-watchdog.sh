#!/bin/sh

# Server-side peer watchdog for KeeneticOS + Entware.

VERSION="0.1.0"
CONFIG_DIR="${KEENETIC_WG_CONFIG_DIR:-/opt/etc/keenetic-wg-watchdog.d}"
STATE_DIR="${KEENETIC_WG_STATE_DIR:-/tmp/keenetic-wg-watchdog}"
RUN_DIR="${KEENETIC_WG_RUN_DIR:-/tmp/keenetic-wg-watchdog}"
NDMC_BIN="${KEENETIC_WG_NDMC:-ndmc}"
PING_BIN="${KEENETIC_WG_PING:-ping}"
CURL_BIN="${KEENETIC_WG_CURL:-curl}"
LOGGER_BIN="${KEENETIC_WG_LOGGER:-logger}"
SLEEP_BIN="${KEENETIC_WG_SLEEP:-sleep}"
DATE_BIN="${KEENETIC_WG_DATE:-date}"
BASE64_BIN="${KEENETIC_WG_BASE64:-base64}"
MD5_BIN="${KEENETIC_WG_MD5:-md5sum}"
SHA256_BIN="${KEENETIC_WG_SHA256:-sha256sum}"
PATH="${KEENETIC_WG_PATH:-/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin}"
export PATH

FORCE=no
VERBOSE=no
LOCK_HELD=no
TMP_ROOT=""
umask 077

say() {
    [ "$VERBOSE" = yes ] && printf '%s\n' "$*"
    return 0
}

log_message() {
    "$LOGGER_BIN" -t keenetic-wg-watchdog "$*" 2>/dev/null || true
    say "$*"
}

cleanup() {
    cleanup_api
    release_lock
}
trap cleanup EXIT HUP INT TERM

release_lock() {
    [ "$LOCK_HELD" = yes ] || return 0
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || true
    LOCK_HELD=no
}

cleanup_api() {
    [ -z "$TMP_ROOT" ] || rm -rf "$TMP_ROOT"
    TMP_ROOT=""
}

is_uint() {
    case "$1" in ''|*[!0-9]*|0[0-9]*) return 1 ;; esac
    [ "${#1}" -le 10 ]
}

valid_job_id() {
    case "$1" in ''|*[!0-9A-Za-z_.-]*) return 1 ;; *) return 0 ;; esac
}

valid_local_interface() {
    case "$1" in Wireguard[0-9]*) suffix=${1#Wireguard}; case "$suffix" in *[!0-9]*|'') return 1 ;; esac ;; *) return 1 ;; esac
}

valid_remote_interface() {
    valid_local_interface "$1"
}

valid_target() {
    case "$1" in ''|-*|*[!0-9A-Fa-f.:]*) return 1 ;; *[0-9A-Fa-f]*) return 0 ;; *) return 1 ;; esac
}

b64decode() {
    printf '%s' "$1" | "$BASE64_BIN" -d 2>/dev/null
}

reset_config() {
    JOB_ID="" LOCAL_INTERFACE="" PEER_PUBLIC_KEY_B64="" TARGET_IP=""
    ROUTER_URL_B64="" ROUTER_USER_B64="" ROUTER_PASSWORD_B64=""
    REMOTE_INTERFACE="" PING_COUNT="" PING_TIMEOUT="" FAILURE_THRESHOLD=""
    RESTART_DELAY="" RECOVERY_CHECK_DELAY="" RESTART_COOLDOWN="" ENABLED=""
}

load_config() {
    reset_config
    [ -f "$1" ] && [ ! -L "$1" ] && [ -r "$1" ] || return 1
    seen="|"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        key=${line%%=*}
        value=${line#*=}
        [ "$key" != "$line" ] || return 1
        case "$seen" in *"|$key|"*) return 1 ;; esac
        seen="${seen}${key}|"
        case "$value" in *[!0-9A-Za-z._:/+=-]*) return 1 ;; esac
        case "$key" in
            JOB_ID) JOB_ID=$value ;;
            LOCAL_INTERFACE) LOCAL_INTERFACE=$value ;;
            PEER_PUBLIC_KEY_B64) PEER_PUBLIC_KEY_B64=$value ;;
            TARGET_IP) TARGET_IP=$value ;;
            ROUTER_URL_B64) ROUTER_URL_B64=$value ;;
            ROUTER_USER_B64) ROUTER_USER_B64=$value ;;
            ROUTER_PASSWORD_B64) ROUTER_PASSWORD_B64=$value ;;
            REMOTE_INTERFACE) REMOTE_INTERFACE=$value ;;
            PING_COUNT) PING_COUNT=$value ;;
            PING_TIMEOUT) PING_TIMEOUT=$value ;;
            FAILURE_THRESHOLD) FAILURE_THRESHOLD=$value ;;
            RESTART_DELAY) RESTART_DELAY=$value ;;
            RECOVERY_CHECK_DELAY) RECOVERY_CHECK_DELAY=$value ;;
            RESTART_COOLDOWN) RESTART_COOLDOWN=$value ;;
            ENABLED) ENABLED=$value ;;
            *) return 1 ;;
        esac
    done < "$1"

    [ "$JOB_ID" = "$REQUESTED_JOB" ] && valid_job_id "$JOB_ID" || return 1
    valid_local_interface "$LOCAL_INTERFACE" || return 1
    valid_remote_interface "$REMOTE_INTERFACE" || return 1
    valid_target "$TARGET_IP" || return 1
    case "$ENABLED" in yes|no) ;; *) return 1 ;; esac
    for number in "$PING_COUNT" "$PING_TIMEOUT" "$FAILURE_THRESHOLD" "$RESTART_DELAY" \
        "$RECOVERY_CHECK_DELAY" "$RESTART_COOLDOWN"; do
        is_uint "$number" || return 1
    done
    PEER_PUBLIC_KEY=$(b64decode "$PEER_PUBLIC_KEY_B64") || return 1
    ROUTER_URL=$(b64decode "$ROUTER_URL_B64") || return 1
    ROUTER_USER=$(b64decode "$ROUTER_USER_B64") || return 1
    ROUTER_PASSWORD=$(b64decode "$ROUTER_PASSWORD_B64") || return 1
    [ -n "$PEER_PUBLIC_KEY" ] && [ -n "$ROUTER_PASSWORD" ] || return 1
    case "$ROUTER_URL" in http://*|https://*) ;; *) return 1 ;; esac
    case "$ROUTER_URL" in *[!0-9A-Za-z._:/-]*) return 1 ;; esac
    case "$ROUTER_USER" in ''|*[!0-9A-Za-z_.@-]*) return 1 ;; esac
    ROUTER_URL=${ROUTER_URL%/}
}

reset_state() {
    FAILURES=0 LAST_CHECK=0 LAST_SUCCESS=0 LAST_RESTART=0 LAST_RESULT=never
}

load_state() {
    reset_state
    [ -f "$STATE_FILE" ] && [ ! -L "$STATE_FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        key=${line%%=*}; value=${line#*=}
        [ "$key" != "$line" ] || { reset_state; return 0; }
        case "$key" in
            FAILURES|LAST_CHECK|LAST_SUCCESS|LAST_RESTART) is_uint "$value" || { reset_state; return 0; }; eval "$key=\$value" ;;
            LAST_RESULT) case "$value" in *[!0-9A-Za-z_.:-]*) reset_state; return 0 ;; esac; LAST_RESULT=$value ;;
            *) reset_state; return 0 ;;
        esac
    done < "$STATE_FILE"
}

save_state() {
    mkdir -p "$STATE_DIR" || return 1
    tmp_state=$(mktemp "$STATE_FILE.XXXXXX") || return 1
    {
        printf 'FAILURES=%s\n' "$FAILURES"
        printf 'LAST_CHECK=%s\n' "$LAST_CHECK"
        printf 'LAST_SUCCESS=%s\n' "$LAST_SUCCESS"
        printf 'LAST_RESTART=%s\n' "$LAST_RESTART"
        printf 'LAST_RESULT=%s\n' "$LAST_RESULT"
    } > "$tmp_state"
    chmod 600 "$tmp_state"
    mv -f "$tmp_state" "$STATE_FILE"
}

now_epoch() {
    "$DATE_BIN" '+%s' 2>/dev/null || printf '0\n'
}

peer_still_configured() {
    "$NDMC_BIN" -c "show running-config" 2>/dev/null | awk \
        -v wanted_interface="$LOCAL_INTERFACE" -v wanted_key="$PEER_PUBLIC_KEY" '
        $1 == "interface" { inside = ($2 == wanted_interface); next }
        inside && $1 == "wireguard" && $2 == "peer" && $3 == wanted_key { found = 1 }
        END { exit(found ? 0 : 1) }
    '
}

ping_peer() {
    "$PING_BIN" -c "$PING_COUNT" -W "$PING_TIMEOUT" "$TARGET_IP" >/dev/null 2>&1
}

header_value() {
    awk -v wanted="$1" '
        BEGIN { IGNORECASE = 1 }
        {
            name = $1
            sub(/:$/, "", name)
            if (tolower(name) == tolower(wanted)) {
                sub(/^[^:]*:[[:space:]]*/, "")
                sub(/\r$/, "")
                print
                exit
            }
        }
    ' "$HEADERS_FILE"
}

check_api_body() {
    if grep -Eq '"status"[[:space:]]*:[[:space:]]*"error"' "$BODY_FILE"; then
        api_error=$(sed -n 's/.*"message"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$BODY_FILE" | sed -n '1p')
        API_ERROR=${api_error:-"Keenetic отклонил команду"}
        return 1
    fi
    return 0
}

api_authenticate() {
    cleanup_api
    TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/keenetic-wg-api.XXXXXX") || return 1
    COOKIE_FILE="$TMP_ROOT/cookies"
    HEADERS_FILE="$TMP_ROOT/headers"
    BODY_FILE="$TMP_ROOT/body"
    : > "$COOKIE_FILE"
    http_code=$("$CURL_BIN" -k -sS --connect-timeout 5 --max-time 15 \
        -c "$COOKIE_FILE" -b "$COOKIE_FILE" -D "$HEADERS_FILE" -o "$BODY_FILE" \
        -w '%{http_code}' "$ROUTER_URL/auth" 2>/dev/null) || {
        API_ERROR="адрес управления недоступен"
        return 1
    }
    if [ "$http_code" = 200 ]; then return 0; fi
    [ "$http_code" = 401 ] || { API_ERROR="GET /auth: HTTP $http_code"; return 1; }
    realm=$(header_value X-NDM-Realm)
    challenge=$(header_value X-NDM-Challenge)
    [ -n "$realm" ] && [ -n "$challenge" ] || {
        API_ERROR="нет X-NDM-Realm/X-NDM-Challenge; нужен прямой доступ к RCI"
        return 1
    }
    first=$(printf '%s' "$ROUTER_USER:$realm:$ROUTER_PASSWORD" | "$MD5_BIN" | awk '{print $1}') || return 1
    key=$(printf '%s' "$challenge$first" | "$SHA256_BIN" | awk '{print $1}') || return 1
    http_code=$("$CURL_BIN" -k -sS --connect-timeout 5 --max-time 15 \
        -c "$COOKIE_FILE" -b "$COOKIE_FILE" -D "$HEADERS_FILE" -o "$BODY_FILE" \
        -w '%{http_code}' -H 'Content-Type: application/json' \
        --data "{\"login\":\"$ROUTER_USER\",\"password\":\"$key\"}" \
        "$ROUTER_URL/auth" 2>/dev/null) || {
        API_ERROR="ошибка отправки авторизации"
        return 1
    }
    [ "$http_code" = 200 ] || { API_ERROR="неверный логин или пароль (HTTP $http_code)"; return 1; }
}

api_get_interface() {
    api_authenticate || return 1
    http_code=$("$CURL_BIN" -k -sS --connect-timeout 5 --max-time 15 \
        -c "$COOKIE_FILE" -b "$COOKIE_FILE" -o "$BODY_FILE" -w '%{http_code}' \
        "$ROUTER_URL/rci/show/interface/$REMOTE_INTERFACE" 2>/dev/null) || {
        API_ERROR="не удалось прочитать интерфейс"
        return 1
    }
    [ "$http_code" = 200 ] || { API_ERROR="проверка интерфейса: HTTP $http_code"; return 1; }
    check_api_body || return 1
    grep -Eq 'Wireguard|wireguard|"id"|"interface-name"' "$BODY_FILE" || {
        API_ERROR="интерфейс $REMOTE_INTERFACE не найден"
        return 1
    }
}

api_post_interface() {
    payload=$1
    http_code=$("$CURL_BIN" -k -sS --connect-timeout 5 --max-time 15 \
        -c "$COOKIE_FILE" -b "$COOKIE_FILE" -o "$BODY_FILE" -w '%{http_code}' \
        -H 'Content-Type: application/json' --data "$payload" \
        "$ROUTER_URL/rci/interface/$REMOTE_INTERFACE" 2>/dev/null) || {
        API_ERROR="не удалось отправить команду"
        return 1
    }
    [ "$http_code" = 200 ] || { API_ERROR="команда интерфейсу: HTTP $http_code"; return 1; }
    check_api_body
}

restart_remote_interface() {
    api_get_interface || return 1
    api_post_interface '{"down":true}' || return 1
    "$SLEEP_BIN" "$RESTART_DELAY"
    up_attempt=1
    while [ "$up_attempt" -le 3 ]; do
        if api_post_interface '{"up":true}'; then return 0; fi
        up_attempt=$((up_attempt + 1))
        [ "$up_attempt" -le 3 ] && "$SLEEP_BIN" 2
    done
    API_ERROR="не удалось вернуть $REMOTE_INTERFACE в up после трёх попыток: $API_ERROR"
    return 1
}

acquire_lock() {
    mkdir -p "$RUN_DIR" || return 1
    LOCK_DIR="$RUN_DIR/$JOB_ID.lock"
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        printf '%s\n' "$$" > "$LOCK_DIR/pid"
        LOCK_HELD=yes
        return 0
    fi
    old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    is_uint "$old_pid" && kill -0 "$old_pid" 2>/dev/null && return 1
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null || return 1
    mkdir "$LOCK_DIR" || return 1
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    LOCK_HELD=yes
}

process_job() {
    REQUESTED_JOB=$1
    CONFIG_FILE="$CONFIG_DIR/$REQUESTED_JOB.conf"
    load_config "$CONFIG_FILE" || { log_message "[$REQUESTED_JOB] повреждена конфигурация"; return 1; }
    if [ "$ENABLED" != yes ] && [ "$FORCE" != yes ]; then
        say "[$JOB_ID] контроль выключен"
        return 0
    fi
    acquire_lock || { say "[$JOB_ID] проверка уже выполняется"; return 0; }
    STATE_FILE="$STATE_DIR/$JOB_ID.state"
    load_state
    NOW=$(now_epoch)

    if [ "$FORCE" != yes ]; then
        peer_still_configured || {
            LAST_CHECK=$NOW LAST_RESULT=peer_missing
            save_state
            log_message "[$JOB_ID] пир больше не найден на $LOCAL_INTERFACE"
            return 1
        }
        if ping_peer; then
            changed=$LAST_RESULT
            FAILURES=0 LAST_CHECK=$NOW LAST_SUCCESS=$NOW LAST_RESULT=healthy
            save_state
            [ "$changed" = healthy ] || log_message "[$JOB_ID] туннель работает ($TARGET_IP)"
            return 0
        fi
        FAILURES=$((FAILURES + 1))
        LAST_CHECK=$NOW
        if [ "$FAILURES" -lt "$FAILURE_THRESHOLD" ]; then
            LAST_RESULT="failure:$FAILURES:$FAILURE_THRESHOLD"
            save_state
            log_message "[$JOB_ID] пир $TARGET_IP недоступен: ошибка $FAILURES из $FAILURE_THRESHOLD"
            return 0
        fi
        if [ "$LAST_RESTART" -gt 0 ] && [ $((NOW - LAST_RESTART)) -lt "$RESTART_COOLDOWN" ]; then
            remaining=$((RESTART_COOLDOWN - (NOW - LAST_RESTART)))
            LAST_RESULT="cooldown:$remaining"
            save_state
            say "[$JOB_ID] действует cooldown, осталось $remaining сек."
            return 0
        fi
    fi

    LAST_RESTART=$NOW LAST_RESULT=restarting
    save_state
    if ! restart_remote_interface; then
        LAST_RESULT=api_error
        save_state
        log_message "[$JOB_ID] перезапуск $REMOTE_INTERFACE не выполнен: $API_ERROR"
        return 1
    fi
    log_message "[$JOB_ID] $REMOTE_INTERFACE на удалённом Keenetic перезапущен"
    "$SLEEP_BIN" "$RECOVERY_CHECK_DELAY"
    if ping_peer; then
        FAILURES=0 LAST_SUCCESS=$(now_epoch) LAST_RESULT=recovered
        save_state
        log_message "[$JOB_ID] туннель восстановлен"
        return 0
    fi
    LAST_RESULT=restarted_unreachable
    save_state
    log_message "[$JOB_ID] интерфейс перезапущен, но пир $TARGET_IP недоступен"
    return 1
}

usage() {
    printf 'Использование: %s --run | --job ID [--check|--force] | --test-api ID\n' "$0"
}

case "${1:-}" in
    --run)
        result=0
        [ -d "$CONFIG_DIR" ] || exit 0
        for file in "$CONFIG_DIR"/*.conf; do
            [ -f "$file" ] || continue
            name=${file##*/}; name=${name%.conf}
            process_job "$name" || result=1
            release_lock
        done
        exit "$result"
        ;;
    --job)
        [ "$#" -ge 2 ] || { usage; exit 2; }
        requested=$2
        case "${3:-}" in
            --force) FORCE=yes; VERBOSE=yes ;;
            --check) VERBOSE=yes ;;
            '') ;;
            *) usage; exit 2 ;;
        esac
        valid_job_id "$requested" || { usage; exit 2; }
        process_job "$requested"
        ;;
    --test-api)
        [ "$#" -eq 2 ] || { usage; exit 2; }
        REQUESTED_JOB=$2
        valid_job_id "$REQUESTED_JOB" || exit 2
        load_config "$CONFIG_DIR/$REQUESTED_JOB.conf" || exit 1
        if api_get_interface; then
            printf 'OK: %s доступен, интерфейс %s найден.\n' "$ROUTER_URL" "$REMOTE_INTERFACE"
        else
            printf 'Ошибка: %s\n' "$API_ERROR" >&2
            exit 1
        fi
        ;;
    --version) printf '%s\n' "$VERSION" ;;
    *) usage; exit 2 ;;
esac
