#!/usr/bin/env python3
"""Server-side WireGuard peer watchdog for KeeneticOS routers."""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import fcntl
import getpass
import hashlib
import http.cookiejar
import ipaddress
import json
import os
import re
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable, Iterable


VERSION = "0.1.0"
CONFIG_DIR = Path(os.environ.get("KWG_CONFIG_DIR", "/etc/keenetic-wg-watchdog.d"))
STATE_DIR = Path(os.environ.get("KWG_STATE_DIR", "/run/keenetic-wg-watchdog"))
WG_BIN = os.environ.get("KWG_WG", "wg")
PING_BIN = os.environ.get("KWG_PING", "ping")
DEFAULTS = {
    "ping_count": 3,
    "ping_timeout": 3,
    "failure_threshold": 2,
    "restart_delay": 3,
    "recovery_check_delay": 15,
    "restart_cooldown": 1800,
}
INTERFACE_RE = re.compile(r"^[A-Za-z0-9_.-]{1,32}$")


class AppError(RuntimeError):
    pass


@dataclasses.dataclass(frozen=True)
class Peer:
    interface: str
    public_key: str
    endpoint: str
    allowed_ips: tuple[str, ...]
    latest_handshake: int
    rx_bytes: int
    tx_bytes: int
    keepalive: int

    @property
    def short_key(self) -> str:
        return f"{self.public_key[:8]}…{self.public_key[-5:]}"


def run_command(args: list[str], *, check: bool = True) -> str:
    try:
        result = subprocess.run(args, text=True, capture_output=True, check=False)
    except OSError as exc:
        raise AppError(f"не удалось запустить {args[0]}: {exc}") from exc
    if check and result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or f"код {result.returncode}"
        raise AppError(f"команда {' '.join(args)} завершилась с ошибкой: {detail}")
    return result.stdout


def list_interfaces() -> list[str]:
    return run_command([WG_BIN, "show", "interfaces"]).split()


def list_peers(interface: str) -> list[Peer]:
    if not INTERFACE_RE.fullmatch(interface):
        raise AppError("недопустимое имя WireGuard-интерфейса")
    lines = run_command([WG_BIN, "show", interface, "dump"]).splitlines()
    peers: list[Peer] = []
    for line in lines[1:]:
        fields = line.split("\t")
        if len(fields) < 8:
            continue
        try:
            peers.append(Peer(
                interface=interface,
                public_key=fields[0],
                endpoint="" if fields[2] == "(none)" else fields[2],
                allowed_ips=tuple(x for x in fields[3].split(",") if x),
                latest_handshake=int(fields[4]),
                rx_bytes=int(fields[5]),
                tx_bytes=int(fields[6]),
                keepalive=int(fields[7].removesuffix("s")) if fields[7] not in {"off", "(none)"} else 0,
            ))
        except ValueError:
            continue
    return peers


def guess_target(allowed_ips: Iterable[str]) -> str | None:
    networks: list[ipaddress._BaseNetwork] = []
    for value in allowed_ips:
        with contextlib.suppress(ValueError):
            networks.append(ipaddress.ip_network(value, strict=False))
    exact = [str(net.network_address) for net in networks if net.prefixlen == net.max_prefixlen]
    if exact:
        return exact[0]
    private = [net for net in networks if net.is_private and net.num_addresses > 1]
    if len(private) == 1:
        return str(next(private[0].hosts(), private[0].network_address))
    return None


def validate_target(value: str) -> str:
    try:
        return str(ipaddress.ip_address(value.strip()))
    except ValueError as exc:
        raise AppError("адрес контроля должен быть одиночным IPv4 или IPv6-адресом") from exc


def validate_router_url(value: str) -> str:
    value = value.strip().rstrip("/")
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise AppError("адрес Keenetic должен начинаться с http:// или https://")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise AppError("в адресе Keenetic не должно быть логина, пароля, query или fragment")
    return value


def validate_remote_interface(value: str) -> str:
    value = value.strip()
    if not re.fullmatch(r"Wireguard[0-9]+", value):
        raise AppError("системное имя на Keenetic должно иметь вид Wireguard0")
    return value


def job_id(interface: str, public_key: str) -> str:
    digest = hashlib.sha256(public_key.encode()).hexdigest()[:12]
    safe_interface = re.sub(r"[^A-Za-z0-9_.-]", "_", interface)
    return f"{safe_interface}-{digest}"


