#!/bin/sh

# Interactive manager for Keenetic WG Watchdog.

VERSION="0.2.2"
OPT_ROOT="${KEENETIC_WG_OPT_ROOT:-/opt}"
CONFIG_DIR="${KEENETIC_WG_CONFIG_DIR:-$OPT_ROOT/etc/keenetic-wg-watchdog.d}"
STATE_DIR="${KEENETIC_WG_STATE_DIR:-/tmp/keenetic-wg-watchdog}"
WORKER="${KEENETIC_WG_WORKER:-$OPT_ROOT/bin/keenetic-wg-watchdog}"
NDMC_BIN="${KEENETIC_WG_NDMC:-ndmc}"
BASE64_BIN="${KEENETIC_WG_BASE64:-base64}"
SHA256_BIN="${KEENETIC_WG_SHA256:-sha256sum}"
TTY="${KEENETIC_WG_TTY:-/dev/tty}"
PATH="${KEENETIC_WG_PATH:-/opt/bin:/opt/sbin:/usr/sbin:/usr/bin:/sbin:/bin}"
export PATH

UI_ACTIVE=no
TMP_FILES=""
umask 077

cleanup() {
    printf '%s' "$TMP_FILES" | while IFS= read -r file; do
        [ -n "$file" ] && rm -f "$file"
    done
    [ "$UI_ACTIVE" = yes ] && printf '\033[0m\033[?7h\033[?25h\033[?1049l' >&4
}
trap cleanup EXIT HUP INT TERM

open_console() {
    exec 3< "$TTY" || { printf 'Ошибка: нет терминала.\n' >&2; exit 1; }
    exec 4> "$TTY" || exit 1
    if [ -t 3 ] && [ -t 4 ] && [ "${TERM:-dumb}" != dumb ]; then
        UI_ACTIVE=yes
        printf '\033[?1049h\033[?7l\033[2J\033[H' >&4
    fi
}

clear_screen() {
    [ "$UI_ACTIVE" = yes ] && printf '\033[2J\033[H' >&4
}

say() { printf '%s\n' "$*" >&4; }

header() {
    clear_screen
    say '__        __    ____    __  __'
    say '\ \      / /   / ___|  |  \/  |'
    say ' \ \ /\ / /   | |  _   | |\/| |'
    say '  \ V  V /    | |_| |  | |  | |'
    say '   \_/\_/      \____|  |_|  |_|'
    say ''
    say 'Keenetic WG Watchdog'
    [ -z "${1:-}" ] || say "$1"
    say ''
}

pause() {
    printf '\nНажмите Enter, чтобы продолжить: ' >&4
    IFS= read -r _answer <&3 || exit 0
}

read_answer() {
    label=$1 default=${2:-}
    if [ -n "$default" ]; then
        printf '%s [%s]: ' "$label" "$default" >&4
    else
        printf '%s: ' "$label" >&4
    fi
    IFS= read -r REPLY <&3 || exit 0
    [ -n "$REPLY" ] || REPLY=$default
}

read_password() {
    printf '%s: ' "$1" >&4
    stty -echo <&3 2>/dev/null || true
    IFS= read -r REPLY <&3 || REPLY=""
    stty echo <&3 2>/dev/null || true
    printf '\n' >&4
}

confirm() {
    read_answer "$1 [д/Н]" ""
    case "$REPLY" in д|Д|да|Да|ДА|y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

is_uint() {
    case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac
}

valid_interface() {
    case "$1" in Wireguard[0-9]*) suffix=${1#Wireguard}; case "$suffix" in ''|*[!0-9]*) return 1 ;; esac ;; *) return 1 ;; esac
}

valid_target() {
    case "$1" in ''|-*|*[!0-9A-Fa-f.:]*) return 1 ;; *[0-9A-Fa-f]*) return 0 ;; *) return 1 ;; esac
}

valid_url() {
    case "$1" in http://*|https://*) ;; *) return 1 ;; esac
    case "$1" in *[!0-9A-Za-z._:/-]*) return 1 ;; esac
    return 0
}

