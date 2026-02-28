#!/usr/bin/env python3
# ═══════════════════════════════════════════════════════════════
# OPS Sentinel Suite — Web Dashboard Server
# ═══════════════════════════════════════════════════════════════
# Stdlib-only HTTP server for the Sentinel web dashboard.
# Serves JSON API endpoints + static dashboard HTML.
#
# Environment:
#   SENTINEL_LOGS    (default: ~/.sentinel-logs)
#   SENTINEL_CONFIG  (default: ~/.sentinel-config)
#   SENTINEL_HOME    (default: ~/.local/share/ops-sentinel)
#   WEB_PORT         (default: 8888)
#   WEB_TOKEN_FILE   (default: ~/.sentinel-config/web.token)
# ═══════════════════════════════════════════════════════════════

import http.server
import json
import os
import subprocess
import glob
import time
from pathlib import Path
from urllib.parse import urlparse, parse_qs

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SENTINEL_LOGS = os.environ.get("SENTINEL_LOGS", os.path.expanduser("~/.sentinel-logs"))
SENTINEL_CONFIG = os.environ.get("SENTINEL_CONFIG", os.path.expanduser("~/.sentinel-config"))
SENTINEL_HOME = os.environ.get("SENTINEL_HOME", os.path.expanduser("~/.local/share/ops-sentinel"))
WEB_PORT = int(os.environ.get("WEB_PORT", "8888"))
WEB_TOKEN_FILE = os.environ.get("WEB_TOKEN_FILE", os.path.expanduser("~/.sentinel-config/web.token"))
SCRIPT_DIR = Path(__file__).resolve().parent

# Load auth token (if file exists)
AUTH_TOKEN = None
try:
    token_path = Path(WEB_TOKEN_FILE)
    if token_path.is_file():
        AUTH_TOKEN = token_path.read_text().strip()
except Exception:
    AUTH_TOKEN = None


# ---------------------------------------------------------------------------
# Security helpers
# ---------------------------------------------------------------------------
def is_local(address):
    """Check if address is from a local/trusted subnet."""
    if address is None:
        return False
    return (
        address.startswith("127.")
        or address.startswith("192.168.")
        or address.startswith("10.")
        or address.startswith("100.")  # Tailscale
        or address == "::1"
    )


def check_auth(handler):
    """Validate token + local subnet. Returns None if OK, or (code, message) tuple."""
    if AUTH_TOKEN:
        provided = handler.headers.get("X-Sentinel-Token", "")
        if provided != AUTH_TOKEN:
            return (401, "Unauthorized: invalid or missing token")
    addr = handler.client_address[0] if handler.client_address else None
    if not is_local(addr):
        return (403, "Forbidden: non-local request")
    return None


