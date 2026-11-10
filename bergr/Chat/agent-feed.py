# Bergr's chat feed: runs on the herdr-core host (over SSH, python3 -I), finds the conversation of
# the coding agent in one terminal and streams it as normalized JSON lines on stdout:
#   {"t":"reset","agent":..,"session":..}   a (new) conversation starts; drop what you have
#   {"t":"msg","id":..,"role":"user"|"assistant","text":..}   upsert by id
#   {"t":"tool","id":..,"name":..,"summary":..}               upsert by id
#   {"t":"toolout","id":<tool event id>,"text":<last <=12 lines, <=1200 chars of the tool's result>}
#                                                             upsert; arrives after the tool event
#   {"t":"plan","id":"plan","steps":[{"text":..,"status":"pending|in_progress|completed"}]}
#                                                             the agent's task list; replaces the last
#   {"t":"image","id":..,"role":"user"|"assistant","mime":..,"data":<base64>}   (only up to 1.5 MB)
#   {"t":"subagent","id":<agentId|threadId>,"parent":<tool event id>|null,"name":..,"kind":..,
#    "state":"running|done|failed","steps":<tool calls seen>,"summary":<last assistant line>}
#                                                             upsert; a sub-agent's progress, every ~2 s
#                                                             when changed. Its own messages are never
#                                                             sent as msg/tool events.
#   {"t":"question","id":..,"title":..,"options":[..]}   the agent asks the user to pick one
#   {"t":"ping"}                                              every few seconds
#   {"t":"usage","model":..,"effort":..,"used":<tokens>,"limit":<tokens>|null,
#    "session":{"percent":..,"resets_at":<epoch s>}|null,"weekly":{..}|null}   context and plan usage
# Usage: agent-feed.py <claude|codex|antigravity> <pid> <cwd> [session-id|-]
# The session id comes from the agent's launch command (claude --resume <id>, codex resume <id>).
# Read-only: it never writes to the agents' files.
import html
import base64, glob, json, os, re, sqlite3, subprocess, sys, time

AGENT, PID, CWD = sys.argv[1], int(sys.argv[2] or 0), sys.argv[3]
HINT = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] not in ("", "-") else None
if HINT and not all(c.isalnum() or c in "-_" for c in HINT):
    HINT = None  # it goes into a glob pattern
MAX_IMAGE = 1_500_000  # decoded bytes
HOME = os.path.expanduser("~")
BACKLOG = 400  # messages sent when a conversation is first opened


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")


def flush():
    sys.stdout.flush()


def descendants(pid):
    """pid and its children (an agent is often a shim that starts the real binary)."""
    pids = [pid] if pid else []
    try:
        rows = subprocess.run(["ps", "-A", "-o", "pid=,ppid="], capture_output=True, text=True).stdout.split("\n")
        kids = {}
        for row in rows:
            parts = row.split()
            if len(parts) == 2:
                kids.setdefault(int(parts[1]), []).append(int(parts[0]))
        i = 0
        while i < len(pids) and len(pids) < 64:
            pids += kids.get(pids[i], [])
            i += 1
    except Exception:
        pass
    return pids


