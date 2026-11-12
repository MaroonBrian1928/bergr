#!/usr/bin/env python3
"""bergr-notify: push an alert to Bergr when a herdr agent needs the user.

Runs next to herdr-core as a long-lived user service. It follows `hc events --json` (one JSON
object per line, each with the full current "terminals" list) and sends a push when a terminal's
status changes to blocked, error or done and the user has not looked at it yet (turn > herdr.seen).

Config: ~/.config/bergr/push.json (on Windows also %LOCALAPPDATA%\\bergr\\push.json), re-read when its mtime changes. Modes: "apns" (curl to APNs,
ES256 JWT signed with the openssl CLI;
separate sandbox and production keys under apns.sandbox / apns.production) and "ntfy" (POST to a topic).

Usage: bergr-notify.py [--test | --version]   (--test sends one test alert to every device and exits)
"""
import base64
import hashlib
import hmac
import json
import os
import re
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# Bumped when the script changes; the app compares it with the installed copy to offer updates.
VERSION = 11
CONFIG_PATH = os.path.expanduser("~/.config/bergr/push.json")


def default_config_path():
    """~/.config/bergr/push.json, where the app writes it; on Windows, %LOCALAPPDATA%\\bergr\\push.json
    when that exists and the first doesn't."""
    local = os.environ.get("LOCALAPPDATA")
    if os.name == "nt" and local:
        alt = os.path.join(local, "bergr", "push.json")
        if not os.path.exists(CONFIG_PATH) and os.path.exists(alt):
            return alt
    return CONFIG_PATH


ALERT_STATES = ("blocked", "error", "done")
# Passive for a finished agent, time-sensitive when someone has to act.
URGENCY = {"blocked": "time-sensitive", "error": "time-sensitive", "done": "passive"}
KINDS = ("permission", "question", "auth")
APP_NAMES = {"claude-code": "Claude", "codex": "Codex", "antigravity": "Antigravity"}
BODY_MAX = 180

# Commands that are hard to undo. Keep in step with Shared/DangerousCommand.swift (same patterns).
DANGEROUS_RULES = [
    ("recursive force delete (rm -rf)",
     r"\brm\b(?=[^;&|\n]*\s(?:-[a-z]*r|--recursive))(?=[^;&|\n]*\s(?:-[a-z]*f|--force))"),
    ("force push (git push --force)",
     r"\bgit\s+push\b[^;&|\n]*\s(?:--force(?:-with-lease)?\b|-[a-z]*f[a-z]*\b)"),
    ("hard reset (git reset --hard)", r"\bgit\s+reset\b[^;&|\n]*--hard\b"),
    ("git clean -f deletes untracked files", r"\bgit\s+clean\b[^;&|\n]*\s-[a-z]*f"),
    ("runs as root (sudo)", r"\bsudo\s"),
    ("formats a disk (mkfs)", r"\bmkfs(?:\.\w+)?\b"),
    ("raw disk write (dd if=)", r"\bdd\s+(?:\S+\s+)*?if="),
    ("drops or empties a database (DROP / TRUNCATE)", r"\bdrop\s+(?:table|database)\b|\btruncate\b"),
    ("opens permissions to everyone (chmod -R 777)",
     r"\bchmod\b(?=[^;&|\n]*\s(?:-[a-z]*r|--recursive))[^;&|\n]*\b777\b"),
    ("writes straight to a disk (> /dev/sd)", r">\s*/dev/sd"),
    ("destructive migration (reset / rollback / drop)", r"\bmigrate\b[^;&|\n]*\b(?:reset|rollback|drop)\b"),
]
_DANGEROUS = [(reason, re.compile(pattern, re.I)) for reason, pattern in DANGEROUS_RULES]


def dangerous_reason(text):
    """Why `text` (a permission prompt's command) is dangerous, or None."""
    for reason, regex in _DANGEROUS:
        if regex.search(text or ""):
            return reason
    return None


