#!/usr/bin/env python3
"""bergr-notify: push an alert to Bergr when a herdr agent needs the user.

Runs next to herdr-core as a long-lived user service. It follows `hc events --json` (one JSON
object per line, each with the full current "terminals" list) and sends a push when a terminal's
status changes to blocked or done and the user has not looked at it yet (turn > herdr.seen).

Config: ~/.config/bergr/push.json, re-read when its mtime changes. Modes: "apns" (curl to APNs,
ES256 JWT signed with the openssl CLI;
separate sandbox and production keys under apns.sandbox / apns.production) and "ntfy" (POST to a topic).

Usage: bergr-notify.py [--test]   (--test sends one test alert to every device and exits)
"""
import base64
import json
import os
import socket
import subprocess
import sys
import time
import urllib.parse
import urllib.request

CONFIG_PATH = os.path.expanduser("~/.config/bergr/push.json")
ALERT_STATES = ("blocked", "done")
KINDS = ("permission", "question", "auth")
APP_NAMES = {"claude-code": "Claude", "codex": "Codex", "antigravity": "Antigravity"}
BODY_MAX = 180
JWT_TTL = 50 * 60
RETRY_DELAY = 5


def log(msg):
    print(f"{time.strftime('%H:%M:%S')} bergr-notify: {msg}", file=sys.stderr, flush=True)


def initial_state():
    """last: address -> last status state seen; sent: (address, turn, state) already pushed."""
    return {"last": {}, "sent": set()}


def _text(value):
    return value if isinstance(value, str) else ""


# ---- pure functions

def _read_len(buf, i):
    first = buf[i]
    i += 1
    if first < 0x80:
        return first, i
    n = first & 0x7F
    if n == 0 or n > 4:
        raise ValueError("unsupported DER length")
    return int.from_bytes(buf[i:i + n], "big"), i + n


def der_to_raw(der, size=32):
    """DER ECDSA signature (SEQUENCE of two INTEGERs) to raw r || s, each `size` bytes."""
    try:
        if der[:1] != b"\x30":
            raise ValueError("not a DER SEQUENCE")
        _, i = _read_len(der, 1)
        parts = []
        for _ in range(2):
            if der[i:i + 1] != b"\x02":
                raise ValueError("expected INTEGER")
            n, i = _read_len(der, i + 1)
            value = der[i:i + n]
            if len(value) != n:
                raise ValueError("truncated INTEGER")
            i += n
            value = value.lstrip(b"\x00")  # DER pads with 0x00 when the high bit is set
            if len(value) > size:
                raise ValueError("INTEGER too large")
            parts.append(value.rjust(size, b"\x00"))
    except IndexError:
        raise ValueError("truncated signature")
    return b"".join(parts)


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def signing_input(key_id, team_id, now):
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id}, separators=(",", ":")).encode())
    claims = b64url(json.dumps({"iss": team_id, "iat": int(now)}, separators=(",", ":")).encode())
    return f"{header}.{claims}"


def make_jwt(team_id, key_id, key_path, now):
    unsigned = signing_input(key_id, team_id, now)
    out = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", os.path.expanduser(key_path)],
        input=unsigned.encode("ascii"), capture_output=True, timeout=30)
    if out.returncode != 0:
        raise RuntimeError("openssl sign failed: " + out.stderr.decode("utf-8", errors="replace").strip())
    return unsigned + "." + b64url(der_to_raw(out.stdout))


def format_alert(term, state):
    """(title, body) for a terminal that just became `state` (blocked or done)."""
    status = term.get("status") if isinstance(term.get("status"), dict) else {}
    labels = term.get("labels") if isinstance(term.get("labels"), dict) else {}
    app = APP_NAMES.get(_text(status.get("app")), _text(status.get("app")) or "Agent")
    title = f"{app} needs you" if state == "blocked" else f"{app} finished"
    body = _text(labels.get("where")) or _text(term.get("title"))
    msg = _text(status.get("msg"))
    if msg:
        body = f"{body} — {msg}" if body else msg
    kind = status.get("kind")
    if state == "blocked" and kind in KINDS:
        body = f"{body} ({kind})" if body else f"({kind})"
    if len(body) > BODY_MAX:
        body = body[:BODY_MAX - 1] + "…"
    return title, body