def config_path(identifier: str) -> Path:
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", identifier):
        raise AppError("недопустимый идентификатор задания")
    return CONFIG_DIR / f"{identifier}.json"


def atomic_json_write(path: Path, data: dict[str, Any], mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temporary)


def load_config(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise AppError(f"не удалось прочитать {path}: {exc}") from exc
    required = {"id", "local_interface", "peer_public_key", "target_ip", "router_url",
                "router_user", "router_password", "remote_interface", "enabled"}
    if not isinstance(data, dict) or not required.issubset(data):
        raise AppError(f"неполная конфигурация {path}")
    return data


def load_all_configs() -> list[dict[str, Any]]:
    if not CONFIG_DIR.exists():
        return []
    result = []
    for path in sorted(CONFIG_DIR.glob("*.json")):
        try:
            result.append(load_config(path))
        except AppError as exc:
            log(str(exc), error=True)
    return result


def state_path(identifier: str) -> Path:
    return STATE_DIR / f"{identifier}.json"


def load_state(identifier: str) -> dict[str, Any]:
    defaults = {"failures": 0, "last_check": 0, "last_success": 0,
                "last_restart": 0, "last_result": "ещё не проверялось"}
    try:
        data = json.loads(state_path(identifier).read_text(encoding="utf-8"))
        if isinstance(data, dict):
            defaults.update({key: data[key] for key in defaults if key in data})
    except (OSError, json.JSONDecodeError):
        pass
    return defaults


def save_state(identifier: str, state: dict[str, Any]) -> None:
    atomic_json_write(state_path(identifier), state)


class KeeneticClient:
    def __init__(self, base_url: str, username: str, password: str,
                 *, verify_tls: bool = True, timeout: int = 10):
        self.base_url = validate_router_url(base_url)
        self.username = username
        self.password = password
        self.timeout = timeout
        self.cookies = http.cookiejar.CookieJar()
        password_manager = urllib.request.HTTPPasswordMgrWithDefaultRealm()
        password_manager.add_password(None, self.base_url, username, password)
        handlers: list[Any] = [
            urllib.request.HTTPCookieProcessor(self.cookies),
            urllib.request.HTTPDigestAuthHandler(password_manager),
        ]
        if not verify_tls:
            handlers.append(urllib.request.HTTPSHandler(
                context=ssl._create_unverified_context()))  # noqa: SLF001
        self.opener = urllib.request.build_opener(*handlers)
        self.authenticated = False

    def _open(self, path: str, payload: dict[str, Any] | None = None) -> Any:
        url = f"{self.base_url}{path}"
        data = None if payload is None else json.dumps(payload).encode()
        request = urllib.request.Request(
            url, data=data,
            headers={"Accept": "application/json", "Content-Type": "application/json"},
            method="GET" if payload is None else "POST",
        )
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace").strip()
            raise AppError(f"Keenetic API вернул HTTP {exc.code}{': ' + detail if detail else ''}") from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise AppError(f"Keenetic API недоступен: {exc}") from exc
        if not raw:
            return {}
        try:
            return json.loads(raw)
        except json.JSONDecodeError as exc:
            raise AppError("Keenetic API вернул некорректный JSON") from exc

    def authenticate(self) -> None:
        request = urllib.request.Request(f"{self.base_url}/auth", method="GET")
        try:
            with self.opener.open(request, timeout=self.timeout):
                self.authenticated = True
                return
        except urllib.error.HTTPError as exc:
            if exc.code != 401:
                raise AppError(f"авторизация Keenetic вернула HTTP {exc.code}") from exc
            realm = exc.headers.get("X-NDM-Realm")
            challenge = exc.headers.get("X-NDM-Challenge")
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise AppError(f"Keenetic недоступен: {exc}") from exc
        if not realm or not challenge:
            raise AppError("Keenetic не вернул X-NDM-Realm/X-NDM-Challenge; проверьте прямой доступ к RCI")
        first = hashlib.md5(
            f"{self.username}:{realm}:{self.password}".encode(), usedforsecurity=False
        ).hexdigest()
        key = hashlib.sha256(f"{challenge}{first}".encode()).hexdigest()
        self._open("/auth", {"login": self.username, "password": key})
        self.authenticated = True

    @staticmethod
    def _check_result(data: Any) -> None:
        if isinstance(data, dict):
            status = data.get("status")
            if isinstance(status, list):
                for item in status:
                    if isinstance(item, dict) and item.get("status") == "error":
                        raise AppError(f"Keenetic отклонил команду: {item.get('message', 'неизвестная ошибка')}")
            for value in data.values():
                KeeneticClient._check_result(value)
        elif isinstance(data, list):
            for value in data:
                KeeneticClient._check_result(value)

    def request(self, path: str, payload: dict[str, Any] | None = None) -> Any:
        if not self.authenticated:
            self.authenticate()
        try:
            result = self._open(path, payload)
        except AppError as exc:
            if "HTTP 401" not in str(exc):
                raise
            self.authenticated = False
            self.authenticate()
            result = self._open(path, payload)
        self._check_result(result)
        return result

    def check_interface(self, interface: str) -> Any:
        interface = validate_remote_interface(interface)
        result = self.request(f"/rci/show/interface/{urllib.parse.quote(interface, safe='')}")
        if result in ({}, [], None):
            raise AppError(f"интерфейс {interface} не найден на Keenetic")
        return result

    def restart_interface(self, interface: str, delay: int) -> None:
        interface = validate_remote_interface(interface)
        path = f"/rci/interface/{urllib.parse.quote(interface, safe='')}"
        self.request(path, {"down": True})
        try:
            time.sleep(delay)
        finally:
            # Always attempt to return the interface to the up state.
            last_error: AppError | None = None
            for attempt in range(3):
                try:
                    self.request(path, {"up": True})
                    return
                except AppError as exc:
                    last_error = exc
                    if attempt < 2:
                        time.sleep(2)
            raise AppError(f"не удалось вернуть {interface} в up после трёх попыток: {last_error}")


def ping_peer(interface: str, target: str, count: int, timeout: int) -> bool:
    family = "-6" if ipaddress.ip_address(target).version == 6 else "-4"
    result = subprocess.run(
        [PING_BIN, family, "-I", interface, "-c", str(count), "-W", str(timeout), target],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
    )
    return result.returncode == 0


def client_from_config(config: dict[str, Any]) -> KeeneticClient:
    return KeeneticClient(
        config["router_url"], config["router_user"], config["router_password"],
        verify_tls=bool(config.get("verify_tls", True)),
        timeout=int(config.get("api_timeout", 10)),
    )


def run_job(config: dict[str, Any], *, force_restart: bool = False,
            ping_fn: Callable[[str, str, int, int], bool] = ping_peer,
            client_factory: Callable[[dict[str, Any]], KeeneticClient] = client_from_config,
            now_fn: Callable[[], float] = time.time,
            sleep_fn: Callable[[float], None] = time.sleep) -> str:
    identifier = config["id"]
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    lock_path = STATE_DIR / f"{identifier}.lock"
    with lock_path.open("w", encoding="utf-8") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return "проверка уже выполняется"

        state = load_state(identifier)
        now = int(now_fn())
        if not config.get("enabled", True) and not force_restart:
            return "контроль выключен"

        if not force_restart and ping_fn(
            config["local_interface"], config["target_ip"],
            int(config.get("ping_count", DEFAULTS["ping_count"])),
            int(config.get("ping_timeout", DEFAULTS["ping_timeout"])),
        ):
            state.update(failures=0, last_check=now, last_success=now,
                         last_result="туннель работает")
            save_state(identifier, state)
            return state["last_result"]

        state["failures"] = int(state.get("failures", 0)) + 1
        state["last_check"] = now
        threshold = int(config.get("failure_threshold", DEFAULTS["failure_threshold"]))
        if not force_restart and state["failures"] < threshold:
            state["last_result"] = f"ошибка {state['failures']} из {threshold}"
            save_state(identifier, state)
            return state["last_result"]

        cooldown = int(config.get("restart_cooldown", DEFAULTS["restart_cooldown"]))
        last_restart = int(state.get("last_restart", 0))
        if not force_restart and last_restart and now - last_restart < cooldown:
            remaining = cooldown - (now - last_restart)
            state["last_result"] = f"cooldown, осталось {remaining} сек."
            save_state(identifier, state)
            return state["last_result"]

        client = client_factory(config)
        client.restart_interface(config["remote_interface"], int(
            config.get("restart_delay", DEFAULTS["restart_delay"])))
        state.update(last_restart=now, last_result="интерфейс перезапущен")
        save_state(identifier, state)
        sleep_fn(int(config.get("recovery_check_delay", DEFAULTS["recovery_check_delay"])))
        if ping_fn(
            config["local_interface"], config["target_ip"],
            int(config.get("ping_count", DEFAULTS["ping_count"])),
            int(config.get("ping_timeout", DEFAULTS["ping_timeout"])),
        ):
            state.update(failures=0, last_success=int(now_fn()), last_result="туннель восстановлен")
        else:
            state["last_result"] = "перезапущен, но пир недоступен"
        save_state(identifier, state)
        return state["last_result"]


def log(message: str, *, error: bool = False) -> None:
    stream = sys.stderr if error else sys.stdout
    print(message, file=stream, flush=True)


def human_time(epoch: int) -> str:
    return "никогда" if not epoch else time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(epoch))