def last_sentences(text, count=2):
    """The last `count` sentences of `text`."""
    parts = [p.strip() for p in re.split(r"(?<=[.!?])\s+|\n+", text.strip()) if p.strip()]
    return " ".join(parts[-count:])
JWT_TTL = 50 * 60
RETRY_DELAY = 5


def log(msg):
    print(f"{time.strftime('%H:%M:%S')} bergr-notify: {msg}", file=sys.stderr, flush=True)


def initial_state():
    """last: address -> last status state seen; sent: (address, turn, state) already pushed."""
    return {"last": {}, "sent": set(), "terms": {}}


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


def format_alert(term, state, machine=""):
    """(title, body) for a terminal that just became `state` (blocked, error or done)."""
    status = term.get("status") if isinstance(term.get("status"), dict) else {}
    labels = term.get("labels") if isinstance(term.get("labels"), dict) else {}
    app = APP_NAMES.get(_text(status.get("app")), _text(status.get("app")) or "Agent")
    title = {"blocked": f"{app} needs you", "error": f"{app} hit an error"}.get(state, f"{app} finished")
    if machine:
        title += f" on {machine}"
    body = _text(labels.get("where")) or _text(term.get("title"))
    msg = _text(status.get("msg"))
    if state == "done" and msg:
        msg = last_sentences(msg)
        room = BODY_MAX - len(body) - 3 if body else BODY_MAX
        if len(msg) > room:  # keep the end of what the agent said
            msg = "…" + msg[-max(room - 1, 20):]
    if msg:
        body = f"{body} — {msg}" if body else msg
    kind = status.get("kind")
    if state == "blocked" and kind in KINDS:
        body = f"{body} ({kind})" if body else f"({kind})"
    if len(body) > BODY_MAX:
        body = body[:BODY_MAX - 1] + "…"
    return title, body


def alert_question(term, state):
    """The question a blocked agent asks, for the alert's answer buttons: {"title", "options",
    "keys"} or None. The helper only sees `hc events`, not the screen, so only a permission prompt
    (status kind "permission") is reliable: Yes / No, answered by key. Other questions (kind
    "question") have their options only on the screen, so they get no buttons."""
    if state != "blocked":
        return None
    status = term.get("status") if isinstance(term.get("status"), dict) else {}
    if status.get("kind") != "permission":
        return None
    title = _text(status.get("msg")) or _text(status.get("title")) or "Needs approval"
    # A dangerous command gets no approve buttons: it has to be answered in the app.
    if dangerous_reason(_text(status.get("msg")) + "\n" + _text(status.get("title"))):
        return None
    return {"title": title[:200], "options": ["Yes", "No"], "keys": True}


def apns_payload(title, body, address, host, state=None):
    payload = {
        "aps": {
            "alert": {"title": title, "body": body},
            "sound": "default",
            "thread-id": address,
        },
        "address": address,
        "host": host,
    }
    if state in URGENCY:
        payload["aps"]["interruption-level"] = URGENCY[state]
    return payload


def apply_event(terms, line):
    """Folds one `hc events` line into `terms` (address -> terminal record). The stream starts
    with a snapshot ({"terminals": [...]}), then sends one JSON-RPC notification per change
    ({"method": "event", "params": {"type", "terminal", "data"}}), a heartbeat every 15 s, and
    "missed" with a fresh snapshot after falling behind. Returns the new map, or None when the
    line changes nothing (heartbeats, unknown methods)."""
    msg = json.loads(line)
    if not isinstance(msg, dict):
        raise ValueError("not an object")
    if "terminals" in msg or msg.get("method") == "missed":
        terminals = msg["terminals"] if "terminals" in msg else (msg.get("params") or {}).get("terminals")
        if not isinstance(terminals, list):
            raise ValueError("terminals is not a list")
        return {t["address"]: t for t in terminals if isinstance(t, dict) and isinstance(t.get("address"), str)}
    if msg.get("method") != "event":
        return None
    p = msg.get("params") or {}
    kind, address, data = p.get("type"), p.get("terminal"), p.get("data")
    if not isinstance(address, str):
        return None
    terms = dict(terms)
    data = data if isinstance(data, dict) else {}
    if kind in ("created", "restarted"):
        terms[address] = data
        return terms
    if kind == "removed":
        terms.pop(address, None)
        return terms
    term = dict(terms.get(address) or {"address": address})
    if kind == "status":
        term["status"] = data.get("status")
        # When it last changed, as herdr-core's own records keep it (status_ms): the change
        # events don't carry a time, so it's the time the change arrived.
        term["status_ms"] = int(time.time() * 1000)
    elif kind == "turn":
        term["turn"] = data.get("turn")
    elif kind == "labels":
        record = data.get("record")
        if isinstance(record, dict):
            term = dict(record)
        else:
            term["labels"] = data.get("labels") or {}
    elif kind == "title":
        term["title"] = data.get("title")
    else:
        return None
    terms[address] = term
    return terms