encode() {
    printf '%s' "$1" | "$BASE64_BIN" | tr -d '\n'
}

job_id_for() {
    digest=$(printf '%s' "$2" | "$SHA256_BIN" | awk '{print substr($1,1,12)}')
    REPLY="$1-$digest"
}

detect_interfaces() {
    RUNNING_CONFIG=$("$NDMC_BIN" -c 'show running-config' 2>/dev/null || true)
    INTERFACE_LIST=$(printf '%s\n' "$RUNNING_CONFIG" | awk '
        function remember(value) {
            current=value
            if (!seen[value]++) order[++count]=value
        }
        function read_description(first, value, i) {
            value=$(first+1)
            for (i=first+2; i<=NF; i++) value=value " " $i
            gsub(/^"|"$/, "", value)
            description[current]=value
        }
        $1=="interface" {
            current=""
            if ($2 ~ /^Wireguard[0-9]+$/) {
                remember($2)
                for (i=3; i<=NF; i++) {
                    if ($i=="description") { read_description(i); break }
                }
            }
            next
        }
        current!="" && $1=="description" { read_description(1); next }
        current!="" && $0=="!" { current=""; next }
        END {
            for (i=1; i<=count; i++) {
                name=order[i]
                if (description[name]=="") description[name]="без описания"
                print name "\t" description[name]
            }
        }
    ')
}

detect_peers() {
    selected=$1
    PEER_LIST=$(printf '%s\n' "$RUNNING_CONFIG" | awk -v wanted="$selected" '
        function unquote(value) {
            gsub(/^"|"$/, "", value)
            return value
        }
        function endpoint_host(value, closing, count, parts) {
            if (substr(value,1,1) == "[") { closing=index(value,"]"); if(closing>2) return substr(value,2,closing-2) }
            count=split(value,parts,":"); if(count==2) return parts[1]; return value
        }
        function remember_peer(value) {
            value=unquote(value)
            if (value == "") return
            current=value
            if (!seen[value]++) order[++peer_count]=value
        }
        function remember_target(value, mask, candidate) {
            if (current == "" || target[current] != "") return
            candidate=value
            if(candidate ~ /\/32$/) { sub(/\/32$/, "", candidate); if(candidate!="0.0.0.0") target[current]=candidate }
            else if(candidate ~ /\/128$/) { sub(/\/128$/, "", candidate); if(candidate!="::") target[current]=candidate }
            else if(mask=="255.255.255.255" && candidate!="0.0.0.0") target[current]=candidate
        }
        function parse_fields(first, i, value) {
            for (i=first; i<=NF; i++) {
                if ($i=="wireguard" && $(i+1)=="peer") {
                    remember_peer($(i+2)); i+=2; continue
                }
                if (i==first && $i=="peer") {
                    if ($(i+1)!="") { remember_peer($(i+1)); i++ }
                    else awaiting_key=1
                    continue
                }
                if (awaiting_key && i==first && $i=="key") {
                    remember_peer($(i+1)); awaiting_key=0; i++; continue
                }
                if (current!="" && $i=="endpoint") {
                    endpoint[current]=endpoint_host($(i+1)); i++; continue
                }
                if (current!="" && $i=="allow-ips") {
                    remember_target($(i+1), $(i+2)); i+=2; continue
                }
                if (current!="" && ($i=="comment" || $i=="description")) {
                    value=$(i+1)
                    for (i=i+2; i<=NF; i++) value=value " " $i
                    label[current]=unquote(value)
                }
            }
        }
        $1=="interface" {
            inside=($2==wanted); current=""; awaiting_key=0
            if (inside) parse_fields(3)
            next
        }
        inside && $0=="!" { inside=0; current=""; awaiting_key=0; next }
        inside { parse_fields(1) }
        END {
            for (i=1; i<=peer_count; i++) {
                key=order[i]
                if (endpoint[key]=="") endpoint[key]="-"
                if (target[key]=="") target[key]="-"
                if (label[key]=="") label[key]="-"
                print key "\t" endpoint[key] "\t" target[key] "\t" label[key]
            }
        }
    ')
}

choose_interface() {
    while :; do
        header 'Выберите WireGuard-сервер'
        count=$(printf '%s\n' "$INTERFACE_LIST" | awk 'NF{n++} END{print n+0}')
        [ "$count" -gt 0 ] || { say 'WireGuard-интерфейсы не найдены.'; pause; exit 1; }
        index=1
        while IFS="$(printf '\t')" read -r iface description; do
            [ -n "$iface" ] || continue
            say "  $index. $iface — $description"
            index=$((index + 1))
        done <<EOF
$INTERFACE_LIST
EOF
        say '  0. Выход'
        read_answer 'Выберите пункт' ''
        [ "$REPLY" = 0 ] && return 1
        if is_uint "$REPLY" && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "$count" ]; then
            SELECTED_INTERFACE=$(printf '%s\n' "$INTERFACE_LIST" | sed -n "${REPLY}p" | cut -f1)
            return 0
        fi
    done
}

choose_peer() {
    while :; do
        detect_peers "$SELECTED_INTERFACE"
        header "$SELECTED_INTERFACE · выберите пира"
        count=$(printf '%s\n' "$PEER_LIST" | awk 'NF{n++} END{print n+0}')
        [ "$count" -gt 0 ] || { say 'На интерфейсе нет пиров.'; pause; return 1; }
        index=1
        while IFS="$(printf '\t')" read -r key endpoint target peer_label; do
            short=$(printf '%.8s' "$key")
            [ "$endpoint" = - ] && endpoint='endpoint не найден'
            [ "$target" = - ] && target='адрес не найден'
            [ "$peer_label" = - ] && peer_label="peer $short…"
            job_id_for "$SELECTED_INTERFACE" "$key"
            marker=''
            [ -f "$CONFIG_DIR/$REPLY.conf" ] && marker=' · настроен'
            say "  $index. $peer_label — $endpoint; $target$marker"
            index=$((index + 1))
        done <<EOF
$PEER_LIST
EOF
        say '  0. Назад'
        read_answer 'Выберите пункт' ''
        [ "$REPLY" = 0 ] && return 1
        if is_uint "$REPLY" && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le "$count" ]; then
            row=$(printf '%s\n' "$PEER_LIST" | sed -n "${REPLY}p")
            PEER_KEY=$(printf '%s\n' "$row" | cut -f1)
            PEER_TARGET=$(printf '%s\n' "$row" | cut -f3)
            [ "$PEER_TARGET" = - ] && PEER_TARGET=''
            job_id_for "$SELECTED_INTERFACE" "$PEER_KEY"
            JOB_ID=$REPLY
            return 0
        fi
    done
}

