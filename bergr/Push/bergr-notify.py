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
import atexit
import base64
import datetime
import glob
import hashlib
import hmac
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

# Bumped when the script changes; the app compares it with the installed copy to offer updates.
VERSION = 26
CONFIG_PATH = os.path.expanduser("~/.config/bergr/push.json")
# Windows: child processes (hc, curl, git) get no console window; the helper runs under pythonw.exe,
# where each console child would otherwise flash a window.
NO_WINDOW = {"creationflags": 0x08000000} if os.name == "nt" else {}


def windows_setup(environ=None, stderr=None):
    """On Windows: puts herdr-core's folder on PATH (the Scheduled Task may start with a PATH that
    lacks it) and, under pythonw.exe (no stderr), logs to %LOCALAPPDATA%\\bergr\\bergr-notify.log.
    Returns the log file it opened, or None."""
    environ = os.environ if environ is None else environ
    local = environ.get("LOCALAPPDATA")
    if os.name != "nt" or not local:
        return None
    herdr = os.path.join(local, "Programs", "herdr-core")
    parts = environ.get("PATH", "").split(os.pathsep)
    if os.path.isdir(herdr) and herdr.lower() not in (p.lower() for p in parts):
        environ["PATH"] = os.pathsep.join([herdr] + [p for p in parts if p])
    if (stderr if stderr is not None else sys.stderr) is not None:
        return None
    try:
        d = os.path.join(local, "bergr")
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, "bergr-notify.log")
        if os.path.exists(path) and os.path.getsize(path) > 1 << 20:
            os.replace(path, path + ".1")
        sys.stderr = open(path, "a", encoding="utf-8", buffering=1)
        return sys.stderr
    except OSError:
        return None


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
# Passive for a finished agent, ordinary alerts when someone has to act.
URGENCY = {"blocked": "active", "error": "active", "done": "passive"}
KINDS = ("permission", "question", "auth")
APP_NAMES = {"claude-code": "Claude", "codex": "Codex", "antigravity": "Antigravity"}
BODY_MAX = 180

# Commands that are hard to undo. Keep in step with Shared/DangerousCommand.swift (same patterns).
DANGEROUS_RULES = [
    ("recursive force delete (rm -rf)",
     r"\brm\b(?=[^;&|\n]*\s(?:-[a-z]*r|--recursive))(?=[^;&|\n]*\s(?:-[a-z]*f|--force))"),
    ("force push (git push --force)",
     r"\bgit\s+push\b[^;&|\n]*\s(?:--force(?:-with-lease)?\b|-[a-z]*f[a-z]*\b|\+[^\s+])"),
    ("hard reset (git reset --hard)", r"\bgit\s+reset\b[^;&|\n]*--hard\b"),
    ("git clean -f deletes untracked files", r"\bgit\s+clean\b[^;&|\n]*\s(?:-[a-z]*f|--force\b)"),
    ("discards uncommitted changes (git checkout .)", r"\bgit\s+checkout\b[^;&|\n]*\s(?:--\s+)?\.(?=[\s;&|)]|$)"),
    ("discards uncommitted changes (git restore)",
     r"\bgit\s+restore\b(?:(?![^;&|\n]*\s--staged\b)|(?=[^;&|\n]*\s--worktree\b))"),
    ("deletes a branch (git branch -D)", r"\bgit\s+branch\b[^;&|\n]*(?-i:\s-[a-zA-Z]*D)"),
    ("deletes files (find -delete)", r"\bfind\b[^;&|\n]*\s(?:-delete\b|-exec(?:dir)?\s+rm\b)"),
    ("runs as root (sudo)", r"\bsudo\s"),
    ("formats a disk (mkfs)", r"\bmkfs(?:\.\w+)?\b"),
    ("raw disk write (dd if=)", r"\bdd\s+(?:\S+\s+)*?if="),
    ("raw disk write (dd of=/dev/)", r"\bdd\b[^;&|\n]*\bof=/dev/(?!null\b|stdout\b|stderr\b)"),
    ("drops or empties a database (DROP / TRUNCATE)", r"\bdrop\s+(?:table|database)\b|\btruncate\b"),
    ("deletes database rows (DELETE FROM)", r"\bdelete\s+from\b"),
    ("opens permissions to everyone (chmod -R 777)",
     r"\bchmod\b(?=[^;&|\n]*\s(?:-[a-z]*r|--recursive))[^;&|\n]*\b777\b"),
    ("changes owners recursively (chown -R)", r"\bchown\b[^;&|\n]*\s(?:-[a-z]*r[a-z]*|--recursive)\b"),
    ("writes straight to a disk (> /dev/sd)", r">\s*/dev/(?:sd|nvme|disk|hd|mmcblk)"),
    ("destructive migration (reset / rollback / drop)",
     r"\bmigrate\b[^;&|\n]*\b(?:reset|rollback|drop)\b"),
    ("destroys infrastructure (terraform destroy)", r"\b(?:terraform|tofu)\b[^;&|\n]*\s-?destroy\b"),
    ("deletes cluster resources (kubectl delete)", r"\bkubectl\b[^;&|\n]*\sdelete\b"),
    ("deletes containers or data (docker prune / rm -f)",
     r"\bdocker\s+(?:system\s+prune|volume\s+(?:rm|prune)\b|(?:container\s+)?rm\b[^;&|\n]*\s(?:-[a-z]*f[a-z]*|--force)\b)"),
    ("runs a script from the internet (curl | sh)",
     r"\b(?:curl|wget)\b[^;&\n]*\|\s*(?:sudo\s+)?(?:sh|bash|zsh|python[0-9.]*)\b|\b(?:sh|bash|zsh)\s+<\(\s*(?:curl|wget)\b"),
    ("shuts down the machine (shutdown / reboot)",
     r"(?:^|[;&|(\n:]|\bsudo|\bsystemctl|\bdoas)\s*(?:shutdown|reboot|halt|poweroff)\b"),
]
_DANGEROUS = [(reason, re.compile(pattern, re.I)) for reason, pattern in DANGEROUS_RULES]


# Notification settings a phone registers (device["prefs"], v13 on): kinds, muted agents, quiet
# hours in the phone's time zone. Missing or malformed prefs allow everything, as before.
PREF_KIND = {"blocked": "needs_you", "error": "error", "done": "finished"}


def _local_minute(quiet_tz, tz_offset, now):
    """Minutes after midnight on the phone: its zone name when this Python knows it (follows
    daylight saving), else the offset it registered with."""
    if quiet_tz:
        try:
            import zoneinfo
            t = datetime.datetime.fromtimestamp(now, zoneinfo.ZoneInfo(quiet_tz))
            return t.hour * 60 + t.minute
        except Exception:
            pass
    offset = tz_offset if isinstance(tz_offset, (int, float)) and not isinstance(tz_offset, bool) else 0
    t = datetime.datetime.fromtimestamp(now + offset * 60, datetime.timezone.utc)
    return t.hour * 60 + t.minute


def _in_quiet(prefs, now=None):
    """Whether the phone's quiet hours are on and cover `now`."""
    quiet = prefs.get("quiet") if isinstance(prefs, dict) else None
    if not isinstance(quiet, dict):
        return False
    start, end = quiet.get("start"), quiet.get("end")
    ints = all(isinstance(v, int) and not isinstance(v, bool) for v in (start, end))
    if not ints or start == end:
        return False
    minute = _local_minute(prefs.get("tz"), prefs.get("tz_offset"), time.time() if now is None else now)
    return (start <= minute < end) if start < end else (minute >= start or minute < end)


def _kind_on(prefs, state):
    kinds = prefs.get("kinds") if isinstance(prefs, dict) else None
    return not (isinstance(kinds, dict) and kinds.get(PREF_KIND[state], True) is False)


def prefs_verdict(prefs, state, address, now=None):
    """"send", "drop" (switch off or muted) or "quiet" (dropped only because of quiet hours, so
    it is worth a catch-up summary)."""
    if not isinstance(prefs, dict) or state not in PREF_KIND:
        return "send"
    if not _kind_on(prefs, state):
        return "drop"
    muted = prefs.get("muted")
    if isinstance(muted, list) and address in muted:
        return "drop"
    if state != "blocked" and _in_quiet(prefs, now):
        return "quiet"
    return "send"


def prefs_allow(prefs, state, address, now=None):
    """Whether a phone with these prefs wants an alert in `state` for `address`. Kind switch off,
    agent muted, or quiet hours (only blocked gets through) drop it. A state outside ALERT_STATES
    (a test alert) always passes."""
    return prefs_verdict(prefs, state, address, now) == "send"