def alerts_for(prev_state, line, machine=""):
    """Processes one `hc events` line. Returns (new_state, alerts); alerts are dicts with
    address, turn, state, title, body. A malformed line leaves the state unchanged."""
    prev = prev_state if prev_state is not None else initial_state()
    try:
        terms = apply_event(prev.get("terms", {}), line)
        if terms is None:
            return prev, []
        terminals = list(terms.values())
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
        turn_now = term.get("turn")
        known = address in last
        # herdr-core can report "done" before the turn number moves on, so a new turn while
        # still blocked/done counts as a change too.
        changed = known and (state != last[address][0] or (turn_now != last[address][1] and state in ALERT_STATES))
        last[address] = (state, turn_now)
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
        title, body = format_alert(term, state, machine)
        alert = {"address": address, "turn": turn, "state": state, "title": title, "body": body}
        question = alert_question(term, state)
        if question:
            alert["q"] = question
        alerts.append(alert)

    last = {a: s for a, s in last.items() if a in present}
    sent = {k for k in sent if k[0] in present}
    return {"last": last, "sent": sent, "terms": terms}, alerts


def activity_summary(terms, rows=False, host_id="", machine="", hide_after=0, now=None):
    """This machine's agents for the phone's Live Activity: how many need the user, work, are done,
    and (with `rows`, when the phone chose full content) the top three, needs-you first. Finished
    agents unchanged for longer than `hide_after` seconds (the phone's setting; 0: never) don't count."""
    now = time.time() if now is None else now
    needs, working, done = [], [], []
    for term in terms.values():
        status = term.get("status") if isinstance(term.get("status"), dict) else {}
        state = status.get("state")
        if state not in ("blocked", "working", "done"):
            continue
        if state == "done" and hide_after > 0:
            stamp = term.get("status_ms") or term.get("created_ms") or 0
            if isinstance(stamp, (int, float)) and stamp > 0 and now - stamp / 1000 > hide_after:
                continue
        if state == "blocked":
            needs.append(term)
        elif state == "working":
            working.append(term)
        else:
            done.append(term)
    out = {"needsYou": len(needs), "working": len(working), "done": len(done)}
    if rows:
        def row(term, needs_you):
            status = term.get("status") or {}
            app = status.get("app") or ""
            kind = {"claude-code": "claude", "codex": "codex", "antigravity": "antigravity"}.get(app, "shell")
            name = _text(term.get("name")) or _text(term.get("title")) or term.get("address", "")
            said = _text(status.get("msg")) or _text(status.get("title")) or ("Needs you" if needs_you else "Working")
            return {"kind": kind, "title": name[:60], "status": said[:80], "machine": machine[:40],
                    "needsYou": needs_you, "host": host_id[:64], "address": term.get("address", "")[:64]}
        out["rows"] = ([row(t, True) for t in needs] + [row(t, False) for t in working])[:3]
    return out


def _counts(summary):
    return (summary["needsYou"], summary["working"], summary["done"])