def apns_payload(title, body, address, host):
    return {
        "aps": {
            "alert": {"title": title, "body": body},
            "sound": "default",
            "thread-id": address,
        },
        "address": address,
        "host": host,
    }


def alerts_for(prev_state, line):
    """Processes one `hc events` line. Returns (new_state, alerts); alerts are dicts with
    address, turn, state, title, body. A malformed line leaves the state unchanged."""
    prev = prev_state if prev_state is not None else initial_state()
    try:
        event = json.loads(line)
        terminals = event["terminals"]
        if not isinstance(terminals, list):
            raise ValueError("terminals is not a list")
    except (ValueError, KeyError, TypeError) as e:
        log(f"ignoring malformed event line: {e}")
        return prev, []

    last = dict(prev["last"])
    sent = set(prev["sent"])
    present = set()
    alerts = []
    for term in terminals:
        if not isinstance(term, dict):
            continue
        address = term.get("address")
        if not isinstance(address, str) or not address:
            continue
        present.add(address)
        status = term.get("status") if isinstance(term.get("status"), dict) else {}
        state = status.get("state")
        known = address in last
        changed = known and state != last[address]
        last[address] = state
        if not changed or state not in ALERT_STATES or term.get("notify") is False:
            continue
        turn = term.get("turn")
        if not isinstance(turn, int) or isinstance(turn, bool):
            continue
        labels = term.get("labels") if isinstance(term.get("labels"), dict) else {}
        try:
            seen = int(labels.get("herdr.seen") or -1)
        except (TypeError, ValueError):
            seen = -1
        if turn <= seen:
            continue
        key = (address, turn, state)
        if key in sent:
            continue
        sent.add(key)
        title, body = format_alert(term, state)
        alerts.append({"address": address, "turn": turn, "state": state, "title": title, "body": body})

    last = {a: s for a, s in last.items() if a in present}
    sent = {k for k in sent if k[0] in present}
    return {"last": last, "sent": sent}, alerts


# ---- I/O

class ConfigWatcher:
    def __init__(self, path):
        self.path = path
        self.mtime = None
        self.config = None
        self.warned = False

    def get(self):
        try:
            mtime = os.stat(self.path).st_mtime_ns
        except OSError:
            if not self.warned:
                log(f"no {self.path}; not sending pushes")
                self.warned = True
            self.mtime = self.config = None
            return None
        if mtime != self.mtime:
            self.mtime = mtime
            try:
                with open(self.path, encoding="utf-8") as f:
                    self.config = json.load(f)
                if not isinstance(self.config, dict):
                    raise ValueError("not a JSON object")
                log(f"loaded {self.path}")
            except (OSError, ValueError) as e:
                log(f"cannot read {self.path}: {e}")
                self.config = None
        return self.config


def apns_key(apns, sandbox):
    """The key for one environment. Apple recommends separate keys: "sandbox" and "production"
    entries ({key_id, key_path}) under apns; a top-level key_id/key_path serves both."""
    env = apns.get("sandbox" if sandbox else "production")
    key = env if isinstance(env, dict) else apns
    return {"team_id": apns["team_id"], "key_id": key["key_id"], "key_path": key["key_path"]}


class JwtCache:
    """One token per key, reused for 50 minutes as Apple asks."""
    def __init__(self):
        self.tokens = {}

    def get(self, apns, now):
        key = (apns["team_id"], apns["key_id"], apns["key_path"])
        token, issued = self.tokens.get(key, (None, 0))
        if token is None or now - issued >= JWT_TTL:
            token = make_jwt(apns["team_id"], apns["key_id"], apns["key_path"], now)
            self.tokens[key] = (token, now)
        return token