def dangerous_reason(text):
    """Why `text` (a permission prompt's command) is dangerous, or None."""
    for reason, regex in _DANGEROUS:
        if regex.search(text or ""):
            return reason
    return None


# "Always allow" rules (v15): a phone registers device["rules"], each {machine, cwd, agent, command,
# prefix}. Mirrors bergr/Approvals/ApprovalRule.swift; both follow bergrTests/approval-rule-cases.json.
METACHARACTERS = set(";&|$`><\n\r")
_BORDERS = set("│┃║╭╮╰╯┌┐└┘─━═┆┊╎|")
_MARKERS = set("❯›>▶►→➤▸")


def command_eligible(command):
    """A plain command a rule may cover: no shell metacharacters, not dangerous."""
    return (isinstance(command, str) and command != "" and not (set(command) & METACHARACTERS)
            and dangerous_reason(command) is None)


def rule_matches(rule, machine, cwd, agent, command, now=None):
    """Exact command, or the rule's prefix followed by the end or a space; same machine, folder, agent.
    A rule with "expires" (seconds since 1970, v18 on) stops matching at that moment."""
    if not isinstance(rule, dict):
        return False
    expires = rule.get("expires")
    if expires is not None:
        if not isinstance(expires, (int, float)) or isinstance(expires, bool):
            return False
        if (time.time() if now is None else now) >= expires:
            return False
    r_cmd, r_machine, r_cwd, r_agent = (rule.get(k) for k in ("command", "machine", "cwd", "agent"))
    if not all(isinstance(v, str) for v in (r_machine, r_cwd, r_agent)) or not r_machine or not r_cwd:
        return False
    if r_machine != machine or r_cwd != cwd or r_agent != agent:
        return False
    if not command_eligible(r_cmd) or not command_eligible(command):
        return False
    if command == r_cmd:
        return True
    return rule.get("prefix") is True and command.startswith(r_cmd + " ")


def _clean(line):
    i, j = 0, len(line)
    while i < j and (line[i].isspace() or line[i] in _BORDERS):
        i += 1
    while j > i and (line[j - 1].isspace() or line[j - 1] in _BORDERS):
        j -= 1
    return line[i:j]


def _option(text):
    selected = False
    if text[:1] in _MARKERS and text:
        selected = True
        text = text[1:].lstrip(" ")
    m = re.match(r"([0-9]{1,2})\. (.*)$", text, re.S)
    if not m:
        return None
    label = m.group(2).strip(" \t")
    return (int(m.group(1)), label, selected) if label else None


def prompt_command(lines, cols, agent):
    """The command of Claude Code's Bash permission prompt at the bottom of the screen, when the screen
    is exactly that prompt with the cursor on "1. Yes"; None whenever unsure."""
    if agent != "claude-code" or not isinstance(cols, int):
        return None
    lines = [_clean(l) for l in lines]
    while lines and (lines[-1] == "" or lines[-1].startswith("Esc to cancel")):
        lines.pop()
    menu = []
    while lines and _option(lines[-1]):
        menu.insert(0, _option(lines.pop()))
    if (len(menu) < 2 or any(o[0] != i + 1 for i, o in enumerate(menu)) or menu[0][1] != "Yes"
            or not menu[0][2] or any(o[2] for o in menu[1:])):
        return None
    if not lines or lines.pop() != "Do you want to proceed?":
        return None
    while lines and lines[-1] == "":
        lines.pop()
    content = []
    while lines and lines[-1] != "" and lines[-1] != "Bash command":
        content.insert(0, lines.pop())
    while lines and lines[-1] == "":
        lines.pop()
    if not lines or lines[-1] != "Bash command" or not 1 <= len(content) <= 2:
        return None
    command = content[0]
    # A line this long may have wrapped: the second line could be the rest of the command.
    if len(command) + 8 > cols or not command_eligible(command):
        return None
    return command


def device_rules(cfg):
    """(machine id, rule) for every rule a device registered for this machine."""
    out = []
    for d in cfg.get("devices") or []:
        if isinstance(d, dict) and isinstance(d.get("host_id"), str) and isinstance(d.get("rules"), list):
            out += [(d["host_id"], r) for r in d["rules"] if isinstance(r, dict)]
    return out


def _glob_regex(pattern):
    return re.compile("".join(".*" if c == "*" else "." if c == "?" else re.escape(c) for c in pattern), re.I)


def ask_match(text, patterns):
    """Whether `text` contains one of the user's "always ask" patterns (v18 on): plain text or a simple
    glob (* any run, ? one character), case-insensitive, anywhere in the text. Mirrors AskPatterns.swift."""
    if not isinstance(text, str) or not isinstance(patterns, list):
        return False
    for p in patterns:
        if isinstance(p, str) and p.strip() and _glob_regex(p.strip()).search(text):
            return True
    return False


def device_ask_patterns(cfg):
    """Every "always ask" pattern any device registered: one phone's caution holds for the machine."""
    out = []
    for d in cfg.get("devices") or []:
        if isinstance(d, dict) and isinstance(d.get("askPatterns"), list):
            out += [p for p in d["askPatterns"] if isinstance(p, str)]
    return out


def _hc_json(args, runner):
    out = runner(["hc"] + args + ["--json"])
    value = json.loads(out) if out else None
    return value if isinstance(value, dict) else None


def _hc_run(args):
    res = subprocess.run(args, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=10,
                         **NO_WINDOW)
    if res.returncode != 0:
        raise RuntimeError(f"{' '.join(args[:2])} exited with {res.returncode}")
    return res.stdout


def _screen_command(address, runner):
    """(command, record) of a local terminal blocked on a Bash prompt, or (None, record)."""
    term = _hc_json(["get", address], runner)
    if not term:
        return None, None
    status = term.get("status") if isinstance(term.get("status"), dict) else {}
    if status.get("state") != "blocked" or status.get("kind") not in (None, "permission"):
        return None, term
    screen = _hc_json(["read", address], runner)
    if not screen or not isinstance(screen.get("text"), str):
        return None, term
    return prompt_command(screen["text"].split("\n"), term.get("cols"), status.get("app")), term


def auto_answer(cfg, address, runner=_hc_run):
    """Answers Yes for a blocked local terminal when a registered rule covers its command exactly as on
    screen. Returns (command, rule, record) when it pressed Enter, else None. Never for another machine's
    terminal (an address with "/"), a dangerous command, or a prompt it can't read with certainty."""
    rules = device_rules(cfg)
    if not rules or not isinstance(address, str) or not address or "/" in address:
        return None
    try:
        command, term = _screen_command(address, runner)
        if not command:
            return None
        status = term.get("status") or {}
        fg = term.get("foreground") if isinstance(term.get("foreground"), dict) else {}
        cwd = _text(fg.get("cwd")) or _text(term.get("cwd"))
        agent = _text(status.get("app"))
        if ask_match(command, device_ask_patterns(cfg)):
            return None
        rule = next((r for machine, r in rules if rule_matches(r, machine, cwd, agent, command)), None)
        if rule is None:
            return None
        # Read once more just before pressing: still the same command, still the same folder.
        again, term2 = _screen_command(address, runner)
        fg2 = (term2 or {}).get("foreground") if isinstance((term2 or {}).get("foreground"), dict) else {}
        if again != command or (_text(fg2.get("cwd")) or _text((term2 or {}).get("cwd"))) != cwd:
            return None
        runner(["hc", "keys", address, "enter"])
        return command, rule, term
    except Exception as e:
        log(f"auto-answer check failed for {address}: {e}")
        return None


AUTO_LOG_LIMIT = 200


def record_auto_answer(path, command, rule, term, now=None):
    """Appends to auto-approvals.json (next to push.json), which the app reads into its approvals log."""
    import uuid
    try:
        with open(path) as f:
            entries = json.load(f)
        if not isinstance(entries, list):
            entries = []
    except (OSError, ValueError):
        entries = []
    entries.append({"id": str(uuid.uuid4()).upper(), "at": time.time() if now is None else now, "command": command,
                    "machine": rule.get("machine"), "cwd": rule.get("cwd"), "agent": rule.get("agent"),
                    "address": term.get("address") if isinstance(term, dict) else None})
    entries = entries[-AUTO_LOG_LIMIT:]
    try:
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(entries, f)
        os.replace(tmp, path)
    except OSError as e:
        log(f"could not save auto-approvals: {e}")
    return entries


def auto_log_path(config_path=None):
    return os.path.join(os.path.dirname(config_path or default_config_path()), "auto-approvals.json")