def clear() -> None:
    if sys.stdout.isatty():
        print("\033[2J\033[H", end="")


def header(subtitle: str = "") -> None:
    clear()
    print(r"""__        __    ____    __  __
\ \      / /   / ___|  |  \/  |
 \ \ /\ / /   | |  _   | |\/| |
  \ V  V /    | |_| |  | |  | |
   \_/\_/      \____|  |_|  |_|""")
    print("\nKeenetic WG Watchdog")
    if subtitle:
        print(subtitle)
    print()


def pause() -> None:
    input("\nНажмите Enter, чтобы продолжить: ")


def choose(title: str, items: list[tuple[str, Any]], *, back: str = "Назад") -> Any | None:
    while True:
        header(title)
        for number, (label, _) in enumerate(items, 1):
            print(f"  {number}. {label}")
        print(f"  0. {back}")
        answer = input("\n> ").strip()
        if answer == "0" or answer.lower() in {"q", "quit", "выход"}:
            return None
        if answer.isdigit() and 1 <= int(answer) <= len(items):
            return items[int(answer) - 1][1]


def prompt(label: str, default: str = "", *, secret: bool = False) -> str:
    suffix = f" [{default}]" if default else ""
    value = getpass.getpass(f"{label}{suffix}: ") if secret else input(f"{label}{suffix}: ")
    return value.strip() or default


