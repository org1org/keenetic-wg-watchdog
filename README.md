<div align="left">

<pre>
__        __    ____    __  __
\ \      / /   / ___|  |  \/  |
 \ \ /\ / /   | |  _   | |\/| |
  \ V  V /    | |_| |  | |  | |
   \_/\_/      \____|  |_|  |_|
</pre>

### Keenetic WG Watchdog

Серверный менеджер автоматического восстановления WireGuard-туннелей на KeeneticOS.

![version](https://img.shields.io/badge/version-0.1.0-blue)
![python](https://img.shields.io/badge/python-3.9%2B-3776AB)
![platform](https://img.shields.io/badge/platform-Linux-4EAA25)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![CI](https://github.com/org1org/keenetic-wg-watchdog/actions/workflows/ci.yml/badge.svg)](https://github.com/org1org/keenetic-wg-watchdog/actions/workflows/ci.yml)

</div>

## Для чего нужен

Программа устанавливается на Linux-сервер WireGuard. Она проверяет выбранного
пира и при длительной недоступности перезапускает соответствующий интерфейс на
удалённом Keenetic через штатный HTTP RCI API.

На самом Keenetic не нужны Entware, cron или дополнительные скрипты.

## Как работает

1. В менеджере выбирается локальный WireGuard-интерфейс сервера.
2. Затем выбирается пир. Адрес контроля определяется из его `AllowedIPs`, если
   там есть одиночный адрес `/32` или `/128`.
3. Указываются независимый адрес управления Keenetic и системное имя его
   интерфейса, например `Wireguard0`.
4. Раз в минуту сервер проверяет пир с привязкой ping к выбранному интерфейсу.
5. После двух последовательных ошибок программа отправляет на Keenetic команды
   `down`, ждёт 3 секунды и отправляет `up`.
6. Через 15 секунд выполняется контрольная проверка. Повторный перезапуск
   блокируется на 30 минут.

Программа не меняет ключи, пиры и постоянную конфигурацию WireGuard.

## Важное требование

Адрес HTTP API Keenetic **не должен маршрутизироваться через контролируемый
WireGuard-интерфейс**. После команды `down` такой путь исчезнет и сервер не
сможет отправить `up`.

Используйте отдельный канал управления: публичный HTTPS-адрес с ограничением по
IP сервера, отдельную управляющую VPN или локальную служебную сеть. Не открывайте
HTTP-интерфейс Keenetic всему интернету.

## Требования

- Linux с systemd;
- Python 3.9 или новее;
- `wireguard-tools`, `iproute2` и `ping`;
- права `root` для чтения WireGuard и установки службы;
- доступ сервера к HTTP RCI API Keenetic независимо от проверяемого туннеля.

Сторонние Python-пакеты не требуются.

## Установка

```sh
curl -fsSL https://raw.githubusercontent.com/org1org/keenetic-wg-watchdog/main/install.sh | sudo sh
```

После установки запустите менеджер:

```sh
sudo kwg
```

Менеджер последовательно покажет WireGuard-интерфейсы и их пиры. Для настройки
понадобятся:

- адрес пира внутри туннеля;
- независимый URL управления Keenetic;
- логин и пароль Keenetic;
- системное имя интерфейса Keenetic (`Wireguard0`, `Wireguard1` и т. д.).

При сохранении программа проверяет авторизацию, наличие интерфейса на Keenetic и,
если возможно, маршрут до API.

## Управление

```sh
sudo kwg                         # интерактивный менеджер
sudo keenetic-wg-watchdog --run  # проверить все задания
sudo keenetic-wg-watchdog --job wg0-xxxxxxxxxxxx
sudo keenetic-wg-watchdog --job wg0-xxxxxxxxxxxx --force-restart
```

Состояние таймера и журнал:

```sh
systemctl status keenetic-wg-watchdog.timer
journalctl -u keenetic-wg-watchdog.service
```

Настройки хранятся в `/etc/keenetic-wg-watchdog.d` с правами доступа только для
`root`. Временное состояние и cooldown находятся в `/run/keenetic-wg-watchdog`.

## HTTP API Keenetic

Используется штатная challenge-response авторизация KeeneticOS:

1. `GET /auth` возвращает `X-NDM-Realm` и `X-NDM-Challenge`;
2. программа вычисляет требуемые MD5/SHA-256 значения и создаёт сессию;
3. `POST /rci/interface/WireguardN` с `{"down":true}` выключает интерфейс;
4. запрос с `{"up":true}` включает его обратно.

KeenDNS может проксировать авторизацию иначе и не всегда возвращает необходимые
`X-NDM-*` заголовки. Версия 0.1.0 рассчитана на прямой доступ к RCI API.

## Удаление

```sh
curl -fsSL https://raw.githubusercontent.com/org1org/keenetic-wg-watchdog/main/install.sh | sudo sh -s -- --uninstall
```

Настройки при удалении сохраняются.

## Лицензия

[MIT](LICENSE) © 2026 org1org