def parse_reply(raw):
    """The relay's JSON reply as a dict; {} when there is none or it isn't JSON."""
    try:
        answer = json.loads(raw or b"{}")
    except ValueError:
        return {}
    return answer if isinstance(answer, dict) else {}


class ActivityPoster:
    """Posts this machine's summary to the relay for the phone's Live Activity, only when something
    the phone shows has changed, so the traffic stays about as rare as push alerts:
    - Inactive (the relay last said no activity, or hasn't said): counts only, and only when a count
      changes: at least 2 s apart, at once when someone newly needs the user. Nothing while all counts
      are zero. A 300 s beat while any count is non-zero, for phone apps that don't seed the activity.
    - Active: a count change at least 2 s after the last post (at once when someone newly needs the
      user). In "full" mode, a change to row text or status alone at most every 20 s. A 300 s beat
      while any count is non-zero.
    A post that fails is not recorded; the same change is sent again after 30 s."""
    MIN_GAP, TEXT_GAP, BEAT, RETRY_DELAY = 2, 20, 300, 30
    ZERO = {"needsYou": 0, "working": 0, "done": 0}

    def __init__(self):
        self.devices = {}  # secret -> {"mode", "active", "last", "at", "retry_at", "hide_after"}

    def _device(self, secret):
        return self.devices.setdefault(secret, {"mode": "counts", "active": None, "last": None,
                                                "at": 0, "retry_at": 0})

    def due(self, secret, summary, now):
        d = self._device(secret)
        if now < d["retry_at"]:
            return False
        prev = d["last"] or self.ZERO
        gap = now - d["at"]
        if _counts(summary) != _counts(prev):
            return summary["needsYou"] > prev["needsYou"] or gap >= self.MIN_GAP
        if d["active"] and d["last"] is not None and summary != d["last"] and gap >= self.TEXT_GAP:
            return True
        return any(_counts(summary)) and gap >= self.BEAT

    def post(self, device, terms, host, now):
        secret = device["secret"]
        d = self._device(secret)
        host_id = device.get("host_id") or host
        rows = bool(d["active"]) and d["mode"] == "full"
        summary = activity_summary(terms, rows=rows, host_id=host_id, machine=host,
                                   hide_after=d.get("hide_after", 86400), now=now)
        if not self.due(secret, summary, now):
            return
        urgent = summary["needsYou"] > (d["last"] or self.ZERO)["needsYou"]
        d["at"] = now
        url = device["relay"].rstrip("/") + "/v1/activity/state"
        body = dict(summary, machine=host_id[:100], urgent=urgent)
        req = urllib.request.Request(url, data=json.dumps(body).encode("utf-8"), method="POST", headers={
            "authorization": "Bearer " + secret, "content-type": "application/json",
            "user-agent": f"bergr-notify/{VERSION}"})
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                if resp.status != 200:
                    raise RuntimeError(f"HTTP {resp.status}")
                raw = resp.read()
        except Exception as e:
            log(f"live activity update failed: {e}")
            d["retry_at"] = now + self.RETRY_DELAY
            return
        d["last"] = summary
        d["retry_at"] = 0
        self.learn(secret, parse_reply(raw))

    def learn(self, secret, answer):
        """Takes the relay's reply, to a post or to a push alert. Ignored when it has no "active"
        (an old relay)."""
        if "active" not in answer:
            return
        d = self._device(secret)
        d["active"] = bool(answer["active"])
        if isinstance(answer.get("hide_after"), int):
            if answer["hide_after"] != d.get("hide_after"):
                d["at"] = 0  # A different setting: send the counts it gives right away.
            d["hide_after"] = answer["hide_after"]
        if not d["active"]:
            d["mode"] = "counts"
            return
        mode = answer.get("mode") if answer.get("mode") in ("counts", "full") else "counts"
        if mode != d["mode"]:
            d["mode"] = mode
            d["at"] = 0  # The mode changed (full content now): send the rows right away.


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