config_value() {
    sed -n "s/^$2=//p" "$1" | sed -n '1p'
}

decode_config_value() {
    encoded=$(config_value "$1" "$2")
    printf '%s' "$encoded" | "$BASE64_BIN" -d 2>/dev/null
}

state_result_text() {
    result=$(config_value "$STATE_DIR/$JOB_ID.state" LAST_RESULT)
    case "$result" in
        healthy) printf 'туннель работает' ;;
        recovered) printf 'туннель восстановлен' ;;
        restarting) printf 'выполняется перезапуск' ;;
        restarted_unreachable) printf 'перезапущен, но пир недоступен' ;;
        api_error) printf 'ошибка HTTP API Keenetic' ;;
        peer_missing) printf 'пир удалён из конфигурации' ;;
        failure:*) failure_info=${result#failure:}; printf 'ошибка %s из %s' "${failure_info%%:*}" "${failure_info#*:}" ;;
        cooldown:*) printf 'действует cooldown' ;;
        ''|never) printf 'ещё не проверялось' ;;
        *) printf '%s' "$result" ;;
    esac
}

write_config() {
    path="$CONFIG_DIR/$JOB_ID.conf"
    mkdir -p "$CONFIG_DIR" || return 1
    tmp=$(mktemp "$path.XXXXXX") || return 1
    {
        printf 'JOB_ID=%s\n' "$JOB_ID"
        printf 'LOCAL_INTERFACE=%s\n' "$SELECTED_INTERFACE"
        printf 'PEER_PUBLIC_KEY_B64=%s\n' "$(encode "$PEER_KEY")"
        printf 'TARGET_IP=%s\n' "$TARGET_IP"
        printf 'ROUTER_URL_B64=%s\n' "$(encode "$ROUTER_URL")"
        printf 'ROUTER_USER_B64=%s\n' "$(encode "$ROUTER_USER")"
        printf 'ROUTER_PASSWORD_B64=%s\n' "$(encode "$ROUTER_PASSWORD")"
        printf 'REMOTE_INTERFACE=%s\n' "$REMOTE_INTERFACE"
        printf 'PING_COUNT=3\nPING_TIMEOUT=3\nFAILURE_THRESHOLD=2\n'
        printf 'RESTART_DELAY=3\nRECOVERY_CHECK_DELAY=15\nRESTART_COOLDOWN=1800\n'
        printf 'ENABLED=yes\n'
    } > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$path"
}

