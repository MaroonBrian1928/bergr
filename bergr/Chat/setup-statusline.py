# Installs Bergr's Claude Code status line on this machine (run by the app over SSH):
# saves ~/.claude/statusline-herdr.py, keeps any status line already set (it runs from ours),
# and adds "statusLine" to ~/.claude/settings.json without rewriting anything else there.
# Prints one JSON line: {"ok": true, "done": [...]} or {"ok": false, "error": "..."}.
import base64, json, os, re, shutil, sys

def main():
    script = base64.b64decode(sys.argv[1]).decode()
    home = os.path.expanduser("~/.claude")
    os.makedirs(home, exist_ok=True)
    target = os.path.join(home, "statusline-herdr.py")
    command = "python3 ~/.claude/statusline-herdr.py"
    done = []
    with open(target, "w") as f:
        f.write(script)
    os.chmod(target, 0o755)
    done.append("saved ~/.claude/statusline-herdr.py")

    path = os.path.join(home, "settings.json")
    text = open(path).read() if os.path.exists(path) else ""
    settings = json.loads(text) if text.strip() else {}
    current = settings.get("statusLine")
    if isinstance(current, dict) and "statusline-herdr" in str(current.get("command", "")):
        done.append("settings.json already uses it")
        return {"ok": True, "done": done}
    if isinstance(current, dict) and current.get("command"):
        with open(os.path.join(home, "statusline-herdr.json"), "w") as f:
            json.dump({"chain": current["command"]}, f)
        done.append("kept your status line (" + current["command"] + "); it still shows")

    entry = json.dumps({"type": "command", "command": command})
    if text.strip():
        shutil.copyfile(path, path + ".bergr-backup")
        if current is not None:
            # Replace the existing value only: find `"statusLine": {...}` and swap the object.
            new = re.sub(r'("statusLine"\s*:\s*)\{[^{}]*\}', lambda m: m.group(1) + entry, text, count=1)
        else:
            # Add the key right after the opening brace, in the file's own indentation.
            indent = re.search(r'\{\s*\n([ \t]+)"', text)
            pad = indent.group(1) if indent else "  "
            body = text.split("{", 1)[1]
            sep = "," if body.strip() and not body.strip().startswith("}") else ""
            new = text.split("{", 1)[0] + "{\n" + pad + '"statusLine": ' + entry + sep + ("\n" + body.lstrip("\n") if sep else body)
        json.loads(new)  # never write a broken file
        with open(path, "w") as f:
            f.write(new)
        done.append("added statusLine to ~/.claude/settings.json (backup: settings.json.bergr-backup)")
    else:
        with open(path, "w") as f:
            json.dump({"statusLine": json.loads(entry)}, f, indent=2)
            f.write("\n")
        done.append("created ~/.claude/settings.json with statusLine")
    return {"ok": True, "done": done}

try:
    print(json.dumps(main()))
except Exception as e:
    print(json.dumps({"ok": False, "error": f"{type(e).__name__}: {e}"}))
