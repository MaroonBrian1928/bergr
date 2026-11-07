#!/usr/bin/env python3
# Status line for Claude Code that also saves the context window and plan limits, for Bergr and
# Herdr Chat to show. Writes only those numbers (to ~/.cache/herdr-chat), nothing else.
import json, os, subprocess, sys, time
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    d = {}
base = os.path.expanduser("~/.cache/herdr-chat")
def save(path, obj):
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = f"{path}.{os.getpid()}.tmp"
        with open(tmp, "w") as f:
            json.dump(obj, f)
        os.replace(tmp, path)
    except Exception:
        pass
rl = d.get("rate_limits") or {}
lim = []
for key, minutes in (("five_hour", 300), ("seven_day", 10080)):
    w = rl.get(key) or {}
    if isinstance(w.get("used_percentage"), (int, float)):
        lim.append({"minutes": minutes, "used": w["used_percentage"], "resets": w.get("resets_at")})
if lim:
    save(os.path.join(base, "claude-limits.json"), {"limits": lim, "at": time.time()})
sid = d.get("session_id") or ""
cw = d.get("context_window") or {}
model = (d.get("model") or {})
if sid.replace("-", "").isalnum() and cw.get("context_window_size"):
    save(os.path.join(base, "ctx", f"{sid}.json"), {"window": cw["context_window_size"], "model": model.get("id")})
# A status line that was set before this one keeps running, and its output is what shows.
try:
    chain = json.load(open(os.path.expanduser("~/.claude/statusline-herdr.json"))).get("chain")
except Exception:
    chain = None
if chain:
    try:
        out = subprocess.run(chain, shell=True, input=raw, capture_output=True, text=True, timeout=5).stdout
        sys.stdout.write(out)
        sys.exit(0)
    except Exception:
        pass
# what Claude Code shows
parts = [model.get("display_name") or ""]
used = cw.get("used_percentage")
if isinstance(used, (int, float)):
    parts.append(f"{round(used)}% context")
if lim:
    parts.append(f"{round(lim[0]['used'])}% of 5h")
print(" · ".join(p for p in parts if p))