def yes_no(label: str, default: bool = True) -> bool:
    hint = "Д/н" if default else "д/Н"
    value = input(f"{label} [{hint}]: ").strip().lower()
    if not value:
        return default
    return value in {"д", "да", "y", "yes"}


def check_management_route(config: dict[str, Any]) -> str | None:
    host = urllib.parse.urlsplit(config["router_url"]).hostname
    if not host or not shutil.which("ip"):
        return None
    try:
        address = socket.getaddrinfo(host, None, type=socket.SOCK_STREAM)[0][4][0]
        route = run_command(["ip", "route", "get", address])
    except (AppError, OSError, socket.gaierror):
        return None
    match = re.search(r"\bdev\s+(\S+)", route)
    if match and match.group(1) == config["local_interface"]:
        return (f"маршрут к API Keenetic проходит через контролируемый интерфейс "
                f"{config['local_interface']}")
    return None


def configure_peer(peer: Peer) -> dict[str, Any] | None:
    identifier = job_id(peer.interface, peer.public_key)
    existing = {}
    path = config_path(identifier)
    if path.exists():
        existing = load_config(path)
    header(f"{peer.interface} · {peer.short_key}")
    print("Настройка удалённого Keenetic\n")
    guessed = existing.get("target_ip") or guess_target(peer.allowed_ips) or ""
    try:
        target = validate_target(prompt("Адрес пира для проверки", guessed))
        router_url = validate_router_url(prompt(
            "Адрес управления Keenetic (не через этот WG-туннель)",
            existing.get("router_url", "https://"),
        ))
        router_user = prompt("Пользователь Keenetic", existing.get("router_user", "admin"))
        router_password = prompt(
            "Пароль Keenetic (Enter — оставить прежний)" if existing else "Пароль Keenetic",
            existing.get("router_password", ""), secret=True,
        )
        if not router_password:
            raise AppError("пароль не может быть пустым")
        remote_interface = validate_remote_interface(prompt(
            "Системное имя туннеля на Keenetic",
            existing.get("remote_interface", "Wireguard0"),
        ))
        verify_tls = yes_no("Проверять TLS-сертификат", bool(existing.get("verify_tls", True)))
    except AppError as exc:
        print(f"\nОШИБКА: {exc}")
        pause()
        return None
    config: dict[str, Any] = {
        "id": identifier,
        "local_interface": peer.interface,
        "peer_public_key": peer.public_key,
        "target_ip": target,
        "router_url": router_url,
        "router_user": router_user,
        "router_password": router_password,
        "remote_interface": remote_interface,
        "verify_tls": verify_tls,
        "enabled": True,
        **{key: existing.get(key, value) for key, value in DEFAULTS.items()},
    }
    warning = check_management_route(config)
    if warning:
        print(f"\nОШИБКА: {warning}.")
        print("После команды down сервер не сможет отправить команду up.")
        pause()
        return None
    print("\nПроверяю HTTP API и интерфейс Keenetic…")
    try:
        client_from_config(config).check_interface(remote_interface)
    except AppError as exc:
        print(f"ОШИБКА: {exc}")
        if not yes_no("Сохранить настройки без успешной проверки", False):
            pause()
            return None
    atomic_json_write(path, config)
    print("\nГОТОВО: контроль пира настроен.")
    pause()
    return config