# ---- Answering from a notification without opening the app (needs next version after 19).
#
# An alert with answer buttons carries an answerID ("a", random 128 bits). The helper keeps what it
# may answer (address, turn, question hash) in remote-answers.json for 10 minutes. The phone posts
# {machine, id, e} to the relay's mailbox; e is sealed with the device's alert key (see seal_answer)
# and binds the machine id and the answerID as associated data. The helper fetches, opens, checks
# that the same question is still on screen and only then presses keys, once.
REMOTE_TTL = 600
ANSWER_POLL = 3
ANSWER_ID_RE = re.compile(r"^[0-9a-f]{32}$")
REMOTE_SOURCE = "notification-remote"


def remote_answers_path(config_path=None):
    return os.path.join(os.path.dirname(config_path or default_config_path()), "remote-answers.json")


def question_hash(title):
    return hashlib.sha256(_text(title).encode("utf-8")).hexdigest()


def _load_pending(path):
    try:
        with open(path) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _save_pending(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f)
    try:
        os.chmod(tmp, 0o600)
    except OSError:
        pass
    os.replace(tmp, path)


def record_pending_answer(path, address, turn, title, now=None, answer_id=None):
    """Remembers a new answerID for (address, turn, question); returns it. Expired ones are dropped."""
    now = time.time() if now is None else now
    aid = answer_id or os.urandom(16).hex()
    data = {k: v for k, v in _load_pending(path).items()
            if isinstance(v, dict) and isinstance(v.get("expires"), (int, float)) and v["expires"] > now}
    data[aid] = {"address": address, "turn": turn, "qhash": question_hash(title), "title": _text(title)[:200],
                 "expires": now + REMOTE_TTL, "used": False}
    _save_pending(path, data)
    return aid


def has_pending(path, now=None):
    now = time.time() if now is None else now
    return any(isinstance(v, dict) and not v.get("used") and (v.get("expires") or 0) > now
               for v in _load_pending(path).values())


def _answer_keys(key_bytes):
    return _hmac(key_bytes, b"bergr-answer-enc"), _hmac(key_bytes, b"bergr-answer-mac")


def _answer_ad(machine, answer_id):
    return machine.encode("utf-8") + b"\x00" + answer_id.encode("utf-8")


def _answer_tag(mac, nonce, ad, cipher):
    return _hmac(mac, b"\x03" + nonce + len(ad).to_bytes(4, "big") + ad + cipher)


def seal_answer(key_bytes, machine, answer_id, choice, nonce=None):
    """The phone's answer envelope (Shared/PushAlertKey.swift sealAnswer), base64: 0x03 || nonce (16) ||
    ciphertext || tag (32). Keys from the 64-byte alert key: enc = HMAC-SHA256(key, "bergr-answer-enc"),
    mac = HMAC-SHA256(key, "bergr-answer-mac"); keystream as for alerts; ad = machine || 0x00 || answerID;
    tag = HMAC-SHA256(mac, 0x03 || nonce || uint32be(len(ad)) || ad || ciphertext). Plaintext: JSON
    {"choice", "id", "machine"}. Here for tests and the shared test vector."""
    if len(key_bytes) != 64:
        raise ValueError("alert key must be 64 bytes")
    nonce = os.urandom(16) if nonce is None else bytes(nonce)
    enc, mac = _answer_keys(key_bytes)
    plain = json.dumps({"choice": choice, "id": answer_id, "machine": machine},
                       separators=(",", ":"), sort_keys=True).encode("utf-8")
    cipher = bytes(x ^ y for x, y in zip(plain, _keystream(enc, nonce, len(plain))))
    ad = _answer_ad(machine, answer_id)
    return base64.b64encode(b"\x03" + nonce + cipher + _answer_tag(mac, nonce, ad, cipher)).decode("ascii")


def open_answer(key_bytes, machine, answer_id, e):
    """The choice ("yes", "no" or an option index) in an answer envelope sealed for this machine and
    answerID; raises ValueError when it was changed, made with another key, or bound to anything else."""
    if len(key_bytes) != 64 or not isinstance(e, str) or len(e) > 2000:
        raise ValueError("bad envelope")
    blob = base64.b64decode(e, validate=True)
    if len(blob) < 1 + 16 + 32 or blob[0] != 3:
        raise ValueError("bad envelope")
    nonce, cipher, tag = blob[1:17], blob[17:-32], blob[-32:]
    enc, mac = _answer_keys(key_bytes)
    if not hmac.compare_digest(_answer_tag(mac, nonce, _answer_ad(machine, answer_id), cipher), tag):
        raise ValueError("bad tag")
    plain = json.loads(bytes(x ^ y for x, y in zip(cipher, _keystream(enc, nonce, len(cipher)))))
    if not isinstance(plain, dict) or plain.get("id") != answer_id or plain.get("machine") != machine:
        raise ValueError("bound to something else")
    choice = plain.get("choice")
    if choice in ("yes", "no") or (isinstance(choice, int) and not isinstance(choice, bool) and 0 <= choice < 9):
        return choice
    raise ValueError("bad choice")


def prompt_menu(lines):
    """The numbered menu at the bottom of the screen: [(number, label, selected)], numbered from 1 with
    exactly one selected; None when it isn't exactly that."""
    lines = [_clean(l) for l in lines]
    while lines and (lines[-1] == "" or lines[-1].startswith("Esc to cancel")):
        lines.pop()
    menu = []
    while lines and _option(lines[-1]):
        menu.insert(0, _option(lines.pop()))
    if len(menu) < 2 or any(o[0] != i + 1 for i, o in enumerate(menu)) or sum(1 for o in menu if o[2]) != 1:
        return None
    return menu


_YN = re.compile(r"[\(\[]\s*y\s*/\s*n\s*[\)\]]", re.I)


def answer_keys(lines, choice):
    """(keys to press, label) for `choice` on this screen, or None when the prompt isn't one it knows."""
    menu = prompt_menu(lines)
    if menu:
        if choice in ("yes", "no"):
            target = next((i for i, o in enumerate(menu) if o[1].lower().startswith(choice)), None)
        else:
            target = choice if choice < len(menu) else None
        if target is None:
            return None
        at = next(i for i, o in enumerate(menu) if o[2])
        steps = ["down"] * (target - at) if target >= at else ["up"] * (at - target)
        return steps + ["enter"], menu[target][1]
    last = next((_clean(l) for l in reversed(lines) if _clean(l)), "")
    if choice in ("yes", "no") and _YN.search(last):
        return [choice[0]], choice.capitalize()
    return None


def _check_screen(cfg, address, rec, choice, runner):
    """(keys, label, term, screen text) when the same question is still asked; else (None, reason, ...)."""
    term = _hc_json(["get", address], runner)
    if not term:
        return None, "the terminal is gone", None, None
    status = term.get("status") if isinstance(term.get("status"), dict) else {}
    if status.get("state") != "blocked":
        return None, "the agent isn't waiting any more", term, None
    if term.get("turn") != rec.get("turn"):
        return None, "the agent moved on", term, None
    title = _text(status.get("msg")) or _text(status.get("title"))
    if dangerous_reason(_text(status.get("msg")) + "\n" + _text(status.get("title"))):
        return None, "it's a dangerous command", term, None
    q = alert_question(term, "blocked")
    if not q or question_hash(q["title"]) != rec.get("qhash"):
        return None, "the question changed", term, None
    screen = _hc_json(["read", address], runner)
    text = screen.get("text") if isinstance(screen, dict) else None
    if not isinstance(text, str):
        return None, "couldn't read the screen", term, None
    if dangerous_reason(text):
        return None, "it's a dangerous command", term, text
    if ask_match(title + "\n" + text, device_ask_patterns(cfg)):
        return None, "it matches an always-ask pattern", term, text
    found = answer_keys(text.split("\n"), choice)
    if not found:
        return None, "couldn't read the prompt", term, text
    return found[0], found[1], term, text


