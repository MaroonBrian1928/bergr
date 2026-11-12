# Lists the recent conversations of Claude Code or Codex for one folder, newest first, as one JSON
# line: [{"id","title","mtime","count"}]. Run by Bergr's New Session sheet through the same stdin
# bootstrap as the chat helper; D["argv"] = [name, "claude"|"codex", <folder>]. Kept small: it must
# also fit through Windows' SSH.
import glob, json, os, re, sys

LIMIT = 20


def _norm(p):
    p = (p or "").replace("\\", "/").rstrip("/")
    return p.lower() if re.match(r"^[A-Za-z]:", p) else p


def _text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        for part in content:
            if isinstance(part, dict) and part.get("type") in ("text", "input_text") and isinstance(part.get("text"), str):
                return part["text"]
    return ""


def _title(text):
    text = " ".join((text or "").split())
    return text if len(text) <= 80 else text[:79].rstrip() + "…"


def _useful(text):
    t = text.strip()
    # Hook and command wrappers, Codex's environment preamble: not what the person wrote.
    return bool(t) and not t.startswith(("<", "Caveat:", "# AGENTS.md"))


def _lines(path):
    with open(path, "rb") as f:
        for raw in f:
            yield raw


def _claude(home, cwd):
    key = re.sub(r"[^A-Za-z0-9]", "-", cwd)
    base = os.path.join(home, ".claude", "projects")
    folder = os.path.join(base, key)
    if not os.path.isdir(folder):
        folder = None
        try:
            for name in os.listdir(base):
                if name.lower() == key.lower():
                    folder = os.path.join(base, name)
        except OSError:
            pass
    if not folder:
        return []
    files = []
    for p in glob.glob(os.path.join(folder, "*.jsonl")):
        try:
            files.append((os.path.getmtime(p), p))
        except OSError:
            pass
    files.sort(reverse=True)
    out = []
    for mtime, p in files:
        title, count = "", 0
        try:
            for raw in _lines(p):
                if (b'"type":"user"' in raw or b'"type":"assistant"' in raw) and b'"isMeta":true' not in raw:
                    count += 1
                    if not title and b'"type":"user"' in raw:
                        try:
                            row = json.loads(raw)
                        except ValueError:
                            continue
                        if row.get("type") != "user" or row.get("isMeta") or row.get("isSidechain"):
                            continue
                        t = _text((row.get("message") or {}).get("content"))
                        if _useful(t):
                            title = _title(t)
        except OSError:
            continue
        if count:
            out.append({"id": os.path.basename(p)[:-6], "title": title, "mtime": mtime, "count": count})
            if len(out) == LIMIT:
                break
    return out


def _codex(home, cwd):
    want = _norm(cwd)
    files = []
    for p in glob.glob(os.path.join(home, ".codex", "sessions", "**", "rollout-*.jsonl"), recursive=True):
        try:
            files.append((os.path.getmtime(p), p))
        except OSError:
            pass
    files.sort(reverse=True)
    out = []
    for mtime, p in files[:400]:
        sid, title, count = None, "", 0
        try:
            for i, raw in enumerate(_lines(p)):
                if i == 0:
                    meta = json.loads(raw).get("payload") or {}
                    if _norm(meta.get("cwd")) != want or not meta.get("id"):
                        break
                    sid = meta["id"]
                    continue
                if b'"user_message"' in raw or b'"agent_message"' in raw:
                    count += 1
                    if not title and b'"user_message"' in raw:
                        try:
                            pl = json.loads(raw).get("payload") or {}
                        except ValueError:
                            continue
                        if pl.get("type") == "user_message" and _useful(pl.get("message") or ""):
                            title = _title(pl["message"])
        except (OSError, ValueError, AttributeError):
            continue
        if sid and count:
            out.append({"id": sid, "title": title, "mtime": mtime, "count": count})
            if len(out) == LIMIT:
                break
    return out


def recent(agent, cwd, home):
    return _claude(home, cwd) if agent == "claude" else _codex(home, cwd) if agent == "codex" else []


if "D" in globals():
    try:
        sys.stdout.reconfigure(encoding="utf-8", newline="\n")
        _r = recent(D["argv"][1], D["argv"][2], os.path.expanduser("~"))
    except Exception:
        _r = []
    sys.stdout.write(json.dumps(_r, ensure_ascii=True) + "\n")
