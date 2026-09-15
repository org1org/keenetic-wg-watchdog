#!/bin/sh

set -eu

VERSION="0.2.1"
BASE_URL="${KEENETIC_WG_BASE_URL:-https://raw.githubusercontent.com/org1org/keenetic-wg-watchdog/main}"
OPT_ROOT="${KEENETIC_WG_OPT_ROOT:-/opt}"
BIN_DIR="$OPT_ROOT/bin"
CONFIG_DIR="$OPT_ROOT/etc/keenetic-wg-watchdog.d"
CRONTAB="$OPT_ROOT/etc/crontab"
CRON_INIT="$OPT_ROOT/etc/init.d/S10cron"
OPKG_BIN="${KEENETIC_WG_OPKG:-opkg}"
PIDOF_BIN="${KEENETIC_WG_PIDOF:-pidof}"
BEGIN_MARKER='# BEGIN KEENETIC-WG-WATCHDOG — managed automatically'
END_MARKER='# END KEENETIC-WG-WATCHDOG'

say() { printf '%s\n' "$*"; }
die() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die 'запустите установщик с правами root'
command -v "$OPKG_BIN" >/dev/null 2>&1 || die 'Entware не найден или не запущен'

remove_cron_block() {
    [ -f "$CRONTAB" ] || return 0
    tmp=$(mktemp "$CRONTAB.XXXXXX") || return 1
    awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
        $0 == begin { skip=1; next }
        $0 == end { skip=0; next }
        !skip { print }
    ' "$CRONTAB" > "$tmp"
    cat "$tmp" > "$CRONTAB"
    rm -f "$tmp"
}

if [ "${1:-}" = --uninstall ]; then
    remove_cron_block
    rm -f "$BIN_DIR/keenetic-wg-watchdog" "$BIN_DIR/keenetic-wg-watchdog-manager" "$BIN_DIR/kwg"
    "$CRON_INIT" restart >/dev/null 2>&1 || true
    say "Программа удалена. Настройки сохранены в $CONFIG_DIR."
    exit 0
fi

missing=''
command -v ndmc >/dev/null 2>&1 || missing="$missing ndmq"
command -v curl >/dev/null 2>&1 || missing="$missing curl"
[ -x "$CRON_INIT" ] || missing="$missing cron"
if [ -n "$missing" ]; then
    say "Устанавливаю зависимости:$missing"
    "$OPKG_BIN" update >/dev/null
    # shellcheck disable=SC2086
    "$OPKG_BIN" install $missing >/dev/null
fi

for command in ndmc curl base64 md5sum sha256sum; do
    command -v "$command" >/dev/null 2>&1 || die "после установки не найдена команда $command"
done
[ -x "$CRON_INIT" ] || die 'служба cron не найдена'

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/keenetic-wg-install.XXXXXX") || die 'не удалось создать временный каталог'
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

download() {
    curl -fsSL --connect-timeout 5 --max-time 30 "$1" -o "$2"
}

if script_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd); then
    :
else
    script_dir=''
fi
if [ -n "$script_dir" ] && [ -f "$script_dir/keenetic-wg-watchdog.sh" ]; then
    cp "$script_dir/keenetic-wg-watchdog.sh" "$tmp_dir/worker"
    cp "$script_dir/keenetic-wg-watchdog-manager.sh" "$tmp_dir/manager"
else
    download "$BASE_URL/keenetic-wg-watchdog.sh" "$tmp_dir/worker"
    download "$BASE_URL/keenetic-wg-watchdog-manager.sh" "$tmp_dir/manager"
fi

sh -n "$tmp_dir/worker" || die 'ошибка синтаксиса worker'
sh -n "$tmp_dir/manager" || die 'ошибка синтаксиса manager'
worker_version=$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$tmp_dir/worker" | sed -n '1p')
manager_version=$(sed -n 's/^VERSION="\([^"]*\)"/\1/p' "$tmp_dir/manager" | sed -n '1p')
if [ "$worker_version" != "$VERSION" ] || [ "$manager_version" != "$VERSION" ]; then
    die 'версии файлов не совпадают'
fi

mkdir -p "$BIN_DIR" "$CONFIG_DIR" || die 'не удалось создать каталоги программы'
chmod 700 "$CONFIG_DIR" || die 'не удалось настроить права каталога конфигурации'
cp "$tmp_dir/worker" "$BIN_DIR/keenetic-wg-watchdog" || die 'не удалось установить worker'
cp "$tmp_dir/manager" "$BIN_DIR/keenetic-wg-watchdog-manager" || die 'не удалось установить manager'
chmod 755 "$BIN_DIR/keenetic-wg-watchdog" "$BIN_DIR/keenetic-wg-watchdog-manager" || \
    die 'не удалось настроить права исполняемых файлов'
ln -sf "$BIN_DIR/keenetic-wg-watchdog-manager" "$BIN_DIR/kwg"

mkdir -p "$(dirname "$CRONTAB")"
touch "$CRONTAB"
remove_cron_block
{
    printf '%s\n' "$BEGIN_MARKER"
    printf '* * * * * root %s --run\n' "$BIN_DIR/keenetic-wg-watchdog"
    printf '%s\n' "$END_MARKER"
} >> "$CRONTAB"

"$CRON_INIT" enable >/dev/null 2>&1 || true
if ! "$PIDOF_BIN" cron >/dev/null 2>&1; then
    "$CRON_INIT" start >/dev/null 2>&1 || die 'не удалось запустить cron'
else
    "$CRON_INIT" restart >/dev/null 2>&1 || die 'не удалось перезапустить cron'
fi

say ''
say 'Готово. Запустите менеджер: kwg'
