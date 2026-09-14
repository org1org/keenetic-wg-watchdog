import hashlib
import http.server
import json
import os
import socketserver
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

import keenetic_wg_watchdog as app


class KeeneticHandler(http.server.BaseHTTPRequestHandler):
    realm = "Keenetic Test"
    challenge = "test-challenge"
    username = "watchdog"
    password = "secret"
    authenticated_cookie = "sid=ok"
    commands = []

    def log_message(self, *_args):
        pass

    def _json(self, status, body, headers=None):
        raw = json.dumps(body).encode()
        self.send_response(status)
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path == "/auth":
            if self.authenticated_cookie in self.headers.get("Cookie", ""):
                self._json(200, {})
            else:
                self._json(401, {}, {
                    "X-NDM-Realm": self.realm,
                    "X-NDM-Challenge": self.challenge,
                    "Set-Cookie": "sid=pending; Path=/; HttpOnly",
                })
        elif self.path == "/rci/show/interface/Wireguard0" and self.authenticated_cookie in self.headers.get("Cookie", ""):
            self._json(200, {"id": "Wireguard0", "type": "Wireguard", "connected": True})
        else:
            self._json(404, {})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length) or b"{}")
        if self.path == "/auth":
            first = hashlib.md5(
                f"{self.username}:{self.realm}:{self.password}".encode(), usedforsecurity=False
            ).hexdigest()
            expected = hashlib.sha256(f"{self.challenge}{first}".encode()).hexdigest()
            if (body == {"login": self.username, "password": expected}
                    and "sid=pending" in self.headers.get("Cookie", "")):
                self._json(200, {}, {"Set-Cookie": "sid=ok; Path=/; HttpOnly"})
            else:
                self._json(401, {})
        elif self.path == "/rci/interface/Wireguard0" and self.authenticated_cookie in self.headers.get("Cookie", ""):
            type(self).commands.append(body)
            self._json(200, {})
        else:
            self._json(404, {})


class ThreadingServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


class WatchdogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.state_dir = Path(self.temp.name) / "state"
        self.config_dir = Path(self.temp.name) / "config"
        self.state_patch = mock.patch.object(app, "STATE_DIR", self.state_dir)
        self.config_patch = mock.patch.object(app, "CONFIG_DIR", self.config_dir)
        self.state_patch.start()
        self.config_patch.start()
        self.addCleanup(self.state_patch.stop)
        self.addCleanup(self.config_patch.stop)

    def test_parse_wireguard_dump(self):
        dump = (
            "private\tpublic\t51820\toff\n"
            "peerkey\t(none)\t198.51.100.2:51820\t10.20.0.2/32,fd00::2/128\t123\t10\t20\t25\n"
        )
        with mock.patch.object(app, "run_command", return_value=dump):
            peers = app.list_peers("wg0")
        self.assertEqual(peers[0].allowed_ips, ("10.20.0.2/32", "fd00::2/128"))
        self.assertEqual(peers[0].keepalive, 25)

    def test_guess_exact_peer_address(self):
        self.assertEqual(app.guess_target(["10.20.0.2/32", "0.0.0.0/0"]), "10.20.0.2")

    def test_validation(self):
        self.assertEqual(app.validate_router_url("https://router.example/"), "https://router.example")
        self.assertEqual(app.validate_remote_interface("Wireguard12"), "Wireguard12")
        with self.assertRaises(app.AppError):
            app.validate_remote_interface("wg0")

    def test_keenetic_auth_check_and_restart(self):
        KeeneticHandler.commands = []
        server = ThreadingServer(("127.0.0.1", 0), KeeneticHandler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        client = app.KeeneticClient(
            f"http://127.0.0.1:{server.server_port}", "watchdog", "secret"
        )
        self.assertEqual(client.check_interface("Wireguard0")["id"], "Wireguard0")
        client.restart_interface("Wireguard0", 0)
        self.assertEqual(KeeneticHandler.commands, [{"down": True}, {"up": True}])

    def test_api_error_inside_http_200_is_rejected(self):
        with self.assertRaises(app.AppError):
            app.KeeneticClient._check_result({
                "status": [{"status": "error", "message": "unable to find interface"}]
            })

    def test_failure_threshold_and_recovery(self):
        config = {
            "id": "wg0-test", "enabled": True, "local_interface": "wg0",
            "target_ip": "10.0.0.2", "failure_threshold": 2,
            "restart_cooldown": 1800, "restart_delay": 0,
            "recovery_check_delay": 0, "ping_count": 1, "ping_timeout": 1,
            "remote_interface": "Wireguard0",
        }
        client = mock.Mock()
        client_factory = mock.Mock(return_value=client)
        first = app.run_job(config, ping_fn=lambda *_: False, client_factory=client_factory, now_fn=lambda: 100)
        self.assertEqual(first, "ошибка 1 из 2")
        outcomes = iter([False, True])
        second = app.run_job(config, ping_fn=lambda *_: next(outcomes), client_factory=client_factory,
                             now_fn=lambda: 200, sleep_fn=lambda _x: None)
        self.assertEqual(second, "туннель восстановлен")
        client.restart_interface.assert_called_once_with("Wireguard0", 0)

    def test_cooldown_blocks_second_restart(self):
        config = {
            "id": "wg0-test", "enabled": True, "local_interface": "wg0",
            "target_ip": "10.0.0.2", "failure_threshold": 1,
            "restart_cooldown": 1800, "restart_delay": 0,
            "recovery_check_delay": 0, "ping_count": 1, "ping_timeout": 1,
            "remote_interface": "Wireguard0",
        }
        app.save_state(config["id"], {
            "failures": 1, "last_check": 100, "last_success": 0,
            "last_restart": 100, "last_result": "перезапущен, но пир недоступен",
        })
        client_factory = mock.Mock()
        result = app.run_job(config, ping_fn=lambda *_: False, client_factory=client_factory, now_fn=lambda: 200)
        self.assertIn("cooldown", result)
        client_factory.assert_not_called()


if __name__ == "__main__":
    unittest.main()