configure_job() {
    existing="$CONFIG_DIR/$JOB_ID.conf"
    current_target=$PEER_TARGET current_url='' current_user=admin current_remote=Wireguard0 current_password=''
    if [ -f "$existing" ]; then
        current_target=$(config_value "$existing" TARGET_IP)
        current_url=$(decode_config_value "$existing" ROUTER_URL_B64)
        current_user=$(decode_config_value "$existing" ROUTER_USER_B64)
        current_password=$(decode_config_value "$existing" ROUTER_PASSWORD_B64)
        current_remote=$(config_value "$existing" REMOTE_INTERFACE)
    fi
    header "$SELECTED_INTERFACE · peer $(printf '%.8s' "$PEER_KEY")…"
    say 'Настройка удалённого Keenetic/Netcraze без Entware'
    say ''
    while :; do
        read_answer 'Адрес пира для контроля' "$current_target"
        valid_target "$REPLY" && { TARGET_IP=$REPLY; break; }
        say 'Введите одиночный IPv4 или IPv6-адрес.'
    done
    while :; do
        read_answer 'Облачный RCI URL (домен 4-го уровня)' "$current_url"
        valid_url "$REPLY" && { ROUTER_URL=${REPLY%/}; break; }
        say 'Пример: http://rci.branch.keenetic.pro'
    done
    router_host=$(printf '%s' "$ROUTER_URL" | sed 's#^[a-z]*://##; s#[:/].*$##')
    if [ "$router_host" = "$TARGET_IP" ]; then
        say ''
        say 'ОШИБКА: API указан через контролируемый туннель.'
        say 'После down команда up не сможет дойти до Keenetic.'
        pause
        return 1
    fi
    while :; do
        read_answer 'Пользователь Keenetic' "$current_user"
        case "$REPLY" in ''|*[!0-9A-Za-z_.@-]*) say 'Недопустимое имя пользователя.' ;; *) ROUTER_USER=$REPLY; break ;; esac
    done
    if [ -n "$current_password" ]; then
        read_password 'Пароль Keenetic (Enter — оставить прежний)'
        ROUTER_PASSWORD=${REPLY:-$current_password}
    else
        while :; do
            read_password 'Пароль Keenetic'
            [ -n "$REPLY" ] && { ROUTER_PASSWORD=$REPLY; break; }
            say 'Пароль не может быть пустым.'
        done
    fi
    while :; do
        read_answer 'Системное имя туннеля на удалённом Keenetic' "$current_remote"
        valid_interface "$REPLY" && { REMOTE_INTERFACE=$REPLY; break; }
        say 'Имя должно иметь вид Wireguard0.'
    done
    write_config || { say 'ОШИБКА: не удалось сохранить настройки.'; pause; return 1; }
    say ''
    say 'Проверяю облачную Digest-авторизацию и интерфейс…'
    if "$WORKER" --test-api "$JOB_ID" >&4 2>&4; then
        say ''
        say 'ГОТОВО: контроль пира включён.'
    else
        say ''
        say 'ВНИМАНИЕ: настройки сохранены, но проверка API не прошла.'
        if confirm 'Выключить задание до исправления доступа?'; then
            sed -i 's/^ENABLED=yes$/ENABLED=no/' "$existing"
        fi
    fi
    pause
}

