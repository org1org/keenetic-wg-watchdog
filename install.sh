#!/bin/sh

set -eu

PROJECT_URL="https://raw.githubusercontent.com/org1org/keenetic-wg-watchdog/main"
BIN_DIR="${KWG_BIN_DIR:-/usr/local/bin}"
SYSTEMD_DIR="${KWG_SYSTEMD_DIR:-/etc/systemd/system}"
CONFIG_DIR="${KWG_CONFIG_DIR:-/etc/keenetic-wg-watchdog.d}"

if [ "$(id -u)" -ne 0 ]; then
    printf 'Ошибка: запустите установщик с правами root.\n' >&2
    exit 1
fi

if [ "${1:-}" = "--uninstall" ]; then
    systemctl disable --now keenetic-wg-watchdog.timer 2>/dev/null || true
    rm -f "$SYSTEMD_DIR/keenetic-wg-watchdog.service" \
        "$SYSTEMD_DIR/keenetic-wg-watchdog.timer" \
        "$BIN_DIR/keenetic-wg-watchdog" "$BIN_DIR/kwg"
    systemctl daemon-reload
    printf 'Программа удалена. Настройки сохранены в %s.\n' "$CONFIG_DIR"
    exit 0
fi

for command in python3 wg ping ip systemctl; do
    command -v "$command" >/dev/null 2>&1 || {
        printf 'Ошибка: требуется команда %s.\n' "$command" >&2
        exit 1
    }
done

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/keenetic-wg-watchdog.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

fetch() {
    source=$1
    destination=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$source" -o "$destination"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$destination" "$source"
    else
        printf 'Ошибка: требуется curl или wget.\n' >&2
        exit 1
    fi
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -f "$script_dir/keenetic_wg_watchdog.py" ]; then
    cp "$script_dir/keenetic_wg_watchdog.py" "$tmp_dir/app"
    cp "$script_dir/systemd/keenetic-wg-watchdog.service" "$tmp_dir/service"
    cp "$script_dir/systemd/keenetic-wg-watchdog.timer" "$tmp_dir/timer"
else
    fetch "$PROJECT_URL/keenetic_wg_watchdog.py" "$tmp_dir/app"
    fetch "$PROJECT_URL/systemd/keenetic-wg-watchdog.service" "$tmp_dir/service"
    fetch "$PROJECT_URL/systemd/keenetic-wg-watchdog.timer" "$tmp_dir/timer"
fi

python3 -m py_compile "$tmp_dir/app"
install -d -m 700 "$CONFIG_DIR"
install -m 755 "$tmp_dir/app" "$BIN_DIR/keenetic-wg-watchdog"
ln -sf "$BIN_DIR/keenetic-wg-watchdog" "$BIN_DIR/kwg"
install -m 644 "$tmp_dir/service" "$SYSTEMD_DIR/keenetic-wg-watchdog.service"
install -m 644 "$tmp_dir/timer" "$SYSTEMD_DIR/keenetic-wg-watchdog.timer"
systemctl daemon-reload
systemctl enable --now keenetic-wg-watchdog.timer

printf '\nГотово. Запустите менеджер: sudo kwg\n'