def peer_menu(peer: Peer) -> None:
    identifier = job_id(peer.interface, peer.public_key)
    while True:
        path = config_path(identifier)
        config = load_config(path) if path.exists() else None
        state = load_state(identifier)
        items: list[tuple[str, str]] = []
        if config:
            items.extend([
                ("Проверить сейчас", "check"),
                ("Принудительно перезапустить туннель на Keenetic", "restart"),
                ("Изменить настройки", "configure"),
                ("Выключить контроль" if config.get("enabled") else "Включить контроль", "toggle"),
                ("Удалить задание", "delete"),
            ])
        else:
            items.append(("Настроить контроль", "configure"))
        header(f"{peer.interface} · {peer.short_key}")
        print(f"Endpoint:       {peer.endpoint or 'нет'}")
        print(f"AllowedIPs:     {', '.join(peer.allowed_ips) or 'нет'}")
        print(f"Последний итог: {state['last_result']}")
        print(f"Успешная связь: {human_time(int(state['last_success']))}\n")
        for number, (label, _) in enumerate(items, 1):
            print(f"  {number}. {label}")
        print("  0. Назад")
        answer = input("\n> ").strip()
        if answer == "0":
            return
        if not answer.isdigit() or not 1 <= int(answer) <= len(items):
            continue
        action = items[int(answer) - 1][1]
        if action == "configure":
            configure_peer(peer)
        elif action == "toggle" and config:
            config["enabled"] = not config.get("enabled", True)
            atomic_json_write(path, config)
        elif action == "delete":
            if yes_no("Удалить это задание", False):
                path.unlink(missing_ok=True)
                state_path(identifier).unlink(missing_ok=True)
        elif action in {"check", "restart"} and config:
            print("\nВыполняю…")
            try:
                print(run_job(config, force_restart=action == "restart"))
            except AppError as exc:
                print(f"ОШИБКА: {exc}")
            pause()


def interactive() -> int:
    if os.geteuid() != 0:
        raise AppError("запустите менеджер с правами root")
    while True:
        interfaces = list_interfaces()
        if not interfaces:
            raise AppError("WireGuard-интерфейсы не найдены")
        interface = choose("Выберите WireGuard-сервер", [(name, name) for name in interfaces], back="Выход")
        if interface is None:
            return 0
        while True:
            peers = list_peers(interface)
            labels = []
            for peer in peers:
                configured = config_path(job_id(peer.interface, peer.public_key)).exists()
                marker = " · настроен" if configured else ""
                detail = ", ".join(peer.allowed_ips) or peer.endpoint or "без адреса"
                labels.append((f"{peer.short_key} · {detail}{marker}", peer))
            selected = choose(f"{interface} · выберите пира", labels)
            if selected is None:
                break
            peer_menu(selected)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Server-side watchdog for Keenetic WireGuard peers")
    parser.add_argument("--run", action="store_true", help="проверить все включённые задания")
    parser.add_argument("--job", help="проверить одно задание")
    parser.add_argument("--force-restart", action="store_true", help="принудительно перезапустить интерфейс")
    parser.add_argument("--version", action="store_true")
    args = parser.parse_args(argv)
    if args.version:
        print(VERSION)
        return 0
    if args.job:
        config = load_config(config_path(args.job))
        print(f"[{args.job}] {run_job(config, force_restart=args.force_restart)}")
        return 0
    if args.run:
        failed = False
        for config in load_all_configs():
            if not config.get("enabled", True):
                continue
            try:
                print(f"[{config['id']}] {run_job(config)}")
            except (AppError, OSError) as exc:
                failed = True
                log(f"[{config.get('id', '?')}] ошибка: {exc}", error=True)
        return 1 if failed else 0
    return interactive()


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AppError, KeyboardInterrupt) as exc:
        log(f"Ошибка: {exc}", error=True)
        raise SystemExit(1)