def send_apns(cfg, device, title, body, address, host, jwt_cache, now):
    token = jwt_cache.get(apns_key(cfg["apns"], bool(device.get("sandbox"))), now)
    server = "api.sandbox.push.apple.com" if device.get("sandbox") else "api.push.apple.com"
    url = f"https://{server}/3/device/{device['token']}"
    payload = json.dumps(apns_payload(title, body, address, host)).encode("utf-8")
    cmd = ["curl", "--http2", "-sS", "-o", "/dev/stderr", "-w", "%{http_code}", url,
           "-H", f"authorization: bearer {token}",
           "-H", f"apns-topic: {device['bundle_id']}",
           "-H", "apns-push-type: alert",
           "-H", f"apns-collapse-id: {address}",
           "-H", "content-type: application/json",
           "--data-binary", "@-"]
    res = subprocess.run(cmd, input=payload, capture_output=True, timeout=30)
    code = res.stdout.decode("ascii", errors="replace").strip()
    if res.returncode != 0 or code != "200":
        detail = res.stderr.decode("utf-8", errors="replace").strip()[:300]
        raise RuntimeError(f"APNs HTTP {code or '?'} (curl exit {res.returncode}) {detail}")


def send_ntfy(cfg, title, body, address):
    def header(value):
        return value.encode("latin-1", "replace").decode("latin-1")  # urllib sends headers as latin-1
    req = urllib.request.Request(
        cfg["ntfy"]["url"], data=body.encode("utf-8"), method="POST",
        headers={"Title": header(title),
                 "Click": "bergr://terminal/" + urllib.parse.quote(address, safe="")})
    with urllib.request.urlopen(req, timeout=15) as resp:
        resp.read()


def send_alert(cfg, title, body, address, host, jwt_cache):
    """Sends one alert to every device (apns) or to the ntfy topic. Returns the successful sends."""
    mode = cfg.get("mode")
    sent = 0
    if mode == "apns":
        now = int(time.time())
        for device in cfg.get("devices") or []:
            try:
                send_apns(cfg, device, title, body, address, host, jwt_cache, now)
                sent += 1
            except Exception as e:
                name = device.get("name", "device") if isinstance(device, dict) else "device"
                log(f"push to {name} failed: {e}")
    elif mode == "ntfy":
        try:
            send_ntfy(cfg, title, body, address)
            sent += 1
        except Exception as e:
            log(f"ntfy push failed: {e}")
    else:
        log(f"unknown push mode {mode!r}")
    return sent


def run():
    watcher = ConfigWatcher(CONFIG_PATH)
    jwt_cache = JwtCache()
    host = socket.gethostname()
    state = initial_state()
    while True:
        try:
            proc = subprocess.Popen(["hc", "events", "--json"], stdout=subprocess.PIPE,
                                    text=True, encoding="utf-8", errors="replace")
        except OSError as e:
            log(f"cannot run hc events: {e}")
        else:
            try:
                for raw in proc.stdout:
                    line = raw.strip()
                    if not line:
                        continue
                    try:
                        state, alerts = alerts_for(state, line)
                    except Exception as e:
                        log(f"could not process event line: {e}")
                        continue
                    if not alerts:
                        continue
                    cfg = watcher.get()
                    if cfg is None:
                        continue
                    for a in alerts:
                        log(f"alert for {a['address']}: {a['title']}")
                        send_alert(cfg, a["title"], a["body"], a["address"], host, jwt_cache)
            finally:
                if proc.poll() is None:
                    proc.kill()
                code = proc.wait()
            log(f"hc events exited with {code}")
        time.sleep(RETRY_DELAY)


def main(argv):
    if "--test" in argv:
        cfg = ConfigWatcher(CONFIG_PATH).get()
        if cfg is None:
            return 1
        sent = send_alert(cfg, "Bergr test", "Push alerts work", "test", socket.gethostname(), JwtCache())
        log(f"test alert sent {sent} time(s)")
        return 0 if sent else 1
    run()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