def remote_answer(cfg, machine, key_bytes, item, path, runner=_hc_run, now=None):
    """Handles one answer from the relay. Returns ("answered", label, rec, term), ("refused", reason, rec,
    term) or ("ignored", reason, None, None): ignored ones (forged, unknown, replayed) get no push."""
    now = time.time() if now is None else now
    aid = item.get("id") if isinstance(item, dict) else None
    if not isinstance(aid, str) or not ANSWER_ID_RE.match(aid):
        return "ignored", "bad id", None, None
    try:
        choice = open_answer(key_bytes, machine, aid, item.get("e"))
    except (ValueError, TypeError) as e:
        return "ignored", f"envelope rejected ({e})", None, None
    data = _load_pending(path)
    rec = data.get(aid)
    if not isinstance(rec, dict):
        return "ignored", "unknown answer id", None, None
    if rec.get("used"):
        return "ignored", "already used", None, None
    rec["used"] = True  # single use, whatever happens next
    data[aid] = rec
    _save_pending(path, data)
    if not isinstance(rec.get("expires"), (int, float)) or rec["expires"] <= now:
        return "refused", "the answer came too late", rec, None
    address = rec.get("address")
    if not isinstance(address, str) or not address or "/" in address:
        return "refused", "not a local terminal", rec, None
    try:
        keys, label, term, text = _check_screen(cfg, address, rec, choice, runner)
        if keys is None:
            return "refused", label, rec, term
        # Once more just before pressing: still exactly the same screen.
        keys2, _, _, text2 = _check_screen(cfg, address, rec, choice, runner)
        if keys2 != keys or text2 != text:
            return "refused", "the screen changed", rec, term
        runner(["hc", "keys", address] + keys)
        return "answered", label, rec, term
    except Exception as e:
        log(f"remote answer failed for {address}: {e}")
        return "refused", "couldn't check the terminal", rec, None


def record_remote_answer(path, question, answer, machine, term, now=None):
    """Logs a remote answer in auto-approvals.json (the app's approvals log), source notification-remote."""
    import uuid
    try:
        with open(path) as f:
            entries = json.load(f)
        if not isinstance(entries, list):
            entries = []
    except (OSError, ValueError):
        entries = []
    term = term if isinstance(term, dict) else {}
    status = term.get("status") if isinstance(term.get("status"), dict) else {}
    fg = term.get("foreground") if isinstance(term.get("foreground"), dict) else {}
    entries.append({"id": str(uuid.uuid4()).upper(), "at": time.time() if now is None else now, "command": question,
                    "answer": answer, "source": REMOTE_SOURCE, "machine": machine,
                    "cwd": _text(fg.get("cwd")) or _text(term.get("cwd")) or None,
                    "agent": _text(status.get("app")), "address": term.get("address")})
    entries = entries[-AUTO_LOG_LIMIT:]
    try:
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(entries, f)
        os.replace(tmp, path)
    except OSError as e:
        log(f"could not save the approvals log: {e}")
    return entries


def fetch_answers(device, machine):
    """Takes this machine's waiting answers from the relay mailbox (it deletes them as it hands them out)."""
    url = device["relay"].rstrip("/") + "/v1/answers?machine=" + urllib.parse.quote(machine, safe="")
    req = urllib.request.Request(url, method="GET", headers={
        "authorization": "Bearer " + device["secret"], "user-agent": f"bergr-notify/{VERSION}"})
    with urllib.request.urlopen(req, timeout=10) as resp:
        answers = parse_reply(resp.read()).get("answers")
    return [a for a in answers if isinstance(a, dict)] if isinstance(answers, list) else []


def poll_answers(cfg, path, host, sender, fetch=fetch_answers, runner=_hc_run, log_path=None, now=None):
    """Fetches and handles every device's answers once. sender(title, body, address, state) pushes."""
    for device in cfg.get("devices") or []:
        if not (isinstance(device, dict) and device.get("relay") and device.get("secret") and device.get("key")):
            continue
        machine = device.get("host_id") or host
        try:
            key = base64.b64decode(device["key"], validate=True)
            items = fetch(device, machine)
        except Exception as e:
            log(f"could not fetch answers: {e}")
            continue
        for item in items:
            outcome, detail, rec, term = remote_answer(cfg, machine, key, item, path, runner, now)
            if outcome == "ignored":
                log(f"ignored a remote answer: {detail}")
                continue
            address = rec.get("address") or ""
            if outcome == "answered":
                log(f"answered {detail!r} for {address} from a notification")
                record_remote_answer(log_path or auto_log_path(), rec.get("title") or "", detail, machine, term)
                sender(f"Answered {detail} on {host}", rec.get("title") or "", address, "done")
            else:
                log(f"refused a remote answer for {address}: {detail}")
                sender("Couldn't answer — open Bergr", detail[:1].upper() + detail[1:] + ".", address, "blocked")


class AnswerPoller(threading.Thread):
    """Asks the relay for answers every few seconds, only while an answerID is waiting."""

    def __init__(self, watcher, path, host, jwt_cache):
        super().__init__(daemon=True)
        self.watcher, self.path, self.host, self.jwt_cache = watcher, path, host, jwt_cache

    def run(self):
        while True:
            time.sleep(ANSWER_POLL)
            try:
                if not has_pending(self.path):
                    continue
                cfg = ConfigWatcher(self.watcher.path).get()
                if cfg is None:
                    continue
                poll_answers(cfg, self.path, self.host, lambda t, b, a, s: send_alert(
                    cfg, t, b, a, self.host, self.jwt_cache, state=s))
            except Exception as e:
                log(f"answer poll failed: {e}")


def last_sentences(text, count=2):
    """The last `count` sentences of `text`."""
    parts = [p.strip() for p in re.split(r"(?<=[.!?])\s+|\n+", text.strip()) if p.strip()]
    return " ".join(parts[-count:])
JWT_TTL = 50 * 60
RETRY_DELAY = 5


# Low-disk and low-battery alerts (v14): checked at most once a minute from the events loop (no extra
# daemon), pushed as an "error" alert once per crossing. The state file sits next to push.json.
GIB = 1 << 30
LOW_DISK_BYTES, LOW_DISK_PERCENT = 5 * GIB, 5.0
DISK_RECOVER_BYTES, DISK_RECOVER_PERCENT = 6 * GIB, 6.0
LOW_BATTERY, BATTERY_RECOVER = 15, 20
HEALTH_INTERVAL = 60


def disk_reading(path=None):
    """(free bytes, total bytes) of the home volume (the drive of the profile on Windows), or None."""
    try:
        usage = shutil.disk_usage(path or os.path.expanduser("~"))
    except OSError:
        return None
    return (usage.free, usage.total) if usage.total > 0 else None


def battery_reading():
    """(percent, discharging) on macOS and Linux machines with a battery, else None. Windows is
    skipped: disk alerts only."""
    try:
        if sys.platform == "darwin":
            out = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True, timeout=5).stdout
            return parse_pmset(out)
        if sys.platform.startswith("linux"):
            import glob
            for cap in sorted(glob.glob("/sys/class/power_supply/*/capacity")):
                with open(cap) as f:
                    percent = int(f.read().strip())
                try:
                    with open(os.path.join(os.path.dirname(cap), "status")) as f:
                        status = f.read().strip().lower()
                except OSError:
                    status = ""
                return min(100, percent), status == "discharging"
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    return None


def parse_pmset(out):
    """"...87%; discharging; 5:00 remaining" -> (87, True); None without a percentage."""
    m = re.search(r"(\d{1,3})%;?\s*([A-Za-z ]*)", out or "")
    if not m:
        return None
    return min(100, int(m.group(1))), m.group(2).strip().lower().startswith("discharging")


def health_alerts(prev, disk=None, battery=None):
    """(alerts, new flags). prev: {"disk": bool, "battery": bool}, whether each is already alerted.
    An alert is (key, title, body). A flag clears only past the recovery margin, so a value hovering at
    the threshold doesn't alert again."""
    flags = {"disk": bool(prev.get("disk")), "battery": bool(prev.get("battery"))}
    alerts = []
    if disk:
        free, total = disk
        percent = free / total * 100
        low = free < LOW_DISK_BYTES or percent < LOW_DISK_PERCENT
        ok = free >= DISK_RECOVER_BYTES and percent >= DISK_RECOVER_PERCENT
        if low and not flags["disk"]:
            flags["disk"] = True
            alerts.append(("disk", "Disk almost full", f"{free / GIB:.1f} GB free ({percent:.0f}%)"))
        elif ok:
            flags["disk"] = False
    if battery:
        percent, discharging = battery
        if percent < LOW_BATTERY and discharging and not flags["battery"]:
            flags["battery"] = True
            alerts.append(("battery", "Battery low", f"{percent}% and not charging"))
        elif percent >= BATTERY_RECOVER or not discharging:
            flags["battery"] = False
    return alerts, flags


def health_state_path(config_path=None):
    return os.path.join(os.path.dirname(config_path or default_config_path()), "health-state.json")