def started_at(pid):
    """When the agent process started (epoch seconds), or 0 if unknown. A conversation from
    before that belongs to an earlier run, not to this terminal."""
    if not pid:
        return 0
    try:
        out = subprocess.run(["ps", "-o", "etime=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        days, _, clock = out.rpartition("-")
        parts = [int(x) for x in clock.split(":")]
        while len(parts) < 3:
            parts.insert(0, 0)
        secs = (int(days or 0) * 24 + parts[0]) * 3600 + parts[1] * 60 + parts[2]
        return time.time() - secs - 5
    except Exception:
        return 0


STARTED = started_at(PID)


def fresh(path):
    """Written since this agent started (a conversation it can't be is older)."""
    try:
        return os.path.getmtime(path) >= STARTED
    except OSError:
        return False


def open_files(pids):
    files = []
    for p in pids:
        fd = f"/proc/{p}/fd"
        try:
            names = os.listdir(fd)
        except OSError:
            continue  # gone, or another user's
        if names:
            for f in names:
                try:
                    files.append(os.readlink(os.path.join(fd, f)))
                except OSError:
                    pass
    if not files and pids and not os.path.isdir("/proc"):
        try:
            out = subprocess.run(["lsof", "-Fn", "-p", ",".join(map(str, pids))],
                                 capture_output=True, text=True, timeout=5).stdout
            files = [l[1:] for l in out.split("\n") if l.startswith("n")]
        except Exception:
            pass
    return files


def tool_tail(text, lines=12, chars=1200):
    """The end of a tool's output: the last lines, the last characters; None when empty."""
    if not isinstance(text, str):
        return None
    text = text.replace("\r\n", "\n").rstrip()
    if not text.strip():
        return None
    out = text.split("\n")[-lines:]
    text = "\n".join(out)
    return text[-chars:] if len(text) > chars else text


def toolout(tid, text):
    tail = tool_tail(text)
    return [{"t": "toolout", "id": tid, "text": tail}] if tail and tid else []


def result_text(content):
    """A tool result's text: a string, or a list of {type:text,text} blocks."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(c.get("text") or "" for c in content if isinstance(c, dict) and c.get("type") == "text")
    return ""


def short(s, n=160):
    s = " ".join(str(s).split())
    return s if len(s) <= n else s[: n - 1] + "…"


LOCAL_IMAGE = re.compile(r"\]\((/[^)\s]+\.(?:png|jpe?g|gif|webp|heic))\)", re.IGNORECASE)
IMAGE_TYPES = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
               "webp": "image/webp", "heic": "image/heic"}


def linked_images(eid, text):
    """Images a reply links to by a path on this machine (`![..](/tmp/x.png)`, `[..](/tmp/x.png)`),
    which the phone can't open: their contents, as image events after the message."""
    seen = []
    for path in LOCAL_IMAGE.findall(text or ""):
        if path in seen:
            continue
        seen.append(path)
        try:
            if not os.path.isfile(path) or os.path.getsize(path) > MAX_IMAGE:
                continue
            with open(path, "rb") as fh:
                data = base64.b64encode(fh.read()).decode()
        except OSError:
            continue
        ev = image_event(f"{eid}.file{len(seen)}", "assistant", IMAGE_TYPES[path.rsplit(".", 1)[1].lower()], data)
        if ev:
            yield ev


def claude_long_context():
    """Whether Claude Code is set to the 1M-token context (`"model": "opus[1m]"` in its settings)."""
    try:
        return "[1m]" in str(json.load(open(os.path.join(HOME, ".claude", "settings.json"))).get("model", ""))
    except Exception:
        return False


CLAUDE_1M = claude_long_context()
# Written by the herdr chat status line for Claude Code (~/.claude/statusline-herdr.py), when a
# machine has it: the plan limits, and each session's real context window.
HERDR_CHAT = os.path.join(HOME, ".cache", "herdr-chat")


def claude_status(session_id):
    """(context window, session window, weekly window) from the status line's files, when present."""
    window = None
    try:
        window = int(json.load(open(os.path.join(HERDR_CHAT, "ctx", f"{session_id}.json"))).get("window") or 0) or None
    except Exception:
        pass
    session = weekly = None
    try:
        now = time.time()
        for w in json.load(open(os.path.join(HERDR_CHAT, "claude-limits.json"))).get("limits") or []:
            if w.get("resets") and w["resets"] < now:
                continue  # a window that has reset since: its number is stale
            entry = {"percent": w.get("used"), "resets_at": w.get("resets")}
            if w.get("minutes") == 300:
                session = entry
            elif w.get("minutes") == 10080:
                weekly = entry
    except Exception:
        pass
    return window, session, weekly


def image_event(eid, role, mime, data):
    """An image event, or None when it is too big (or not base64 text) to send."""
    if not isinstance(data, str) or not data or not isinstance(mime, str):
        return None
    if len(data) * 3 // 4 - data[-2:].count("=") > MAX_IMAGE:
        return None
    return {"t": "image", "id": eid, "role": role, "mime": mime, "data": data}


def plan_event(steps):
    out = []
    for text, status in steps:
        if isinstance(text, str) and text.strip():
            out.append({"text": text, "status": status if status in ("pending", "in_progress", "completed")
                        else "pending"})
    return {"t": "plan", "id": "plan", "steps": out}


def tool_summary(args):
    if isinstance(args, str):
        try:
            args = json.loads(args)
        except Exception:
            return short(args)
    if not isinstance(args, dict):
        return ""
    def first(keys):
        for key in keys:
            v = args.get(key)
            if isinstance(v, list):
                v = " ".join(map(str, v))
            if isinstance(v, str) and v.strip():
                return v
        return None
    # The agent's own description, then what actually runs: "List workspace files" / "ls -la ~/x".
    # Both go, one per line: the chat shows the first and opens to the second.
    what = first(("toolSummary", "description"))
    does = first(("command", "cmd", "CommandLine", "file_path", "path", "AbsolutePath", "DirectoryPath",
                  "pattern", "query", "url", "prompt"))
    if what and does and short(does) != short(what):
        return short(what) + "\n" + short(does, 400)
    return short(what or does or "")


class Tail:
    """Reads complete new lines from a growing file."""

    def __init__(self, path):
        self.path, self.offset, self.rest = path, 0, b""

    def start_backlog(self, lines):
        # Start near the end of a big file: about `lines` lines back.
        size = os.path.getsize(self.path)
        with open(self.path, "rb") as f:
            pos = size
            count = 0
            while pos > 0 and count <= lines:
                step = min(1 << 20, pos)
                pos -= step
                f.seek(pos)
                count += f.read(step).count(b"\n")
            self.offset = pos
        if pos > 0:
            self.rest = None  # skip the partial first line

    def lines(self):
        try:
            with open(self.path, "rb") as f:
                f.seek(self.offset)
                data = f.read()
        except OSError:
            return []
        self.offset += len(data)
        if self.rest is None:
            cut = data.find(b"\n")
            if cut < 0:
                return []
            data, self.rest = data[cut + 1 :], b""
        data = self.rest + data
        *done, self.rest = data.split(b"\n")
        out = []
        for raw in done:
            try:
                out.append(json.loads(raw))
            except Exception:
                pass
        return out


# MARK: Sub-agents: their own transcripts, summarised as status events (never as chat messages)

SUB_WINDOW = 6 * 3600  # only sub-agents written within this many seconds
SUB_QUIET = 60  # a sub-agent silent this long is done
SUB_READ = 64 * 1024  # a child's transcript is read from its last 64 KB
SUBS = {}


def recent(path):
    try:
        return time.time() - os.path.getmtime(path) < SUB_WINDOW
    except OSError:
        return False


def last_line(text):
    lines = [l.strip() for l in str(text).split("\n") if l.strip()]
    return short(lines[-1]) if lines else ""


class SubTrack:
    """One sub-agent: reads its transcript incrementally and says when its state changed."""

    def __init__(self, sid, path, parent, name, kind, parse):
        self.id, self.path, self.parent, self.name, self.kind, self.parse = sid, path, parent, name, kind, parse
        self.steps, self.summary, self.force, self.last, self.born = 0, "", None, None, ""
        self.tail = Tail(path)
        try:
            self.tail.offset = max(0, os.path.getsize(path) - SUB_READ)
        except OSError:
            pass
        if self.tail.offset:
            self.tail.rest = None

    def event(self):
        for d in self.tail.lines():
            self.parse(d, self)
        try:
            quiet = time.time() - os.path.getmtime(self.path) > SUB_QUIET
        except OSError:
            quiet = True
        state = self.force or ("done" if quiet else "running")
        ev = {"t": "subagent", "id": self.id, "parent": self.parent, "name": self.name, "kind": self.kind,
              "state": state, "steps": self.steps, "summary": self.summary}
        if ev == self.last:
            return None
        self.last = ev
        return ev


# MARK: Claude Code: ~/.claude/sessions/<pid>.json names the session; the transcript is
# ~/.claude/projects/<project>/<sessionId>.jsonl


class Claude:
    def locate(self):
        base = os.path.join(HOME, ".claude")
        meta = None
        for p in descendants(PID):
            f = os.path.join(base, "sessions", f"{p}.json")
            if os.path.exists(f):
                meta = f
                break
        if meta is None and HINT:
            # A resumed session: its file can predate this process, so no fresh() here.
            found = glob.glob(os.path.join(base, "projects", "*", f"{HINT}.jsonl"))
            if found:
                return found[0]
        if meta is None:
            same = []
            for f in glob.glob(os.path.join(base, "sessions", "*.json")):
                try:
                    if json.load(open(f)).get("cwd") == CWD:
                        same.append(f)
                except Exception:
                    pass
            same = [f for f in same if fresh(f)]
            if same:
                meta = max(same, key=os.path.getmtime)
        if meta is None:
            return None
        try:
            sid = json.load(open(meta)).get("sessionId")
        except Exception:
            return None
        found = [f for f in glob.glob(os.path.join(base, "projects", "*", f"{sid}.jsonl")) if fresh(f)]
        return found[0] if found else None

    results = None  # tool_use id -> {"error", "async"} of the parent's finished tool calls

    def parse(self, d):
        kind = d.get("type")
        # Compaction: the divider becomes a tool row, and the summary that follows is its output.
        if kind == "system" and d.get("subtype") == "compact_boundary":
            m = d.get("compactMetadata") or {}
            k = lambda n: f"{round(int(n) / 1000)}k" if n else "?"
            bits = [f"{k(m.get('preTokens'))} → {k(m.get('postTokens'))} tokens"] if m.get("preTokens") else []
            if m.get("durationMs"):
                bits.append(f"{round(m['durationMs'] / 1000)}s")
            yield {"t": "tool", "id": d.get("uuid") or str(id(d)),
                   "name": "Auto Compaction ran" if m.get("trigger") == "auto" else "Compacted",
                   "summary": " · ".join(bits), "compact": True}
            return
        if d.get("isCompactSummary"):
            c = (d.get("message") or {}).get("content")
            c = c if isinstance(c, str) else result_text(c)
            if c and d.get("parentUuid"):
                yield {"t": "toolout", "id": d["parentUuid"], "text": c}
            return
        # A message typed while Claude was working: Claude Code records it as a queued-command
        # attachment, not a user message, once it takes it in mid-turn.
        att = d.get("attachment") if kind == "attachment" else None
        if isinstance(att, dict) and att.get("type") == "queued_command" and not d.get("isSidechain") \
                and att.get("commandMode", "prompt") == "prompt" \
                and (att.get("origin") or {}).get("kind", "human") == "human":
            text = att.get("prompt")
            text = user_text(text) if isinstance(text, str) else None
            if text and text.strip():
                yield {"t": "msg", "id": (d.get("uuid") or str(id(d))) + ".0", "role": "user", "text": text}
            return
        if kind not in ("user", "assistant") or d.get("isMeta") or d.get("isSidechain"):
            return
        if kind == "user" and isinstance((d.get("message") or {}).get("content"), list):
            tur = d.get("toolUseResult") if isinstance(d.get("toolUseResult"), dict) else {}
            if self.results is None:
                self.results = {}
            for b in d["message"]["content"]:
                if isinstance(b, dict) and b.get("type") == "tool_result" and b.get("tool_use_id"):
                    self.results[b["tool_use_id"]] = {
                        "error": bool(b.get("is_error")) or tur.get("status") in ("failed", "error"),
                        "async": bool(tur.get("isAsync"))}
        msg = d.get("message") or {}
        usage = msg.get("usage") if kind == "assistant" else None
        if isinstance(usage, dict) and msg.get("model") and msg.get("model") != "<synthetic>":
            used = sum(int(usage.get(k) or 0) for k in
                       ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens"))
            window, session, weekly = claude_status(d.get("sessionId") or "")
            yield {"t": "usage", "model": msg["model"], "effort": None, "used": used,
                   "limit": window or (1_000_000 if CLAUDE_1M or used > 200_000 else 200_000),
                   "session": session, "weekly": weekly}
        content = msg.get("content")
        uid = d.get("uuid") or str(id(d))
        if isinstance(content, str):
            content = [{"type": "text", "text": content}]
        for i, block in enumerate(content or []):
            t = block.get("type")
            bid = f"{uid}.{i}"
            if t == "text":
                text = block.get("text") or ""
                if kind == "user":
                    shell = shell_text(text)
                    if shell and shell[0] != "shell":
                        yield {"t": "msg", "id": bid, "role": shell[0], "text": shell[1]}
                        continue
                    text = user_text(text)
                    if text is None:
                        continue
                if text.strip():
                    yield {"t": "msg", "id": bid, "role": kind, "text": text}
                    if kind == "assistant":
                        yield from linked_images(bid, text)
            elif t == "image":
                src = block.get("source") or {}
                ev = image_event(bid, kind, src.get("media_type"), src.get("data")) \
                    if src.get("type") == "base64" else None
                if ev:
                    yield ev
            elif t == "tool_result":
                yield from toolout(block.get("tool_use_id"), result_text(block.get("content")))
            elif t == "tool_use" and block.get("name") == "TodoWrite" \
                    and isinstance((block.get("input") or {}).get("todos"), list):
                yield plan_event([(x.get("content"), x.get("status")) for x in block["input"]["todos"]
                                  if isinstance(x, dict)])
            elif t == "tool_use":
                yield {"t": "tool", "id": block.get("id") or bid, "name": block.get("name") or "tool",
                       "summary": tool_summary(block.get("input"))}


    def subagents(self, path):
        """Sub-agents of this conversation: <session>/subagents/agent-<id>.jsonl + .meta.json."""
        out = []
        for meta_path in glob.glob(os.path.join(path[: -len(".jsonl")], "subagents", "agent-*.meta.json")):
            tx = meta_path[: -len(".meta.json")] + ".jsonl"
            if not recent(tx):
                continue
            aid = os.path.basename(tx)[len("agent-"):-len(".jsonl")]
            tr = SUBS.get(aid)
            if tr is None:
                try:
                    with open(meta_path) as fh:
                        meta = json.load(fh)
                except Exception:
                    continue
                tr = SUBS[aid] = SubTrack(aid, tx, meta.get("toolUseId"),
                                          short(meta.get("description") or meta.get("agentType") or "Sub-agent", 80),
                                          meta.get("agentType") or "claude", self.parse_child)
            res = (self.results or {}).get(tr.parent)
            if res and res["error"]:
                tr.force = "failed"
            elif res and not res["async"]:
                tr.force = "done"
            out.append(tr)
        return out

    def parse_child(self, d, tr):
        if d.get("type") != "assistant":
            return
        content = (d.get("message") or {}).get("content")
        if isinstance(content, str):
            content = [{"type": "text", "text": content}]
        for b in content or []:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "tool_use":
                tr.steps += 1
            elif b.get("type") == "text" and (b.get("text") or "").strip():
                tr.summary = last_line(b["text"])


def tag(s, name):
    """The text inside <name>…</name>, or None."""
    m = re.search(rf"<{name}>(.*?)</{name}>", s, re.S)
    # Claude Code escapes &, < and > inside these tags.
    return html.unescape(m.group(1)) if m else None


def shell_text(text):
    """A `!` shell command typed in Claude Code (recorded as <bash-input>) as the person typed it,
    and its output (<bash-stdout>/<bash-stderr>) as a code block from the agent's side; else None."""
    s = text.strip()
    if s.startswith("<bash-input>"):
        command = tag(s, "bash-input")
        return ("user", "!" + command.strip()) if command and command.strip() else None
    if s.startswith("<user_shell_command>"):
        # Codex: <command>…</command><result>Exit code: N\nDuration: … seconds\nOutput:\n…</result>
        command = (tag(s, "command") or "").strip()
        if not command:
            return None
        lines = (tag(s, "result") or "").strip("\n").split("\n")
        code, body = None, []
        for line in lines:
            if line.startswith("Exit code:") and code is None and not body:
                code = line.split(":", 1)[1].strip()
            elif (line.startswith("Duration:") or line.startswith("Wall time")) and not body:
                continue
            elif line.strip() == "Output:" and not body:
                continue
            else:
                body.append(line)
        out = "\n".join(body).strip("\n").replace("```", "`\u200b``")
        if code and code != "0":
            out = (out + "\n" if out else "") + f"(exit code {code})"
        return ("shell", ("!" + command, "```\n" + (out or "(no output)") + "\n```"))
    if s.startswith("<bash-stdout>") or s.startswith("<bash-stderr>"):
        out = "\n".join(x for x in ((tag(s, "bash-stdout") or "").rstrip(), (tag(s, "bash-stderr") or "").rstrip()) if x)
        out = out.replace("```", "`\u200b``")
        return ("assistant", "```\n" + (out or "(no output)") + "\n```")
    return None


def user_text(text):
    """What the person typed, or None for what the agent injected."""
    s = text.strip()
    if s.startswith("<command-name>"):
        name = s.split("<command-name>", 1)[1].split("</command-name>", 1)[0]
        args = ""
        if "<command-args>" in s:
            args = s.split("<command-args>", 1)[1].split("</command-args>", 1)[0]
        return (name + " " + args).strip()
    if s.startswith("<") or s.startswith("[Request interrupted") or s.startswith("# AGENTS.md") \
            or s.startswith("Caveat:"):
        return None
    return text


# MARK: Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl (zstd-compressed once finished)


MEM_CITE = re.compile(r"\s*<oai-mem-citation>(.*?)(?:</oai-mem-citation>|$)", re.S)


def memory_citations(text):
    """Codex's memory citations (<oai-mem-citation> blocks) become one quiet line naming what it
    remembered, instead of raw tags."""
    notes = []

    def repl(m):
        for entry in re.findall(r"note=\[(.*?)\]", m.group(1), re.S):
            entry = " ".join(entry.split())
            if entry and entry not in notes:
                notes.append(entry)
        return ""

    out = MEM_CITE.sub(repl, text).rstrip()
    if out == text.rstrip():
        return text, None
    return out, ("From memory: " + "; ".join(notes)) if notes else None


def codex_meta(path):
    try:
        with open(path, "rb") as fh:
            return json.loads(fh.readline()).get("payload") or {}
    except Exception:
        return {}


def codex_is_main(meta):
    """The user's own thread, not a sub-agent or the approval reviewer ("guardian") that Codex runs
    beside it in files of their own, in the same folder."""
    return meta.get("thread_source") in (None, "user") and not meta.get("parent_thread_id") \
        and not meta.get("forked_from_id") and "subagent" not in str(meta.get("source") or "")


def codex_child_of(meta, parent_id):
    """The thread_spawn info when this is a sub-agent thread of `parent_id` (never the guardian
    reviewer), else None."""
    src = meta.get("source")
    if meta.get("thread_source") != "subagent" or not isinstance(src, dict) or "guardian" in str(src):
        return None
    sub = src.get("subagent") if isinstance(src.get("subagent"), dict) else {}
    spawn = sub.get("thread_spawn") or {}
    return spawn if spawn.get("parent_thread_id") == parent_id else None


class Codex:
    found = None  # the rollout seen open by the process: trusted over any guess

    def locate(self):
        # The first look retries briefly: Codex has its rollout open most, not all, of the time,
        # and the fallback below can pick another session in the same folder (a wrong first
        # conversation that's replaced seconds later).
        for attempt in range(1 if self.found else 4):
            for f in open_files(descendants(PID)):
                if "/.codex/sessions/" in f and os.path.basename(f).startswith("rollout-") and f.endswith(".jsonl") \
                        and codex_is_main(codex_meta(f)):
                    type(self).found = f
                    return f
            if attempt < 3 and not self.found:
                time.sleep(0.15)
        if self.found and os.path.exists(self.found):
            return self.found
        files = glob.glob(os.path.join(HOME, ".codex", "sessions", "*", "*", "*", "rollout-*.jsonl"))
        if HINT:
            # A resumed session: its file can predate this process, so no fresh() here.
            hinted = [f for f in files if f.endswith(f"{HINT}.jsonl")]
            if hinted:
                return max(hinted, key=os.path.getmtime)
        files.sort(key=os.path.getmtime, reverse=True)
        for f in files[:40]:
            if not fresh(f):
                break  # sorted newest first: the rest are older still
            meta = codex_meta(f)
            if meta.get("cwd") == CWD and codex_is_main(meta):
                return f
        return None

    model, effort = None, None
    spawns = ()  # [timestamp, tool event id, output text] of the parent's spawn_agent calls
    waited = ""  # output of wait_agent calls: names the agents they finished
    pending = None  # call_id -> ("spawn", entry) | ("wait", None)

    def subagents(self, path):
        """Sub-agent threads: rollouts in the same sessions tree whose parent_thread_id is this thread."""
        parent_id = codex_meta(path).get("id")
        if not parent_id:
            return []
        root = os.path.join(HOME, ".codex", "sessions")
        dirs = {os.path.dirname(path)}
        for back in (0, 86400):
            t = time.localtime(time.time() - back)
            dirs.add(os.path.join(root, "%04d" % t.tm_year, "%02d" % t.tm_mon, "%02d" % t.tm_mday))
        out = []
        for d in dirs:
            for f in glob.glob(os.path.join(d, "rollout-*.jsonl")):
                if f == path or not recent(f):
                    continue
                tr = SUBS.get(f)
                if tr is None:
                    meta = codex_meta(f)
                    spawn = codex_child_of(meta, parent_id)
                    if spawn is None:
                        SUBS[f] = False
                        continue
                    name = meta.get("agent_nickname") or spawn.get("agent_nickname") or spawn.get("agent_role")
                    tr = SUBS[f] = SubTrack(meta.get("id") or os.path.basename(f), f, None,
                                            short(name or "Sub-agent", 80), "codex", self.parse_child)
                    tr.born = str(meta.get("timestamp") or "")
                if tr is False:
                    continue
                if tr.parent is None:
                    tr.parent = self.anchor(tr)
                if tr.id in self.waited:
                    tr.force = "done"
                out.append(tr)
        return out

    def anchor(self, tr):
        """The parent's spawn_agent call that started this thread: the one whose output names it,
        else the latest one before the thread began."""
        best = None
        for ts, tid, out in self.spawns:
            if tr.id in out:
                return tid
            if ts <= tr.born:
                best = tid
        return best

    def parse_child(self, d, tr):
        p = d.get("payload") or {}
        if d.get("type") == "event_msg" and p.get("type") == "task_complete":
            tr.force = "done"
        elif d.get("type") == "response_item":
            if p.get("type") in ("function_call", "custom_tool_call", "local_shell_call"):
                tr.steps += 1
            elif p.get("type") == "message" and p.get("role") == "assistant":
                text = "".join(c.get("text") or "" for c in p.get("content") or [] if isinstance(c, dict))
                if text.strip():
                    tr.summary = last_line(text)

    def parse(self, d):
        p = d.get("payload") or {}
        if d.get("type") == "response_item":
            t = p.get("type")
            if t in ("function_call", "custom_tool_call") and p.get("name") in ("spawn_agent", "wait_agent"):
                if self.pending is None:
                    self.pending, self.spawns = {}, []
                if p["name"] == "spawn_agent":
                    entry = [str(d.get("timestamp") or ""), p.get("id") or p.get("call_id") or str(id(d)), ""]
                    self.spawns.append(entry)
                    self.pending[p.get("call_id")] = entry
                else:
                    self.pending[p.get("call_id")] = None
            elif t in ("function_call_output", "custom_tool_call_output") and self.pending \
                    and p.get("call_id") in self.pending:
                out = p.get("output")
                out = out if isinstance(out, str) else json.dumps(out)
                entry = self.pending.pop(p["call_id"])
                if entry is not None:
                    entry[2] = out
                else:
                    self.waited += out
        yield from self.parse_main(d)

    def parse_main(self, d):
        p = d.get("payload") or {}
        if d.get("type") == "turn_context":
            self.model, self.effort = p.get("model") or self.model, p.get("effort") or self.effort
            return
        if d.get("type") == "event_msg" and p.get("type") == "token_count":
            info = p.get("info") or {}
            last = info.get("last_token_usage") or {}
            limits = p.get("rate_limits") or {}

            def window(w):
                if not isinstance(w, dict) or w.get("used_percent") is None:
                    return None
                return {"percent": w.get("used_percent"), "resets_at": w.get("resets_at")}
            yield {"t": "usage", "model": self.model, "effort": self.effort,
                   "used": int(last.get("total_tokens") or last.get("input_tokens") or 0),
                   "limit": info.get("model_context_window"),
                   "session": window(limits.get("primary")), "weekly": window(limits.get("secondary"))}
            return
        if d.get("type") != "response_item":
            return
        p = d.get("payload") or {}
        t = p.get("type")
        pid = p.get("id") or p.get("call_id") or str(d.get("ordinal") or id(d))
        if t == "message" and p.get("role") in ("user", "assistant"):
            text = "".join(c.get("text") or "" for c in p.get("content") or []
                           if c.get("type") in ("input_text", "output_text", "text"))
            if p["role"] == "user":
                shell = shell_text(text)
                if shell and shell[0] == "shell":
                    yield {"t": "msg", "id": pid, "role": "user", "text": shell[1][0]}
                    yield {"t": "msg", "id": f"{pid}-out", "role": "assistant", "text": shell[1][1]}
                    return
                text = user_text(text)
                if text is None:
                    return
            note = None
            if p["role"] == "assistant":
                text, note = memory_citations(text)
            if text.strip():
                yield {"t": "msg", "id": pid, "role": p["role"], "text": text}
                if p["role"] == "assistant":
                    yield from linked_images(pid, text)
            if note:
                yield {"t": "msg", "id": f"{pid}-mem", "role": "note", "text": note}
            for i, c in enumerate(p.get("content") or []):
                url = c.get("image_url")
                if c.get("type") == "input_image" and isinstance(url, str) and url.startswith("data:") \
                        and ";base64," in url:
                    head, _, data = url.partition(";base64,")
                    ev = image_event(f"{pid}.img{i}", p["role"], head[5:], data)
                    if ev:
                        yield ev
        elif t == "function_call" and p.get("name") == "update_plan":
            try:
                plan = json.loads(p.get("arguments") or "{}").get("plan")
            except Exception:
                plan = None
            if isinstance(plan, list):
                yield plan_event([(x.get("step"), x.get("status")) for x in plan if isinstance(x, dict)])
            else:
                yield {"t": "tool", "id": pid, "name": "update_plan", "summary": ""}
        elif t in ("function_call", "custom_tool_call", "local_shell_call"):
            args = p.get("arguments") or p.get("input") or p.get("action") or ""
            if p.get("call_id"):
                self.__dict__.setdefault("calls", {})[p["call_id"]] = pid
            if (p.get("name") or "").startswith("request_user_input"):
                # Codex asking the user (A/B/C): a question card, not a tool step.
                try:
                    qs = json.loads(args).get("questions") if isinstance(args, str) else args.get("questions")
                except Exception:
                    qs = None
                for i, q in enumerate(qs or []):
                    if isinstance(q, dict) and q.get("title"):
                        opts = [o if isinstance(o, str) else (o.get("label") or o.get("title") or "")
                                for o in q.get("options") or []]
                        yield {"t": "question", "id": f"{pid}-q{i}", "title": q["title"], "options": [o for o in opts if o]}
                if qs:
                    return
            yield {"t": "tool", "id": pid, "name": p.get("name") or "shell", "summary": tool_summary(args)}
        elif t in ("function_call_output", "custom_tool_call_output"):
            out = p.get("output")
            if isinstance(out, str) and out.lstrip().startswith("{"):
                try:
                    out = json.loads(out).get("output", out)
                except Exception:
                    pass
            elif isinstance(out, dict):
                out = out.get("content") or out.get("output")
            cid = p.get("call_id")
            yield from toolout(self.__dict__.get("calls", {}).get(cid, cid), result_text(out))


# MARK: Antigravity: ~/.gemini/antigravity-cli/conversations/<id>.db (SQLite, protobuf steps)


def pb_fields(b):
    out, i = [], 0
    while i < len(b):
        key, i = pb_varint(b, i)
        field, wire = key >> 3, key & 7
        if wire == 0:
            v, i = pb_varint(b, i)
        elif wire == 1:
            v, i = b[i : i + 8], i + 8
        elif wire == 5:
            v, i = b[i : i + 4], i + 4
        elif wire == 2:
            n, i = pb_varint(b, i)
            v, i = b[i : i + n], i + n
        else:
            raise ValueError("wire type")
        out.append((field, v))
    return out


def pb_varint(b, i):
    r = s = 0
    while True:
        x = b[i]
        i += 1
        r |= (x & 0x7F) << s
        s += 7
        if x < 0x80:
            return r, i


def pb_get(b, *path):
    """Every value at a field path (repeated fields give several)."""
    vals = [b]
    for f in path:
        nxt = []
        for v in vals:
            try:
                nxt += [x for k, x in pb_fields(v) if k == f and isinstance(x, bytes)]
            except Exception:
                pass
        vals = nxt
    return vals


def pb_str(b, *path):
    vals = pb_get(b, *path)
    try:
        return vals[0].decode() if vals else ""
    except UnicodeDecodeError:
        return ""


class Antigravity:
    base = os.path.join(HOME, ".gemini", "antigravity-cli")

    def locate(self):
        try:
            conv = json.load(open(os.path.join(self.base, "cache", "last_conversations.json"))).get(CWD)
        except Exception:
            conv = None
        if conv:
            f = os.path.join(self.base, "conversations", f"{conv}.db")
            if os.path.exists(f) and fresh(f):
                return f
        dbs = [f for f in glob.glob(os.path.join(self.base, "conversations", "*.db")) if fresh(f)]
        return max(dbs, key=os.path.getmtime) if dbs else None

    def rows(self, path, since):
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=2)
        try:
            return db.execute("select idx, step_type, step_payload from steps where idx >= ? order by idx",
                              (since,)).fetchall()
        finally:
            db.close()

    def shell_commands(self, offset):
        """`!` commands typed in this folder since the agent started: Antigravity keeps them only in
        its input history (history.jsonl, "type": "shell"), not in the conversation, and keeps no
        output. Returns the user messages and the offset to read on from."""
        out = []
        try:
            with open(os.path.join(self.base, "history.jsonl"), "rb") as fh:
                fh.seek(0, 2)
                if fh.tell() < offset:
                    offset = 0
                fh.seek(offset)
                data = fh.read()
        except OSError:
            return out, offset
        end = data.rfind(b"\n") + 1
        for line in data[:end].splitlines():
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if d.get("type") == "shell" and os.path.realpath(d.get("workspace") or "") == os.path.realpath(CWD) and (d.get("display") or "").strip() \
                    and (d.get("timestamp") or 0) / 1000 >= STARTED:
                out.append({"t": "msg", "id": f"h{d['timestamp']}", "role": "user",
                            "text": "!" + d["display"].strip()})
        return out, offset + end

    def parse_row(self, idx, kind, payload):
        payload = payload or b""
        if kind == 14:
            text = pb_str(payload, 19, 2)
            if text.strip():
                yield {"t": "msg", "id": f"s{idx}", "role": "user", "text": text}
        elif kind == 15:
            text = pb_str(payload, 20, 1)
            if text.strip():
                yield {"t": "msg", "id": f"s{idx}", "role": "assistant", "text": text}
                yield from linked_images(f"s{idx}", text)
            for n, call in enumerate(pb_get(payload, 20, 7)):
                name = pb_str(call, 2) or "tool"
                yield {"t": "tool", "id": f"s{idx}.{n}", "name": name, "summary": tool_summary(pb_str(call, 3))}


CLAUDE_BUILTINS = [
    ("/clear", "Start a new conversation"), ("/compact", "Summarize the conversation to free context"),
    ("/context", "Show what fills the context"), ("/cost", "Show this session's cost"),
    ("/model", "Switch the model"), ("/usage", "Show plan usage"), ("/resume", "Resume a conversation"),
    ("/review", "Review a pull request"), ("/init", "Write a CLAUDE.md for this project"),
    ("/memory", "Edit memory files"), ("/agents", "Manage subagents"), ("/mcp", "Manage MCP servers"),
    ("/permissions", "Manage permissions"), ("/status", "Show status"), ("/help", "Show help"),
]
CODEX_BUILTINS = [
    ("/new", "Start a new conversation"), ("/compact", "Summarize the conversation to free context"),
    ("/model", "Choose the model and effort"), ("/status", "Show session and usage"),
    ("/diff", "Show the git diff"), ("/review", "Review the current changes"), ("/init", "Write an AGENTS.md"),
    ("/mention", "Mention a file"), ("/approvals", "Choose what needs approval"), ("/quit", "Exit Codex"),
]


def skill_description(path):
    """The `description:` line of a skill's or command's front matter, shortened."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            head = fh.read(4000)
    except OSError:
        return ""
    if head.startswith("---"):
        for line in head.split("\n")[1:]:
            if line.strip() == "---":
                break
            if line.startswith("description:"):
                text = line.split(":", 1)[1].strip().strip('"\'')
                return text if len(text) <= 110 else text[:109] + "…"
    return ""


def plugin_commands():
    """Claude Code plugins' skills and commands, as `/<plugin>:<name>`: only enabled plugins
    (settings.json "enabledPlugins", "<plugin>@<marketplace>": true), from the newest cached
    version of each (cache/<marketplace>/<plugin>/<version>/). A skill is any folder holding a
    SKILL.md, at any depth: plugins lay them out as skills/<name>, skills/<group>/<name> or <name>."""
    cache = os.path.join(HOME, ".claude", "plugins", "cache")
    enabled = None
    try:
        with open(os.path.join(HOME, ".claude", "settings.json")) as fh:
            plugins = json.load(fh).get("enabledPlugins")
        if isinstance(plugins, dict):
            enabled = {k for k, v in plugins.items() if v}
    except Exception:
        pass
    out = []
    for plugin_dir in sorted(glob.glob(os.path.join(cache, "*", "*"))):
        marketplace, plugin = plugin_dir.split(os.sep)[-2:]
        if enabled is not None and f"{plugin}@{marketplace}" not in enabled:
            continue
        versions = [d for d in glob.glob(os.path.join(plugin_dir, "*")) if os.path.isdir(d)]
        if not versions:
            continue
        newest = max(versions, key=os.path.getmtime)
        for f in sorted(glob.glob(os.path.join(newest, "**", "SKILL.md"), recursive=True)):
            if os.sep + "node_modules" + os.sep in f:
                continue
            out.append((f"/{plugin}:{os.path.basename(os.path.dirname(f))}", skill_description(f)))
        commands = os.path.join(newest, "commands")
        for f in sorted(glob.glob(os.path.join(commands, "**", "*.md"), recursive=True)):
            rel = os.path.relpath(f, commands)[:-3].replace(os.sep, ":")
            out.append((f"/{plugin}:{rel}", skill_description(f)))
    return out


def list_commands():
    """What can follow `/` (and `$` for Codex skills) in this agent: built-ins, then skills and
    commands installed on this machine and in the project."""
    out, seen = [], set()

    def add(name, desc):
        if name not in seen:
            seen.add(name)
            out.append({"name": name, "description": desc})

    if AGENT == "claude":
        for name, desc in CLAUDE_BUILTINS:
            add(name, desc)
        for root in (os.path.join(HOME, ".claude"), os.path.join(CWD, ".claude")):
            for f in sorted(glob.glob(os.path.join(root, "skills", "*", "SKILL.md"))):
                add("/" + os.path.basename(os.path.dirname(f)), skill_description(f))
            for f in sorted(glob.glob(os.path.join(root, "commands", "**", "*.md"), recursive=True)):
                rel = os.path.relpath(f, os.path.join(root, "commands"))[:-3].replace(os.sep, ":")
                add("/" + rel, skill_description(f))
        for name, desc in plugin_commands():
            add(name, desc)
    elif AGENT == "codex":
        for name, desc in CODEX_BUILTINS:
            add(name, desc)
        for f in sorted(glob.glob(os.path.join(HOME, ".codex", "prompts", "*.md"))):
            add("/prompts:" + os.path.basename(f)[:-3], skill_description(f))
        for root in (os.path.join(HOME, ".codex"), os.path.join(HOME, ".agents"), os.path.join(CWD, ".codex")):
            for f in sorted(glob.glob(os.path.join(root, "skills", "**", "SKILL.md"), recursive=True)):
                add("$" + os.path.basename(os.path.dirname(f)), skill_description(f))
    return out[:400]


CLAUDE_MODELS = [
    {"id": "claude-opus-5-5", "name": "Opus 5.5", "description": "For complex work and everyday tasks"},
    {"id": "claude-sonnet-5-5", "name": "Sonnet 5.5", "description": "Most efficient for simpler tasks"},
    {"id": "claude-fable-5-1", "name": "Fable 5.1", "description": "For your toughest challenges",
     "note": "Requires usage credits"},
    {"id": "claude-haiku-5-5", "name": "Haiku 5.5", "description": "Fastest for quick answers"},
]
CLAUDE_EFFORTS = ["low", "medium", "high", "xhigh", "max"]


def claude_catalog_file():
    """Claude Code's own model list, as its /model picker shows it: the newest catalog it cached
    (~/.claude/cache/model-catalog), the CLI's ("cc") before the desktop app's ("ccd")."""
    files = glob.glob(os.path.join(HOME, ".claude", "cache", "model-catalog", "*-cc.json")) \
        or glob.glob(os.path.join(HOME, ".claude", "cache", "model-catalog", "*-ccd.json"))
    return max(files, key=os.path.getmtime) if files else None


def claude_catalog():
    """The main models from Claude Code's cached catalog, with their effort levels and badges
    ("Requires usage credits"), or [] to fall back on the built-in list."""
    f = claude_catalog_file()
    try:
        with open(f) as fh:
            models = json.load(fh)["catalog"]["config"]["models"]
    except Exception:
        return []
    out = []
    for m in models:
        if not isinstance(m, dict) or not m.get("id") or m.get("section", "main") != "main":
            continue
        efforts = [e.get("id") for e in (m.get("thinking") or {}).get("effort_options") or []
                   if isinstance(e, dict) and e.get("id")]
        item = {"id": m["id"], "name": m.get("name") or m["id"], "description": m.get("description") or "",
                "efforts": efforts or CLAUDE_EFFORTS}
        badge = m.get("badge")
        if isinstance(badge, dict) and badge.get("message"):
            item["note"] = badge["message"]
        default = (m.get("runtime") or {}).get("default_effort")
        if default:
            item["default_effort"] = default
        out.append(item)
    return out


def models_source():
    """The file the model list comes from, so it's sent again when that file changes."""
    if AGENT == "claude":
        return claude_catalog_file()
    if AGENT == "codex":
        return os.path.join(HOME, ".codex", "models_cache.json")
    return None


MODELS_SEEN = [None, 0, 0]  # file, its mtime, ticks since the last check


def refresh_models(force=False):
    """Sends the model list when its file is new or changed (the agent refreshed its catalog,
    e.g. a new model came out), checking every ten seconds."""
    MODELS_SEEN[2] += 1
    if not force and MODELS_SEEN[2] < 10:
        return
    MODELS_SEEN[2] = 0
    f = models_source()
    try:
        mtime = os.path.getmtime(f) if f else 0
    except OSError:
        mtime = 0
    if force or (f, mtime) != tuple(MODELS_SEEN[:2]):
        MODELS_SEEN[0], MODELS_SEEN[1] = f, mtime
        emit({"t": "models", "items": list_models()})


def list_models():
    """The models (and their effort levels) the agent can switch to in a running session."""
    if AGENT == "claude":
        return claude_catalog() or [dict(m, efforts=CLAUDE_EFFORTS) for m in CLAUDE_MODELS]
    if AGENT == "antigravity":
        # Its /model picker's list (Antigravity CLI 1.5); effort is a low/medium/high slider there.
        return [{"id": name, "name": name, "description": desc, "efforts": ["low", "medium", "high"]}
                for name, desc in (("Gemini 4 Argon", "Google's frontier model"), ("Gemini 3.8 Flash", "Fast"),
                                   ("Claude Opus 5.5", ""), ("Claude Sonnet 5.5", ""), ("GPT-OSS 120B", ""))]
    if AGENT == "codex":
        try:
            cache = json.load(open(os.path.join(HOME, ".codex", "models_cache.json")))
        except Exception:
            return []
        out = []
        for m in cache.get("models") or []:
            if m.get("visibility") != "list" or not m.get("slug"):
                continue
            # Its picker offers these directly; max and ultra sit behind "More reasoning…".
            efforts = [e.get("effort") for e in m.get("supported_reasoning_levels") or []
                       if isinstance(e, dict) and e.get("effort") in ("low", "medium", "high", "xhigh")]
            out.append({"id": m["slug"], "name": m.get("display_name") or m["slug"],
                        "description": m.get("description") or "", "efforts": efforts,
                        "default_effort": m.get("default_reasoning_level")})
        return out
    return []


def follow_jsonl(source):
    path, tail, tick, sub_at = None, None, 0, 0
    while True:
        # Looking for the session costs a process scan; new sessions are rare.
        now = source.locate() if tick % 5 == 0 else path
        tick += 1
        if now and now != path:
            path, tail = now, Tail(now)
            SUBS.clear()
            tail.start_backlog(BACKLOG * 3)
            emit({"t": "reset", "agent": AGENT, "session": os.path.basename(now)})
        if tail:
            for d in tail.lines():
                for ev in source.parse(d) or ():
                    emit(ev)
        if path and hasattr(source, "subagents") and time.time() - sub_at >= 2:
            sub_at = time.time()
            try:
                for tr in source.subagents(path):
                    ev = tr.event()
                    if ev:
                        emit(ev)
            except Exception:
                pass  # sub-agent status is best effort
        refresh_models()
        emit({"t": "ping"})
        flush()
        time.sleep(1)


def antigravity_model():
    """Antigravity's model and effort from its settings ("Gemini 4 Argon (Medium)"), which it
    updates when /model changes them; its conversation files don't say."""
    try:
        name = json.load(open(os.path.join(HOME, ".gemini", "antigravity-cli", "settings.json"))).get("model") or ""
    except Exception:
        return None
    if not name:
        return None
    effort = None
    if name.endswith(")") and " (" in name:
        name, effort = name[:-1].rsplit(" (", 1)
        effort = effort.lower()
    try:
        mode = json.load(open(os.path.join(HOME, ".gemini", "antigravity-cli", "settings.json"))).get("agentMode")
    except Exception:
        mode = None
    return {"t": "usage", "model": name, "effort": effort, "mode": mode, "used": 0, "limit": None,
            "session": None, "weekly": None}


def follow_antigravity(source):
    path, since, tick, history = None, 0, 0, 0
    while True:
        now = source.locate() if tick % 5 == 0 else path
        if tick % 5 == 0:
            status = antigravity_model()
            if status and status != getattr(source, "status", None):
                source.status = status
                emit(status)
        tick += 1
        if now and now != path:
            path, since, history = now, 0, 0
            emit({"t": "reset", "agent": AGENT, "session": os.path.basename(now)})
            # A reset clears what the app knows: send the model and mode again.
            source.status = antigravity_model()
            if source.status:
                emit(source.status)
        if path:
            try:
                rows = source.rows(path, since)
            except Exception:
                rows = []
            for idx, kind, payload in rows:
                for ev in source.parse_row(idx, kind, payload):
                    emit(ev)
            # Steps fill in while they run: read the last few again next time (the app upserts).
            if rows:
                since = max(since, rows[-1][0] - 2)
            shells, history = source.shell_commands(history)
            for ev in shells:
                emit(ev)
        refresh_models()
        emit({"t": "ping"})
        flush()
        time.sleep(1)


def main():
    try:
        emit({"t": "commands", "items": list_commands()})
        refresh_models(force=True)
        if AGENT == "claude":
            follow_jsonl(Claude())
        elif AGENT == "codex":
            follow_jsonl(Codex())
        elif AGENT == "antigravity":
            follow_antigravity(Antigravity())
        else:
            emit({"t": "error", "text": f"unknown agent {AGENT}"})
    except (BrokenPipeError, KeyboardInterrupt):
        pass


if __name__ == "__main__":
    main()