def send_apns(cfg, device, title, body, address, host, jwt_cache, now, state=None):
    token = jwt_cache.get(apns_key(cfg["apns"], bool(device.get("sandbox"))), now)
    server = "api.sandbox.push.apple.com" if device.get("sandbox") else "api.push.apple.com"
    url = f"https://{server}/3/device/{device['token']}"
    payload = json.dumps(apns_payload(title, body, address, host, state)).encode("utf-8")
    cmd = ["curl", "--http2", "-sS", "-o", "NUL" if os.name == "nt" else "/dev/stderr", "-w", "%{http_code}", url,
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
        headers={"Title": header(title), "User-Agent": f"bergr-notify/{VERSION}",
                 "Click": "bergr://terminal/" + urllib.parse.quote(address, safe="")})
    with urllib.request.urlopen(req, timeout=15) as resp:
        resp.read()


def _hmac(key, data):
    return hmac.new(key, data, hashlib.sha256).digest()


def _keystream(enc, nonce, length):
    return b"".join(_hmac(enc, nonce + i.to_bytes(4, "big")) for i in range((length + 31) // 32))


def encrypt_alert(key_bytes, title, body, nonce=None, q=None):
    """Base64 blob the phone's Notification Service Extension decrypts (see Shared/PushAlertKey.swift).
    Version 2, standard library only: 0x02 || nonce (16) || ciphertext || tag (32). With the 64-byte
    alert key: enc = HMAC-SHA256(key, "bergr-enc"), mac = HMAC-SHA256(key, "bergr-mac"); keystream
    block i = HMAC-SHA256(enc, nonce || uint32be(i)); ciphertext = plaintext XOR keystream;
    tag = HMAC-SHA256(mac, 0x02 || nonce || ciphertext)."""
    if len(key_bytes) != 64:
        raise ValueError("alert key must be 64 bytes")
    nonce = os.urandom(16) if nonce is None else bytes(nonce)
    if len(nonce) != 16:
        raise ValueError("nonce must be 16 bytes")
    content = {"title": title, "body": body}
    if q:
        content["q"] = q  # {"title", "options" (up to 4), "keys"}: the phone's answer buttons
    plain = json.dumps(content, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    enc, mac = _hmac(key_bytes, b"bergr-enc"), _hmac(key_bytes, b"bergr-mac")
    cipher = bytes(a ^ b for a, b in zip(plain, _keystream(enc, nonce, len(plain))))
    signed = b"\x02" + nonce + cipher
    return base64.b64encode(signed + _hmac(mac, signed)).decode("ascii")


def decrypt_alert(key_bytes, blob):
    """Inverse of encrypt_alert (for tests). Raises ValueError when the tag doesn't match."""
    if len(key_bytes) != 64 or len(blob) < 1 + 16 + 32 or blob[0] != 2:
        raise ValueError("not a v2 blob")
    signed, tag = blob[:-32], blob[-32:]
    if not hmac.compare_digest(_hmac(_hmac(key_bytes, b"bergr-mac"), signed), tag):
        raise ValueError("bad tag")
    nonce, cipher = signed[1:17], signed[17:]
    stream = _keystream(_hmac(key_bytes, b"bergr-enc"), nonce, len(cipher))
    return json.loads(bytes(a ^ b for a, b in zip(cipher, stream)))


def relay_request(device, title, body, address, host, state=None, q=None):
    """(url, headers, body bytes) for a push through the relay."""
    url = device["relay"].rstrip("/") + "/v1/push"
    payload = {"title": title[:100], "body": body[:400], "address": address[:64], "host": host[:100]}
    if device.get("key"):
        # Never send the text in the clear when the phone has a key; fall back to a generic alert.
        try:
            key = base64.b64decode(device["key"], validate=True)
            payload = {"e": encrypt_alert(key, title[:100], body[:400], q=q),"address": address[:64], "host": host[:100]}
        except Exception as e:
            log(f"alert encryption failed ({type(e).__name__}); sending without text")
            payload = {"title": "Bergr", "body": "An agent needs you", "address": address[:64], "host": host[:100]}
    if state in URGENCY:
        payload["state"] = state  # in the clear: the relay needs it for the interruption level
    # Cloudflare turns away Python's default User-Agent (error 1010), so name ourselves.
    headers = {"authorization": "Bearer " + device["secret"], "content-type": "application/json",
               "user-agent": f"bergr-notify/{VERSION}"}
    return url, headers, json.dumps(payload).encode("utf-8")


def send_relay(device, title, body, address, host, state=None, q=None):
    """Sends one push through the device's relay. Returns the relay's reply (see ActivityPoster.learn)."""
    url, headers, data = relay_request(device, title, body, address, host, state, q)
    req = urllib.request.Request(url, data=data, method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return parse_reply(resp.read())
    except urllib.error.HTTPError as e:
        if e.code == 410:
            raise RuntimeError("the phone is no longer registered (turn push alerts off and on again in Bergr)")
        raise RuntimeError(f"relay HTTP {e.code}: {e.read()[:200].decode('utf-8', 'replace')}")


def send_alert(cfg, title, body, address, host, jwt_cache, on_reply=None, state=None, q=None):
    """Sends one alert to every device (through its relay, or straight to APNs with a key on this
    machine) or to the ntfy topic. Returns the successful sends. on_reply(secret, reply) gets each
    relay's reply."""
    mode = cfg.get("mode", "apns")
    sent = 0
    devices = [d for d in cfg.get("devices") or [] if isinstance(d, dict)]
    # Devices registered through a relay carry its address and a secret; the relay holds the key.
    # A device with "alerts": false wants only the Live Activity kept current, not notifications.
    for device in [d for d in devices if d.get("relay") and d.get("secret") and d.get("alerts", True) is not False]:
        try:
            # The app's own id for this machine when it gave one, so a tap opens the right one.
            reply = send_relay(device, title, body, address, device.get("host_id") or host, state, q)
            sent += 1
            if on_reply and isinstance(reply, dict):
                on_reply(device["secret"], reply)
        except Exception as e:
            log(f"push to {device.get('name', 'device')} through the relay failed: {e}")
    cfg = dict(cfg, devices=[d for d in devices if not (d.get("relay") and d.get("secret"))])
    if mode == "apns":
        now = int(time.time())
        for device in cfg.get("devices") or []:
            try:
                send_apns(cfg, device, title, body, address, host, jwt_cache, now, state)
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
    watcher = ConfigWatcher(default_config_path())
    jwt_cache = JwtCache()
    host = socket.gethostname()
    state = initial_state()
    poster = ActivityPoster()
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
                        state, alerts = alerts_for(state, line, host)
                    except Exception as e:
                        log(f"could not process event line: {e}")
                        continue
                    cfg = watcher.get()
                    if cfg is None:
                        continue
                    # Every line (a change, or the 15 s heartbeat): the Live Activity may be due.
                    for device in cfg.get("devices") or []:
                        if isinstance(device, dict) and device.get("relay") and device.get("secret"):
                            poster.post(device, state.get("terms", {}), host, time.time())
                    if not alerts:
                        continue
                    for a in alerts:
                        log(f"alert for {a['address']}: {a['title']}")
                        send_alert(cfg, a["title"], a["body"], a["address"], host, jwt_cache,
                                   on_reply=poster.learn, state=a["state"], q=a.get("q"))
            finally:
                if proc.poll() is None:
                    proc.kill()
                code = proc.wait()
            log(f"hc events exited with {code}")
        time.sleep(RETRY_DELAY)


def main(argv):
    if "--version" in argv:
        print(VERSION)
        return 0
    if "--test" in argv:
        cfg = ConfigWatcher(default_config_path()).get()
        if cfg is None:
            return 1
        sent = send_alert(cfg, "Bergr test", "Push alerts work", "test", socket.gethostname(), JwtCache())
        log(f"test alert sent {sent} time(s)")
        return 0 if sent else 1
    run()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