def check_health(cfg, host, jwt_cache, state_path, disk=None, battery=None, sender=None):
    """Reads disk and battery, pushes each new crossing, saves the flags. Returns the alerts sent."""
    try:
        with open(state_path) as f:
            prev = json.load(f)
        if not isinstance(prev, dict):
            prev = {}
    except (OSError, ValueError):
        prev = {}
    alerts, flags = health_alerts(prev, disk, battery)
    if flags != {"disk": bool(prev.get("disk")), "battery": bool(prev.get("battery"))}:
        try:
            with open(state_path, "w") as f:
                json.dump(flags, f)
        except OSError as e:
            log(f"could not save health state: {e}")
    for key, title, body in alerts:
        log(f"health alert: {title}")
        (sender or send_alert)(cfg, f"{host}: {title}", body, "health", host, jwt_cache, state="error")
    return alerts


# Quiet-hours catch-up (v17): alerts dropped only because of quiet hours are counted per device in
# quiet-drops.json (beside push.json); once that device's quiet hours are over, ONE summary push
# goes out and its counts are cleared. Checked at most once a minute from the events loop.
QUIET_INTERVAL = 60
_drop_path = None  # set by run(); None records nothing


def quiet_drops_path(config_path=None):
    return os.path.join(os.path.dirname(config_path or default_config_path()), "quiet-drops.json")


def device_key(device):
    return str(device.get("secret") or device.get("token") or device.get("id") or device.get("name") or "device")


def _drop_category(state, address, title):
    if state == "done":
        return "finished"
    if address == "health":
        low = (title or "").lower()
        if "battery" in low:
            return "battery"
        if "disk" in low:
            return "disk"
    return "error"


def _load_drops(path):
    try:
        with open(path) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _save_drops(path, data):
    try:
        if data:
            with open(path, "w") as f:
                json.dump(data, f)
        elif os.path.exists(path):
            os.remove(path)
    except OSError as e:
        log(f"could not save quiet-hours state: {e}")


def record_quiet_drop(path, device, state, address, title):
    cat = _drop_category(state, address, title)
    data = _load_drops(path)
    entry = data.get(device_key(device))
    entry = entry if isinstance(entry, dict) else {}
    entry[cat] = int(entry.get(cat, 0)) + 1
    data[device_key(device)] = entry
    _save_drops(path, data)


def quiet_summary(counts, host, prefs=None):
    """"While you were away: 3 finished, 1 error on pop-os, low battery", or None when nothing counts.
    Kinds the device has since switched off are left out."""
    parts = []
    n = counts.get("finished", 0)
    if n and (prefs is None or _kind_on(prefs, "done")):
        parts.append(f"{n} finished")
    n = counts.get("error", 0)
    if n and (prefs is None or _kind_on(prefs, "error")):
        parts.append(f"{n} error" + ("" if n == 1 else "s"))
    text = ", ".join(parts)
    if parts:
        text += f" on {host}"
    extra = [label for key, label in (("battery", "low battery"), ("disk", "low disk"))
             if counts.get(key, 0) and (prefs is None or _kind_on(prefs, "error"))]
    if extra:
        if text:
            text += ", " + ", ".join(extra)
        else:
            text = ", ".join(extra) + f" on {host}"
    return f"While you were away: {text}" if text else None


def flush_quiet_drops(cfg, host, jwt_cache, path, now=None, sender=None):
    """Sends the summary to each device whose quiet hours have ended, then forgets its counts.
    A device that is gone, or whose counts are all for kinds now off, is just cleared. Returns the
    (device key, summary) pairs sent."""
    data = _load_drops(path)
    if not data:
        return []
    devices = {device_key(d): d for d in cfg.get("devices") or [] if isinstance(d, dict)}
    sent, changed = [], False
    for key in list(data):
        device = devices.get(key)
        if device is not None and _in_quiet(device.get("prefs"), now):
            continue  # still inside the window: keep counting
        changed = True
        counts = data.pop(key)
        text = quiet_summary(counts if isinstance(counts, dict) else {}, host,
                             device.get("prefs") if device else None)
        if device is None or not text:
            continue
        log(f"quiet hours over for {device.get('name', 'device')}: {text}")
        one = dict(cfg, devices=[device])
        (sender or send_alert)(one, text, "Quiet hours ended", "summary", host, jwt_cache)
        sent.append((key, text))
    if changed:
        _save_drops(path, data)
    return sent


# Keep the machine awake while agents work (v17): a child process holds an idle-sleep inhibitor
# while any terminal is "working", and is released 2 minutes after the last one stops. Windows: skipped.
KEEP_AWAKE_GRACE = 120


def keep_awake_command(pid, platform=None):
    platform = platform or sys.platform
    if platform == "darwin":
        return ["caffeinate", "-i", "-w", str(pid)]
    if platform.startswith("linux"):
        return ["systemd-inhibit", "--what=idle:sleep", "--why=Bergr agents working", "sleep", "infinity"]
    return None


def keep_awake_wanted(cfg):
    """The keepAwake pref (default true): off only when every registered phone turned it off."""
    devices = [d for d in (cfg or {}).get("devices") or [] if isinstance(d, dict)]
    prefs = [d.get("prefs") for d in devices]
    return not devices or any(not (isinstance(p, dict) and p.get("keepAwake") is False) for p in prefs)


def working_count(terms):
    return sum(1 for t in terms.values()
               if isinstance(t.get("status"), dict) and t["status"].get("state") == "working")


class KeepAwake:
    def __init__(self, spawn=None, clock=time.time, pid=None, platform=None):
        self.spawn = spawn or (lambda cmd: subprocess.Popen(cmd, stdin=subprocess.DEVNULL,
                                                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                                            **NO_WINDOW))
        self.clock = clock
        self.pid = os.getpid() if pid is None else pid
        self.platform = platform
        self.child = None
        self.idle_since = None

    def held(self):
        return self.child is not None and self.child.poll() is None

    def update(self, working, enabled=True):
        now = self.clock()
        if not enabled:
            self.release()
        elif working:
            self.idle_since = None
            if not self.held():
                self.child = None
                cmd = keep_awake_command(self.pid, self.platform)
                if cmd:
                    try:
                        self.child = self.spawn(cmd)
                    except OSError as e:
                        log(f"cannot keep the machine awake: {e}")
        elif self.held():
            if self.idle_since is None:
                self.idle_since = now
            elif now - self.idle_since >= KEEP_AWAKE_GRACE:
                self.release()
        else:
            self.child = None

    def release(self):
        child, self.child, self.idle_since = self.child, None, None
        if child is not None and child.poll() is None:
            try:
                child.kill()
                child.wait(timeout=5)
            except Exception:
                pass


# Watchdog (v23): the two silent failures. A terminal "working" whose screen has not changed for
# `stuckMinutes` (pref, default 20, 0 off) gets one "no output" alert (kind error, so prefs, quiet
# hours and mute apply); a terminal still blocked on the same turn `renudgeMinutes` (default 30,
# 0 off) after its alert gets one "Still waiting" reminder with the same answer buttons. The screen
# is read with `hc read --json` at most once a minute per working terminal, only while one works.
STUCK_DEFAULT = 20
RENUDGE_DEFAULT = 30
WATCH_SAMPLE = 60
WATCH_TICK = 15


def pref_minutes(cfg, key, default):
    """The smallest positive `key` pref among the registered phones (a phone without it means the
    default); 0 when every phone turned it off or none is registered."""
    values = []
    for d in (cfg or {}).get("devices") or []:
        if not isinstance(d, dict):
            continue
        prefs = d.get("prefs")
        v = prefs.get(key) if isinstance(prefs, dict) else None
        if not isinstance(v, int) or isinstance(v, bool) or v < 0:
            v = default
        values.append(v)
    positive = [v for v in values if v > 0]
    return min(positive) if positive else 0


def screen_digest(address, runner=_hc_run):
    """A cheap hash of the terminal's screen text, or None when it can't be read."""
    try:
        screen = _hc_json(["read", address], runner)
    except Exception:
        return None
    if not screen or not isinstance(screen.get("text"), str):
        return None
    return hashlib.sha1(screen["text"].encode("utf-8", "replace")).hexdigest()


def stuck_alert(term, minutes, machine=""):
    status = term.get("status") if isinstance(term.get("status"), dict) else {}
    labels = term.get("labels") if isinstance(term.get("labels"), dict) else {}
    app = APP_NAMES.get(_text(status.get("app")), _text(status.get("app")) or "Agent")
    where = f" on {machine}" if machine else ""
    body = _text(labels.get("where")) or _text(term.get("title"))
    return {"address": term.get("address"), "turn": term.get("turn"), "state": "error",
            "title": f"{app}{where} has shown no output for {minutes} min", "body": body}