# ---------------------------------------------------------------------------
# Request handler
# ---------------------------------------------------------------------------
class SentinelHandler(http.server.BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        """Suppress default request logging noise."""
        pass

    # -- Response helpers ---------------------------------------------------

    def _send_json(self, data, code=200):
        body = json.dumps(data).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, text, code=200, content_type="text/plain"):
        body = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, path, content_type="text/html"):
        try:
            data = Path(path).read_bytes()
        except FileNotFoundError:
            self._send_json({"error": "file not found"}, 404)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _send_error_json(self, code, message):
        self._send_json({"error": message}, code)

    # -- CORS preflight -----------------------------------------------------

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Sentinel-Token")
        self.send_header("Content-Length", "0")
        self.end_headers()

    # -- GET routing --------------------------------------------------------

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        params = parse_qs(parsed.query)

        if path == "/":
            self._handle_dashboard()
        elif path == "/api/status":
            self._handle_status()
        elif path == "/api/history":
            hours = params.get("hours", [None])[0]
            self._handle_history(hours)
        elif path == "/api/alerts":
            self._handle_alerts()
        elif path == "/api/actions":
            self._handle_actions()
        elif path == "/api/config":
            self._handle_config()
        else:
            self._send_error_json(404, "not found")

    # -- POST routing -------------------------------------------------------

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/")

        # Auth check for all POST endpoints
        auth_err = check_auth(self)
        if auth_err:
            self._send_error_json(auth_err[0], auth_err[1])
            return

        # Read body
        content_length = int(self.headers.get("Content-Length", 0))
        body_raw = self.rfile.read(content_length) if content_length > 0 else b"{}"
        try:
            body = json.loads(body_raw)
        except json.JSONDecodeError:
            self._send_error_json(400, "invalid JSON")
            return

        if path == "/api/action/restart":
            self._handle_restart(body)
        elif path == "/api/action/kill":
            self._handle_kill(body)
        elif path == "/api/action/config":
            self._handle_config_update(body)
        elif path == "/api/action/triage":
            self._handle_triage()
        else:
            self._send_error_json(404, "not found")

    # -- GET handlers -------------------------------------------------------

    def _handle_dashboard(self):
        # Try SCRIPT_DIR first, then SENTINEL_HOME
        for base in [SCRIPT_DIR, Path(SENTINEL_HOME)]:
            html_path = base / "sentinel-dashboard.html"
            if html_path.is_file():
                html = html_path.read_text()
                html = html.replace("{{AUTH_TOKEN}}", AUTH_TOKEN or "")
                html = html.replace("{{WEB_PORT}}", str(WEB_PORT))
                self._send_text(html, content_type="text/html")
                return
        self._send_error_json(404, "dashboard HTML not found")

    def _handle_status(self):
        status_file = Path(SENTINEL_LOGS) / "status.json"
        if not status_file.is_file():
            self._send_json({"error": "no status data yet"}, 404)
            return
        try:
            data = json.loads(status_file.read_text())
            self._send_json(data)
        except (json.JSONDecodeError, OSError) as e:
            self._send_json({"error": str(e)}, 500)

    def _handle_history(self, hours=None):
        history_file = Path(SENTINEL_LOGS) / "history.jsonl"
        if not history_file.is_file():
            self._send_json([])
            return
        try:
            lines = history_file.read_text().strip().splitlines()
            if hours is not None:
                try:
                    max_lines = int(hours) * 60
                    lines = lines[-max_lines:]
                except ValueError:
                    pass
            records = []
            for line in lines:
                line = line.strip()
                if line:
                    try:
                        records.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
            self._send_json(records)
        except OSError as e:
            self._send_json({"error": str(e)}, 500)

    def _handle_alerts(self):
        alerts_dir = Path(SENTINEL_LOGS) / "alerts"
        if not alerts_dir.is_dir():
            self._send_json([])
            return
        alert_files = sorted(
            glob.glob(str(alerts_dir / "*.json")) + glob.glob(str(alerts_dir / "*.txt")),
            key=lambda f: os.path.getmtime(f),
            reverse=True,
        )[:50]
        alerts = []
        for f in alert_files:
            try:
                if f.endswith(".json"):
                    alerts.append(json.loads(Path(f).read_text()))
                else:
                    alerts.append({
                        "file": os.path.basename(f),
                        "content": Path(f).read_text(),
                        "timestamp": time.strftime(
                            "%Y-%m-%dT%H:%M:%SZ", time.gmtime(os.path.getmtime(f))
                        ),
                    })
            except (json.JSONDecodeError, OSError):
                continue
        self._send_json(alerts)

    def _handle_actions(self):
        actions_file = Path(SENTINEL_LOGS) / "actions.jsonl"
        if not actions_file.is_file():
            self._send_json([])
            return
        try:
            lines = actions_file.read_text().strip().splitlines()
            records = []
            for line in lines:
                line = line.strip()
                if line:
                    try:
                        records.append(json.loads(line))
                    except json.JSONDecodeError:
                        continue
            self._send_json(records)
        except OSError as e:
            self._send_json({"error": str(e)}, 500)

    def _handle_config(self):
        config_file = Path(SENTINEL_CONFIG) / "sentinel.conf"
        if not config_file.is_file():
            self._send_json({"error": "config file not found"}, 404)
            return
        try:
            text = config_file.read_text()
            self._send_json({"config": text})
        except OSError as e:
            self._send_json({"error": str(e)}, 500)

    # -- POST handlers ------------------------------------------------------

    def _handle_restart(self, body):
        service = body.get("service")
        if not service:
            self._send_json({"ok": False, "error": "missing 'service' field"}, 400)
            return
        uid = os.getuid()
        cmd = ["launchctl", "kickstart", "-k", f"gui/{uid}/{service}"]
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            self._send_json({
                "ok": result.returncode == 0,
                "service": service,
                "stdout": result.stdout.strip(),
                "stderr": result.stderr.strip(),
                "returncode": result.returncode,
            })
        except Exception as e:
            self._send_json({"ok": False, "error": str(e)}, 500)

    def _handle_kill(self, body):
        pid = body.get("pid")
        name = body.get("name")
        if not pid and not name:
            self._send_json({"ok": False, "error": "missing 'pid' or 'name' field"}, 400)
            return
        try:
            if pid:
                cmd = ["kill", "-TERM", str(int(pid))]
            else:
                cmd = ["pkill", "-f", str(name)]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            self._send_json({
                "ok": result.returncode == 0,
                "target": pid or name,
                "stdout": result.stdout.strip(),
                "stderr": result.stderr.strip(),
                "returncode": result.returncode,
            })
        except Exception as e:
            self._send_json({"ok": False, "error": str(e)}, 500)

    def _handle_config_update(self, body):
        key = body.get("key")
        value = body.get("value")
        if not key or value is None:
            self._send_json({"ok": False, "error": "missing 'key' or 'value' field"}, 400)
            return
        config_file = Path(SENTINEL_CONFIG) / "sentinel.conf"
        if not config_file.is_file():
            self._send_json({"ok": False, "error": "config file not found"}, 404)
            return
        try:
            lines = config_file.read_text().splitlines()
            updated = False
            for i, line in enumerate(lines):
                stripped = line.strip()
                if stripped.startswith(f"{key}=") or stripped.startswith(f'{key}="'):
                    lines[i] = f'{key}="{value}"'
                    updated = True
                    break
            if not updated:
                lines.append(f'{key}="{value}"')
            config_file.write_text("\n".join(lines) + "\n")
            self._send_json({"ok": True, "key": key, "value": value, "updated": updated})
        except OSError as e:
            self._send_json({"ok": False, "error": str(e)}, 500)

    def _handle_triage(self):
        triage_script = SCRIPT_DIR / "sentinel-triage.sh"
        if not triage_script.is_file():
            triage_script = Path(SENTINEL_HOME) / "sentinel-triage.sh"
        if not triage_script.is_file():
            self._send_json({"ok": False, "error": "triage script not found"}, 404)
            return
        try:
            subprocess.Popen(
                ["bash", str(triage_script), "--auto"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            self._send_json({"ok": True, "message": "triage started in background"})
        except Exception as e:
            self._send_json({"ok": False, "error": str(e)}, 500)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    server = http.server.HTTPServer(("0.0.0.0", WEB_PORT), SentinelHandler)
    print(f"Sentinel web server running on 0.0.0.0:{WEB_PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()


if __name__ == "__main__":
    main()
