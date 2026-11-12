# One-shot transcript search for Bergr. Stage 1 execs the first line of stdin, which defines D
# (JSON: q = the query) and runs this file inline. Searches the user and assistant text of Claude
# (~/.claude/projects/**/*.jsonl) and Codex (~/.codex/sessions/**/rollout-*.jsonl) conversations,
# newest first, and prints one JSON line: {"hits":[...],"truncated":bool}.
# Bounded: 5 s, 30 hits (one per conversation), 120 KB of output. Works on Windows (no shell, no
# POSIX-only calls).
import json, os, sys, time

MAX_HITS = 30
BUDGET = 5.0
MAX_OUT = 120000
SNIPPET = 160


def _text_of(content, kinds):
    if isinstance(content, str):
        return content
    out = []
    if isinstance(content, list):
        for b in content:
            if isinstance(b, dict) and b.get("type") in kinds and isinstance(b.get("text"), str):
                out.append(b["text"])
    return "\n".join(out)


def _snippet(text, idx, n):
    start = max(0, idx - SNIPPET // 3)
    end = min(len(text), idx + n + SNIPPET)
    s = " ".join(text[start:end].split())
    return ("…" if start > 0 else "") + s + ("…" if end < len(text) else "")


def _messages(path, agent, needle):
    """Yields (role, text, meta) for user/assistant text containing the query."""
    meta = {}
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            has = needle in line.lower()
            # Cheap prefilter: parse only lines that can match, until the metadata is known.
            if not has and meta.get("cwd") and meta.get("session") and meta.get("title"):
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if not isinstance(o, dict):
                continue
            role = text = None
            if agent == "claude":
                if o.get("isSidechain") or o.get("isMeta"):
                    continue
                if o.get("cwd"):
                    meta.setdefault("cwd", o.get("cwd"))
                if o.get("sessionId"):
                    meta.setdefault("session", o.get("sessionId"))
                m = o.get("message")
                t = o.get("type")
                if isinstance(m, dict) and t in ("user", "assistant"):
                    role = t
                    text = _text_of(m.get("content"), ("text",))
            else:
                p = o.get("payload")
                if not isinstance(p, dict):
                    continue
                if o.get("type") == "session_meta":
                    if p.get("cwd"):
                        meta.setdefault("cwd", p.get("cwd"))
                    if p.get("id"):
                        meta.setdefault("session", p.get("id"))
                elif o.get("type") == "response_item" and p.get("type") == "message" \
                        and p.get("role") in ("user", "assistant"):
                    role = p["role"]
                    text = _text_of(p.get("content"), ("input_text", "output_text", "text"))
            if not role or not text:
                continue
            # Injected context is not conversation.
            if role == "user" and text.lstrip().startswith("<"):
                continue
            if "title" not in meta and role == "user":
                meta["title"] = " ".join(text.split())[:80]
            if has:
                yield role, text, meta


def _files(root, prefix):
    found = []
    for d, _, names in os.walk(root):
        for n in names:
            if n.endswith(".jsonl") and n.startswith(prefix):
                p = os.path.join(d, n)
                try:
                    found.append((os.stat(p).st_mtime, p))
                except OSError:
                    pass
    return found


def search(query, home, budget=BUDGET, max_hits=MAX_HITS):
    needle = query.strip().lower()
    deadline = time.time() + budget
    out = {"hits": [], "truncated": False}
    if not needle:
        return out
    files = []
    for agent, parts, prefix in (("claude", (".claude", "projects"), ""),
                                 ("codex", (".codex", "sessions"), "rollout-")):
        files += [(m, p, agent) for m, p in _files(os.path.join(home, *parts), prefix)]
    files.sort(key=lambda x: -x[0])
    size = 0
    for mtime, path, agent in files:
        if len(out["hits"]) >= max_hits or time.time() > deadline or size > MAX_OUT:
            out["truncated"] = True
            break
        try:
            for role, text, meta in _messages(path, agent, needle):
                idx = text.lower().find(needle)
                if idx < 0:
                    continue
                hit = {"agent": agent, "role": role, "path": path,
                       "session": meta.get("session") or os.path.splitext(os.path.basename(path))[0],
                       "cwd": meta.get("cwd") or "", "title": meta.get("title") or "",
                       "snippet": _snippet(text, idx, len(needle)), "ts": mtime}
                out["hits"].append(hit)
                size += len(json.dumps(hit))
                break
        except OSError:
            continue
    return out


if "D" in globals():
    _home = os.environ.get("BERGR_SEARCH_HOME") or os.path.expanduser("~")
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")
    sys.stdout.write(json.dumps(search(D.get("q") or "", _home), ensure_ascii=False) + "\n")
    sys.stdout.flush()