toggle_job() {
    path="$CONFIG_DIR/$JOB_ID.conf"
    enabled=$(config_value "$path" ENABLED)
    if [ "$enabled" = yes ]; then
        sed -i 's/^ENABLED=yes$/ENABLED=no/' "$path"
    else
        sed -i 's/^ENABLED=no$/ENABLED=yes/' "$path"
    fi
}

peer_menu() {
    while :; do
        path="$CONFIG_DIR/$JOB_ID.conf"
        if [ ! -f "$path" ]; then
            configure_job
            [ -f "$path" ] || return 0
        fi
        enabled=$(config_value "$path" ENABLED)
        state_text=$(state_result_text)
        header "$SELECTED_INTERFACE · peer $(printf '%.8s' "$PEER_KEY")…"
        say "Адрес контроля: $(config_value "$path" TARGET_IP)"
        say "Удалённый интерфейс: $(config_value "$path" REMOTE_INTERFACE)"
        say "Контроль: $([ "$enabled" = yes ] && printf 'включён' || printf 'выключен')"
        say "Последний результат: $state_text"
        say ''
        say '  1. Проверить сейчас'
        say '  2. Принудительно перезапустить удалённый туннель'
        say '  3. Изменить настройки'
        say "  4. $([ "$enabled" = yes ] && printf 'Выключить' || printf 'Включить') контроль"
        say '  5. Удалить задание'
        say '  0. Назад'
        read_answer 'Выберите пункт' ''
        case "$REPLY" in
            1) header 'Проверка соединения'; "$WORKER" --job "$JOB_ID" --check >&4 2>&4 || true; pause ;;
            2)
                header 'Принудительный перезапуск'
                if confirm "Перезапустить $(config_value "$path" REMOTE_INTERFACE) на удалённом Keenetic?"; then
                    "$WORKER" --job "$JOB_ID" --force >&4 2>&4 || true
                else
                    say 'ОТМЕНЕНО.'
                fi
                pause
                ;;
            3) configure_job ;;
            4) toggle_job ;;
            5)
                if confirm 'Удалить это задание?'; then
                    rm -f "$path" "$STATE_DIR/$JOB_ID.state"
                    return 0
                fi
                ;;
            0) return 0 ;;
        esac
    done
}

preflight() {
    for command in "$NDMC_BIN" "$BASE64_BIN" "$SHA256_BIN"; do
        command -v "$command" >/dev/null 2>&1 || { say "ОШИБКА: не найдена команда $command."; return 1; }
    done
    [ -x "$WORKER" ] || { say "ОШИБКА: не найден $WORKER."; return 1; }
}

main() {
    open_console
    preflight || { pause; return 1; }
    while :; do
        detect_interfaces
        choose_interface || return 0
        while choose_peer; do peer_menu; done
    done
}

list_peers() {
    [ "$#" -eq 1 ] && valid_interface "$1" || {
        printf 'Использование: %s --list-peers WireguardN\n' "$0" >&2
        return 2
    }
    detect_interfaces
    detect_peers "$1"
    printf '%s\n' "$PEER_LIST" | awk 'NF'
}

case "${1:-}" in
    --version) printf '%s\n' "$VERSION" ;;
    --list-peers) shift; list_peers "$@" ;;
    ''|--plain) main ;;
    *) printf 'Использование: %s [--plain|--version|--list-peers WireguardN]\n' "$0" >&2; exit 2 ;;
esac