class Watchdog:
    def __init__(self, reader=screen_digest, clock=time.time, host=""):
        self.reader = reader
        self.clock = clock
        self.host = host
        self.lock = threading.Lock()
        self.screens = {}  # address -> {"hash", "changed", "sampled", "alerted"}
        self.blocked = {}  # address -> {"turn", "at", "alert", "q", "nudged"}

    def note_alert(self, alert, q=None, now=None):
        """Remembers a blocked alert that was sent, for the reminder."""
        if alert.get("state") != "blocked":
            return
        with self.lock:
            self.blocked[alert["address"]] = {"turn": alert.get("turn"), "at": self.clock() if now is None else now,
                                              "alert": alert, "q": q, "nudged": False}

    def stuck(self, terms, minutes, now=None):
        now = self.clock() if now is None else now
        working = {a: t for a, t in terms.items() if isinstance(t, dict) and isinstance(t.get("status"), dict)
                   and t["status"].get("state") == "working" and t.get("notify") is not False}
        alerts = []
        with self.lock:
            # Leaving working (or the pref going off) re-arms.
            self.screens = {a: v for a, v in self.screens.items() if a in working} if minutes > 0 else {}
            if minutes <= 0:
                return alerts
            for address, t in working.items():
                rec = self.screens.get(address)
                if rec and now - rec["sampled"] < WATCH_SAMPLE:
                    continue
                digest = self.reader(address)
                if digest is None:
                    continue
                if rec is None or rec["hash"] != digest:
                    self.screens[address] = {"hash": digest, "changed": now, "sampled": now, "alerted": False}
                    continue
                rec["sampled"] = now
                if not rec["alerted"] and now - rec["changed"] >= minutes * 60:
                    rec["alerted"] = True
                    alerts.append(stuck_alert(t, minutes, self.host))
        return alerts

    def renudge(self, terms, minutes, now=None):
        now = self.clock() if now is None else now
        alerts = []
        with self.lock:
            for address, rec in list(self.blocked.items()):
                t = terms.get(address)
                status = t.get("status") if isinstance(t, dict) and isinstance(t.get("status"), dict) else {}
                if status.get("state") != "blocked" or t.get("turn") != rec["turn"]:
                    del self.blocked[address]
                    continue
                if minutes <= 0 or rec["nudged"] or now - rec["at"] < minutes * 60:
                    continue
                rec["nudged"] = True
                orig, q = rec["alert"], rec["q"]
                question = _text(q.get("title") if q else None) or _text(status.get("msg")) or _text(orig.get("body"))
                alerts.append({"address": address, "turn": orig["turn"], "state": "blocked",
                               "title": ("Still waiting: " + question)[:120], "body": _text(orig.get("title")), "q": q})
        return alerts

    def tick(self, cfg, terms, now=None):
        """Alerts due now (stuck ones first); a reminder carries its q."""
        return (self.stuck(terms, pref_minutes(cfg, "stuckMinutes", STUCK_DEFAULT), now)
                + self.renudge(terms, pref_minutes(cfg, "renudgeMinutes", RENUDGE_DEFAULT), now))


def send_with_answer(cfg, a, q, host, jwt_cache, poster, answers_path):
    """Sends alert `a`; answer buttons answer through the relay, so a key question gets a fresh answerID
    the helper remembers (this address, turn and question) for 10 minutes."""
    answer_id = None
    if q and q.get("keys") is True:
        try:
            answer_id = record_pending_answer(answers_path, a["address"], a["turn"], q["title"])
        except Exception as e:
            log(f"could not save the answer id: {e}")
    send_alert(cfg, a["title"], a["body"], a["address"], host, jwt_cache,
               on_reply=poster.learn if poster else None, state=a["state"], q=q, a=answer_id)


# Scheduled sends (v24): the app writes {id, address, at, text} entries to scheduled.json beside
# push.json (e.g. "continue" when a plan limit resets). When one is due the helper types it into the
# terminal with `hc send` and alerts that it did, so it happens with the phone asleep.
def scheduled_path(config_path=None):
    return os.path.join(os.path.dirname(config_path or default_config_path()), "scheduled.json")


def run_scheduled(path, host, runner=_hc_run, now=None):
    """Sends the due entries, drops them (and any older than a day) and returns their alerts."""
    now = time.time() if now is None else now
    try:
        with open(path, encoding="utf-8") as f:
            items = json.load(f)
    except (OSError, ValueError):
        return []
    if not isinstance(items, list):
        return []
    keep, alerts = [], []
    for item in items:
        if not isinstance(item, dict) or not isinstance(item.get("at"), (int, float)):
            continue
        address, text = _text(item.get("address")), _text(item.get("text"))
        if not address or not text or now - item["at"] > 86400:
            continue
        if item["at"] > now:
            keep.append(item)
            continue
        where = f" on {host}" if host else ""
        try:
            runner(["hc", "send", address, text])
            log(f"scheduled send to {address}")
            alerts.append({"address": address, "turn": None, "state": "done",
                           "title": f"Sent \u201c{text[:60]}\u201d{where}", "body": "Your scheduled message went out."})
        except Exception as e:
            log(f"scheduled send to {address} failed: {e}")
            alerts.append({"address": address, "turn": None, "state": "error",
                           "title": f"Couldn't send your scheduled message{where}", "body": str(e)[:120]})
    if len(keep) != len(items):
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(keep, f)
        os.replace(tmp, path)
    return alerts


class WatchdogThread(threading.Thread):
    def __init__(self, watcher, shared, watchdog, host, jwt_cache, poster, answers_path):
        super().__init__(daemon=True)
        self.args = (watcher, shared, watchdog, host, jwt_cache, poster, answers_path)

    def run(self):
        watcher, shared, watchdog, host, jwt_cache, poster, answers_path = self.args
        while True:
            time.sleep(WATCH_TICK)
            try:
                cfg = watcher.get()
                if cfg is None:
                    continue
                for a in watchdog.tick(cfg, shared.get("terms") or {}):
                    log(f"watchdog alert for {a['address']}: {a['title']}")
                    send_with_answer(cfg, a, a.get("q"), host, jwt_cache, poster, answers_path)
                for a in run_scheduled(scheduled_path(), host):
                    send_with_answer(cfg, a, None, host, jwt_cache, poster, answers_path)
            except Exception as e:
                log(f"watchdog failed: {e}")


# Turn baselines (v18): when a terminal starts working, its cwd's tree is snapshotted with
# `git stash create` (a commit of the tracked changes; the worktree, index and branches are not
# touched) and kept under refs/bergr/turns/<name>, latest only. The list of untracked files at that
# moment goes into a blob under refs/bergr/turns-untracked/<name> (the app reads both over git) and
# into turns/<name>.json beside push.json. The finished alert says what the turn changed.
GIT_TIMEOUT = 1.0
TURN_REF = "refs/bergr/turns/"
TURN_UNTRACKED_REF = "refs/bergr/turns-untracked/"


def ref_name(address):
    """The address as a ref component; the app (ChangesModel.turnRefName) does the same."""
    name = re.sub(r"[^A-Za-z0-9_-]", "_", address)
    return name or "_"


def _git(cwd, args, timeout=GIT_TIMEOUT, stdin=None):
    """Stdout of `git -C cwd args`, or None on any failure or timeout."""
    try:
        out = subprocess.run(["git", "-C", cwd] + args, input=stdin, capture_output=True, text=True,
                             timeout=timeout, env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"), **NO_WINDOW)
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    return out.stdout if out.returncode == 0 else None


def untracked_files(cwd, timeout=GIT_TIMEOUT):
    out = _git(cwd, ["ls-files", "--others", "--exclude-standard"], timeout)
    return None if out is None else [l for l in out.split("\n") if l]


def turns_dir(config_path=None):
    return os.path.join(os.path.dirname(config_path or default_config_path()), "turns")


def record_turn_baseline(address, cwd, config_path=None, timeout=GIT_TIMEOUT):
    """Snapshots `cwd` as the baseline for `address`'s new turn. Returns the sha, or None (not a
    repo, no commits, git failed or timed out)."""
    if not cwd or not os.path.isdir(cwd):
        return None
    head = _git(cwd, ["rev-parse", "--verify", "-q", "HEAD"], timeout)
    if head is None:
        return None
    snap = _git(cwd, ["stash", "create"], timeout)
    if snap is None:
        return None
    sha = snap.strip() or head.strip()  # empty output: a clean tree
    name = ref_name(address)
    if _git(cwd, ["update-ref", TURN_REF + name, sha], timeout) is None:
        return None
    untracked = untracked_files(cwd, timeout) or []
    blob = _git(cwd, ["hash-object", "-w", "--stdin"], timeout, stdin="\n".join(untracked) + "\n" if untracked else "")
    if blob:
        _git(cwd, ["update-ref", TURN_UNTRACKED_REF + name, blob.strip()], timeout)
    try:
        d = turns_dir(config_path)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, name + ".json"), "w") as f:
            json.dump({"sha": sha, "cwd": cwd, "untracked": untracked}, f)
    except OSError as e:
        log(f"could not save turn baseline: {e}")
    return sha


