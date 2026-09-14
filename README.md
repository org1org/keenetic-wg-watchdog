<div align="left">

<pre>
__        __    ____    __  __
\ \      / /   / ___|  |  \/  |
 \ \ /\ / /   | |  _   | |\/| |
  \ V  V /    | |_| |  | |  | |
   \_/\_/      \____|  |_|  |_|
</pre>

### Keenetic WG Watchdog

Удалённое восстановление WireGuard между роутерами Keenetic.

![version](https://img.shields.io/badge/version-0.1.0-blue)
![shell](https://img.shields.io/badge/shell-POSIX%20sh-4EAA25)
![platform](https://img.shields.io/badge/platform-KeeneticOS-009EE2)
![environment](https://img.shields.io/badge/environment-Entware-555555)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![CI](https://github.com/org1org/keenetic-wg-watchdog/actions/workflows/ci.yml/badge.svg)](https://github.com/org1org/keenetic-wg-watchdog/actions/workflows/ci.yml)

</div>

## Схема работы

Программа ставится на центральный Keenetic с Entware, который принимает
WireGuard-подключения. Удалённому Keenetic Entware не нужен.

Центральный роутер проверяет адрес выбранного пира внутри туннеля. После двух
последовательных ошибок он подключается к HTTP RCI API удалённого Keenetic по
независимому адресу и перезапускает там только указанный `WireguardN`.

## Важно

Адрес управления удалённым Keenetic не должен проходить через контролируемый
туннель. После команды `down` этот путь исчезнет и команда `up` не дойдёт.

Подойдёт прямой HTTPS-доступ через внешний адрес и отдельный порт, отдельная
управляющая VPN или служебная сеть. Доступ следует ограничить IP-адресом
центрального роутера. KeenDNS может не передавать необходимые заголовки
`X-NDM-Realm` и `X-NDM-Challenge`; версия 0.1.0 рассчитана на прямой RCI-доступ.

## Возможности

- интерфейс в стиле WG Watchdog Manager;
- последовательный выбор локального WG-сервера и его пира;
- определение адреса контроля из `allow-ips /32` или `/128`;
- проверка авторизации и наличия удалённого интерфейса при настройке;
- две ошибки до перезапуска, контроль восстановления и cooldown 30 минут;
- три попытки вернуть удалённый интерфейс в `up`;
- отдельные задания для разных интерфейсов и пиров;
- пароли хранятся в конфигурациях с правами `600`;
- работа через cron без Python, systemd и программ на удалённом Keenetic.

## Требования

- центральный Keenetic с установленным Entware;
- KeeneticOS с WireGuard;
- прямой доступ к RCI API удалённого Keenetic;
- на удалённом Keenetic — отдельная учётная запись администратора.

Установщик проверяет и при необходимости добавляет `ndmq`, `curl` и `cron`.

## Установка

```sh
wget -qO- https://raw.githubusercontent.com/org1org/keenetic-wg-watchdog/main/install.sh | sh
```

Затем:

```sh
kwg
```

Менеджер сначала покажет локальные интерфейсы `WireguardN`, затем пиры выбранного
интерфейса. Для задания нужно указать:

- туннельный адрес пира;
- независимый URL управления удалённым Keenetic;
- логин и пароль;
- системное имя удалённого туннеля (`Wireguard0`, `Wireguard1` и т. д.).

## Управление

В меню настроенного пира доступны проверка сейчас, принудительный перезапуск,
изменение настроек, включение/выключение и удаление задания.

События записываются в системный журнал Keenetic с тегом
`keenetic-wg-watchdog`.

## Удаление

```sh
wget -qO- https://raw.githubusercontent.com/org1org/keenetic-wg-watchdog/main/install.sh | sh -s -- --uninstall
```

Настройки сохраняются в `/opt/etc/keenetic-wg-watchdog.d`.

## Лицензия

[MIT](LICENSE) © 2026 org1org