def turn_stat(address, cwd, config_path=None, timeout=GIT_TIMEOUT):
    """'4 files, +120 \u221218' for what changed since the turn's baseline, or None (no repo, no
    baseline, nothing changed, timeout)."""
    name = ref_name(address)
    try:
        with open(os.path.join(turns_dir(config_path), name + ".json")) as f:
            saved = json.load(f)
        before = set(saved.get("untracked") or [])
        # The baseline's own folder: an agent's work folder can differ from the terminal's.
        if isinstance(saved.get("cwd"), str) and os.path.isdir(saved["cwd"]):
            cwd = saved["cwd"]
    except (OSError, ValueError, AttributeError):
        before = set()
    if not cwd or not os.path.isdir(cwd):
        return None
    start = time.monotonic()
    short = _git(cwd, ["diff", "--shortstat", TURN_REF + name], timeout)
    if short is None:
        return None
    left = max(timeout - (time.monotonic() - start), 0.2)
    now = untracked_files(cwd, left)
    new = len(set(now or []) - before)
    m = re.search(r"(\d+) files? changed", short)
    files = (int(m.group(1)) if m else 0) + new
    plus = re.search(r"(\d+) insertions?", short)
    minus = re.search(r"(\d+) deletions?", short)
    if not files:
        return None
    return f"{files} file{'s' if files != 1 else ''}, +{plus.group(1) if plus else 0} \u2212{minus.group(1) if minus else 0}"


def _hc_terminal(address, timeout=2.0):
    """herdr-core's record of one terminal (`hc get`), or None."""
    try:
        out = subprocess.run(["hc", "get", address], capture_output=True, text=True, timeout=timeout, **NO_WINDOW)
        return json.loads(out.stdout) if out.returncode == 0 else None
    except (OSError, subprocess.SubprocessError, ValueError):
        return None


def claude_tail(pid, home=None):
    """The last ~256 KB of a Claude Code process's conversation, as lines; None when not found."""
    base = os.path.join(home or os.path.expanduser("~"), ".claude")
    try:
        with open(os.path.join(base, "sessions", f"{int(pid)}.json")) as f:
            sid = json.JSONDecoder().raw_decode(f.read().strip())[0].get("sessionId")
    except (OSError, ValueError, TypeError, AttributeError):
        return None
    if not isinstance(sid, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", sid):
        return None
    files = glob.glob(os.path.join(base, "projects", "*", sid + ".jsonl"))
    if not files:
        return None
    try:
        with open(files[0], "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(f.tell() - 262144, 0))
            lines = f.read().decode("utf-8", "replace").split("\n")
    except OSError:
        return None
    return lines


BLOCKED = "Permission for this action was denied by the Claude Code auto mode classifier."


def claude_blocked(pid, home=None):
    """The command of the last call Claude's auto mode blocked in its latest turn and that hasn't
    run since (approved in /permissions it runs again with the same input); None otherwise."""
    calls, blocked = {}, None
    for line in claude_tail(pid, home) or []:
        if '"tool_use"' not in line and '"tool_result"' not in line and '"user"' not in line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        content = (d.get("message") or {}).get("content") if isinstance(d, dict) else None
        if d.get("type") == "user" and isinstance(content, str) and not content.startswith("<"):
            blocked = None  # a new turn
        for b in content if isinstance(content, list) else []:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "tool_use":
                key = (b.get("name") or "") + json.dumps(b.get("input"), sort_keys=True)
                if blocked and blocked[0] == key:
                    blocked = None
                calls[b.get("id")] = (key, b.get("input") if isinstance(b.get("input"), dict) else {})
            elif b.get("type") == "tool_result":
                text = b.get("content")
                if isinstance(text, list):
                    text = " ".join(x.get("text", "") for x in text if isinstance(x, dict))
                if isinstance(text, str) and text.startswith(BLOCKED) and b.get("tool_use_id") in calls:
                    key, inp = calls[b["tool_use_id"]]
                    blocked = (key, str(inp.get("command") or inp.get("description") or inp.get("file_path") or "a tool call"))
    return blocked[1] if blocked else None


def claude_folder(pid, home=None):
    """The folder a Claude Code process is working in now: its conversation records the current
    folder on every line (a `cd` in its shell moves it), while the process and the terminal stay
    where they started (often the home folder). None when it can't be told."""
    lines = claude_tail(pid, home)
    if lines is None:
        return None
    for line in reversed(lines):
        if '"cwd"' not in line:
            continue
        try:
            cwd = json.loads(line).get("cwd")
        except (ValueError, AttributeError):
            continue
        if isinstance(cwd, str) and os.path.isdir(cwd):
            return cwd
    return None


def blocked_command(address):
    """claude_blocked for the Claude Code running in this terminal, else None."""
    term = _hc_terminal(address) or {}
    fg = term.get("foreground") if isinstance(term.get("foreground"), dict) else {}
    program = " ".join(str(x) for x in (fg.get("argv") or [])[:1]).lower()
    status = term.get("status") if isinstance(term.get("status"), dict) else {}
    named = " ".join(str(x or "") for x in (term.get("agent"), status.get("app"), fg.get("name"))).lower()
    if not fg.get("pid") or ("claude" not in program and "claude" not in named):
        return None
    try:
        return claude_blocked(fg["pid"])
    except Exception:
        return None


def turn_folder(address, fallback):
    """Where a turn's changes happen: a Claude agent's current folder, else the program's or
    terminal's folder."""
    term = _hc_terminal(address) or {}
    fg = term.get("foreground") if isinstance(term.get("foreground"), dict) else {}
    pid = fg.get("pid")
    program = " ".join(str(x) for x in (fg.get("argv") or [])[:1]).lower()
    status = term.get("status") if isinstance(term.get("status"), dict) else {}
    named = " ".join(str(x or "") for x in (term.get("agent"), status.get("app"), fg.get("name"))).lower()
    if pid and ("claude" in program or "claude" in named):
        found = claude_folder(pid)
        if found:
            return found
    return _text(fg.get("cwd")) or _text(term.get("cwd")) or fallback


def baseline_turn(address, cwd):
    record_turn_baseline(address, turn_folder(address, cwd))


def started_working(prev_state, state):
    """Addresses that went from another known state to working between two states."""
    out = []
    for address, (st, _) in state["last"].items():
        before = prev_state["last"].get(address)
        if st == "working" and before is not None and before[0] != "working":
            out.append(address)
    return out


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
        input=unsigned.encode("ascii"), capture_output=True, timeout=30, **NO_WINDOW)
    if out.returncode != 0:
        raise RuntimeError("openssl sign failed: " + out.stderr.decode("utf-8", errors="replace").strip())
    return unsigned + "." + b64url(der_to_raw(out.stdout))


def format_alert(term, state, machine="", stat=None):
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
    suffix = f" · {stat}" if stat and state == "done" else ""
    if len(body) > BODY_MAX - len(suffix):
        body = body[:BODY_MAX - len(suffix) - 1] + "…"
    return title, body + suffix


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


def alert_answers(cfg, alert):
    """The alert's answer buttons, unless its question matches an "always ask" pattern."""
    q = alert.get("q")
    if q and ask_match(_text(q.get("title")) + "\n" + _text(alert.get("title")) + "\n" + _text(alert.get("body")),
                       device_ask_patterns(cfg)):
        return None
    return q


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


# Terminals already logged for a non-integer turn (logged once each).
_BAD_TURN_LOGGED = set()


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
            if address not in _BAD_TURN_LOGGED:
                _BAD_TURN_LOGGED.add(address)
                log(f"skipping {address}: turn is not an integer ({turn!r})")
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
        stat = turn_stat(address, term.get("cwd")) if state == "done" else None
        title, body = format_alert(term, state, machine, stat)
        # Finished with a call auto mode blocked: say so, so it can be allowed from the chat.
        command = blocked_command(address) if state == "done" else None
        if command:
            title = "Claude: auto mode blocked a command" + (f" on {machine}" if machine else "")
            body = (command if len(command) <= BODY_MAX - 25 else command[:BODY_MAX - 26] + "…") + " · Tap to allow and retry"
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
    # The "I'm alive" beat to the relay, even when every count is zero: the relay tells the phone when
    # a machine that was working goes silent (see heartbeat).
    HEARTBEAT = 300
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

    def heartbeat(self, device, terms, host, now):
        """Every HEARTBEAT seconds (5 min), posts machine id, name, counts and helper version to the
        relay's /v1/heartbeat, idle or not. A failed beat is tried again after RETRY_DELAY. Returns
        True when a beat was sent."""
        d = self._device(device["secret"])
        if now < d.get("hb_at", 0) + self.HEARTBEAT or now < d.get("hb_retry", 0):
            return False
        host_id = device.get("host_id") or host
        summary = activity_summary(terms, rows=False, host_id=host_id, machine=host,
                                   hide_after=d.get("hide_after", 86400), now=now)
        body = {"machine": host_id[:100], "name": host[:100], "needsYou": summary["needsYou"],
                "working": summary["working"], "done": summary["done"], "version": VERSION}
        req = urllib.request.Request(device["relay"].rstrip("/") + "/v1/heartbeat",
                                     data=json.dumps(body).encode("utf-8"), method="POST", headers={
            "authorization": "Bearer " + device["secret"], "content-type": "application/json",
            "user-agent": f"bergr-notify/{VERSION}"})
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                if resp.status != 200:
                    raise RuntimeError(f"HTTP {resp.status}")
                resp.read()
        except Exception as e:
            log(f"heartbeat failed: {e}")
            d["hb_retry"] = now + self.RETRY_DELAY
            return False
        d["hb_at"] = now
        d["hb_retry"] = 0
        return True

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
    res = subprocess.run(cmd, input=payload, capture_output=True, timeout=30, **NO_WINDOW)
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


def encrypt_alert(key_bytes, title, body, nonce=None, q=None, a=None):
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
    if a:
        content["a"] = a  # the answerID: the buttons answer through the relay, without opening the app
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


def relay_request(device, title, body, address, host, state=None, q=None, a=None):
    """(url, headers, body bytes) for a push through the relay."""
    url = device["relay"].rstrip("/") + "/v1/push"
    payload = {"title": title[:100], "body": body[:400], "address": address[:64], "host": host[:100]}
    if device.get("key"):
        # Never send the text in the clear when the phone has a key; fall back to a generic alert.
        try:
            key = base64.b64decode(device["key"], validate=True)
            payload = {"e": encrypt_alert(key, title[:100], body[:400], q=q, a=a if q else None), "address": address[:64], "host": host[:100]}
        except Exception as e:
            log(f"alert encryption failed ({type(e).__name__}); sending without text")
            payload = {"title": "Bergr", "body": "An agent needs you", "address": address[:64], "host": host[:100]}
    if state in URGENCY:
        payload["state"] = state  # in the clear: the relay needs it for the interruption level
    # Cloudflare turns away Python's default User-Agent (error 1010), so name ourselves.
    headers = {"authorization": "Bearer " + device["secret"], "content-type": "application/json",
               "user-agent": f"bergr-notify/{VERSION}"}
    return url, headers, json.dumps(payload).encode("utf-8")


def send_relay(device, title, body, address, host, state=None, q=None, a=None):
    """Sends one push through the device's relay. Returns the relay's reply (see ActivityPoster.learn)."""
    url, headers, data = relay_request(device, title, body, address, host, state, q, a)
    req = urllib.request.Request(url, data=data, method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return parse_reply(resp.read())
    except urllib.error.HTTPError as e:
        if e.code == 410:
            raise RuntimeError("the phone is no longer registered (turn push alerts off and on again in Bergr)")
        raise RuntimeError(f"relay HTTP {e.code}: {e.read()[:200].decode('utf-8', 'replace')}")


def send_alert(cfg, title, body, address, host, jwt_cache, on_reply=None, state=None, q=None, a=None):
    """Sends one alert to every device (through its relay, or straight to APNs with a key on this
    machine) or to the ntfy topic. Returns the successful sends. on_reply(secret, reply) gets each
    relay's reply."""
    mode = cfg.get("mode", "apns")
    sent = 0
    devices = [d for d in cfg.get("devices") or [] if isinstance(d, dict)]
    # Devices registered through a relay carry its address and a secret; the relay holds the key.
    # A device with "alerts": false wants only the Live Activity kept current, not notifications.
    def wanted(d):
        verdict = prefs_verdict(d.get("prefs"), state, address)
        if verdict == "quiet" and _drop_path and d.get("alerts", True) is not False:
            record_quiet_drop(_drop_path, d, state, address, title)
        return verdict == "send"

    for device in [d for d in devices if d.get("relay") and d.get("secret") and d.get("alerts", True) is not False
                   and wanted(d)]:
        try:
            # The app's own id for this machine when it gave one, so a tap opens the right one.
            reply = send_relay(device, title, body, address, device.get("host_id") or host, state, q, a)
            sent += 1
            if on_reply and isinstance(reply, dict):
                on_reply(device["secret"], reply)
        except Exception as e:
            log(f"push to {device.get('name', 'device')} through the relay failed: {e}")
    cfg = dict(cfg, devices=[d for d in devices if not (d.get("relay") and d.get("secret"))])
    if mode == "apns":
        now = int(time.time())
        for device in cfg.get("devices") or []:
            if isinstance(device, dict) and not wanted(device):
                continue
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
    health_at = 0.0
    health_path = health_state_path()
    global _drop_path
    _drop_path = quiet_drops_path()
    quiet_at = 0.0
    awake = KeepAwake()
    atexit.register(awake.release)
    answers_path = remote_answers_path()
    AnswerPoller(watcher, answers_path, host, jwt_cache).start()
    watchdog = Watchdog(host=host)
    shared = {"terms": {}}
    WatchdogThread(watcher, shared, watchdog, host, jwt_cache, poster, answers_path).start()
    while True:
        try:
            proc = subprocess.Popen(["hc", "events", "--json"], stdout=subprocess.PIPE,
                                    text=True, encoding="utf-8", errors="replace", **NO_WINDOW)
        except OSError as e:
            log(f"cannot run hc events: {e}")
        else:
            try:
                for raw in proc.stdout:
                    line = raw.strip()
                    if not line:
                        continue
                    try:
                        before = state
                        state, alerts = alerts_for(state, line, host)
                        shared["terms"] = state.get("terms", {})
                        for address in started_working(before, state):
                            cwd = (state.get("terms", {}).get(address) or {}).get("cwd")
                            threading.Thread(target=baseline_turn, args=(address, cwd), daemon=True).start()
                    except Exception as e:
                        log(f"could not process event line: {e}")
                        continue
                    cfg = watcher.get()
                    if cfg is None:
                        continue
                    if time.time() - health_at >= HEALTH_INTERVAL:
                        health_at = time.time()
                        try:
                            check_health(cfg, host, jwt_cache, health_path, disk_reading(), battery_reading())
                        except Exception as e:
                            log(f"health check failed: {e}")
                    awake.update(working_count(state.get("terms", {})), keep_awake_wanted(cfg))
                    if time.time() - quiet_at >= QUIET_INTERVAL:
                        quiet_at = time.time()
                        try:
                            flush_quiet_drops(cfg, host, jwt_cache, _drop_path)
                        except Exception as e:
                            log(f"quiet-hours summary failed: {e}")
                    # Every line (a change, or the 15 s heartbeat): the Live Activity may be due.
                    for device in cfg.get("devices") or []:
                        if isinstance(device, dict) and device.get("relay") and device.get("secret"):
                            poster.post(device, state.get("terms", {}), host, time.time())
                            poster.heartbeat(device, state.get("terms", {}), host, time.time())
                    if not alerts:
                        continue
                    for a in alerts:
                        done = auto_answer(cfg, a["address"]) if a["state"] == "blocked" else None
                        if done:
                            command, rule, term = done
                            log(f"auto-approved {command!r} for {a['address']}")
                            record_auto_answer(auto_log_path(), command, rule, term)
                            # Quiet (passive, like a finished agent): nothing to do.
                            send_alert(cfg, f"Auto-approved `{command}` on {host}", a["body"], a["address"], host,
                                       jwt_cache, on_reply=poster.learn, state="done")
                            continue
                        log(f"alert for {a['address']}: {a['title']}")
                        q = alert_answers(cfg, a)
                        watchdog.note_alert(a, q)
                        send_with_answer(cfg, a, q, host, jwt_cache, poster, answers_path)
            finally:
                if proc.poll() is None:
                    proc.kill()
                code = proc.wait()
            log(f"hc events exited with {code}")
        time.sleep(RETRY_DELAY)


def main(argv):
    windows_setup()
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
