# Installs, checks or removes the bergr-notify user service. Run by Bergr over SSH:
#   python3 -I -c 'import base64,sys;exec(base64.b64decode(sys.argv.pop(1)))' <this file b64> <args b64>
# Args JSON: {"op": "status"|"install"|"uninstall", "script": "<bergr-notify source>"}.
# Prints exactly one JSON line. Never touches ~/.config/bergr.
# On Windows the service is a Scheduled Task (schtasks, at logon, current user, no admin needed).
# BERGR_HELPER_DRY_RUN=1 prints the service commands instead of running them; BERGR_HELPER_OS forces the OS.
import base64, json, os, re, shutil, subprocess, sys, tempfile

LABEL = "dev.bergr.notify"
UNIT = "bergr-notify"
DRY = os.environ.get("BERGR_HELPER_DRY_RUN") == "1"
HOME = os.path.expanduser("~")
BIN = os.path.join(HOME, ".local", "bin", "bergr-notify")
UNIT_PATH = os.path.join(HOME, ".config", "systemd", "user", "bergr-notify.service")
PLIST_PATH = os.path.join(HOME, "Library", "LaunchAgents", LABEL + ".plist")
LOG_PATH = os.path.join(HOME, "Library", "Logs", "bergr-notify.log")
OS = os.environ.get("BERGR_HELPER_OS") or (
    "darwin" if sys.platform == "darwin" else "windows" if sys.platform == "win32" else "linux")
TASK = "BergrNotify"
LOCALAPPDATA = os.environ.get("LOCALAPPDATA") or os.path.join(HOME, "AppData", "Local")
WIN_BIN = os.path.join(LOCALAPPDATA, "bergr", "bergr-notify.py")
if OS == "windows":
    BIN = WIN_BIN
planned = []


def sh(*cmd):
    """Runs a service command (or records it in dry-run). Returns the exit code."""
    if DRY:
        planned.append(" ".join(cmd))
        return 0
    try:
        return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30).returncode
    except (OSError, subprocess.SubprocessError):
        return 127


def query(*cmd):
    """Read-only check, always really runs. None when the tool is missing."""
    try:
        return subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30).returncode
    except (OSError, subprocess.SubprocessError):
        return None


def query_output(*cmd):
    """Read-only check that returns the output; None when the tool is missing or fails."""
    try:
        res = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return res.stdout if res.returncode == 0 else ""


def windows_python():
    """Windowless pythonw.exe next to the running interpreter when there is one."""
    exe = sys.executable or "python.exe"
    w = os.path.join(os.path.dirname(exe), "pythonw.exe")
    return w if os.path.isfile(w) else exe


def installed_version():
    try:
        with open(BIN) as f:
            m = re.search(r"^VERSION\s*=\s*(\d+)", f.read(), re.M)
        return int(m.group(1)) if m else 0
    except OSError:
        return None


def status():
    version = installed_version()
    running = None
    if version is not None:
        if OS == "windows":
            out = query_output("schtasks", "/Query", "/TN", TASK, "/FO", "CSV", "/NH")
            code = None if out is None else 0 if "Running" in out else 1
        elif OS == "darwin":
            code = query("launchctl", "print", "gui/%d/%s" % (os.getuid(), LABEL))
        else:
            code = query("systemctl", "--user", "is-active", "--quiet", UNIT)
        running = None if code is None else code == 0
    return {"installed": version is not None, "version": version, "running": running, "os": OS}


def find_hc():
    found = shutil.which("hc")
    if found:
        return found
    shell = os.environ.get("SHELL")
    if shell and OS != "windows":
        try:
            out = subprocess.run([shell, "-lc", "command -v hc"], capture_output=True, text=True, timeout=15).stdout
            for line in reversed(out.strip().splitlines()):
                if line.startswith("/") and os.access(line, os.X_OK):
                    return line
        except (OSError, subprocess.SubprocessError):
            pass
    for p in ("~/.local/bin/hc", "~/.cargo/bin/hc", "~/.cargo/bin/hc.exe", "~/AppData/Local/Programs/herdr/hc.exe", "/opt/homebrew/bin/hc", "/usr/local/bin/hc"):
        p = os.path.expanduser(p)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def write_atomic(path, text, mode):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def xml(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def install(script):
    if not script or "VERSION" not in script:
        return {"ok": False, "error": "no script given"}
    hc = find_hc()
    if not hc:
        return {"ok": False, "error": "hc not found"}
    path = os.path.dirname(hc) + ":/usr/local/bin:/usr/bin:/bin" + (":/opt/homebrew/bin" if OS == "darwin" else "")
    m = re.search(r"^VERSION\s*=\s*(\d+)", script, re.M)
    version = int(m.group(1)) if m else 0
    result = {"ok": True, "version": version, "os": OS}
    if OS == "windows":
        write_atomic(BIN, script, 0o644)
        action = '"%s" -I "%s"' % (windows_python(), BIN)
        sh("schtasks", "/End", "/TN", TASK)
        if sh("schtasks", "/Create", "/TN", TASK, "/TR", action, "/SC", "ONLOGON", "/RL", "LIMITED", "/F") != 0:
            return {"ok": False, "error": "schtasks /Create failed"}
        sh("schtasks", "/Run", "/TN", TASK)
    elif OS == "darwin":
        python = shutil.which("python3") or "/usr/bin/python3"
        os.makedirs(os.path.dirname(LOG_PATH), exist_ok=True)
        plist = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>%s</string>
    <key>ProgramArguments</key>
    <array><string>%s</string><string>-I</string><string>%s</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>EnvironmentVariables</key><dict><key>PATH</key><string>%s</string></dict>
    <key>StandardErrorPath</key><string>%s</string>
</dict>
</plist>
""" % (LABEL, xml(python), xml(BIN), xml(path), xml(LOG_PATH))
        write_atomic(BIN, script, 0o755)
        write_atomic(PLIST_PATH, plist, 0o644)
        target = "gui/%d" % os.getuid()
        sh("launchctl", "bootout", "%s/%s" % (target, LABEL))
        if sh("launchctl", "bootstrap", target, PLIST_PATH) != 0:
            return {"ok": False, "error": "launchctl bootstrap failed"}
    else:
        if not DRY and query("systemctl", "--user", "--version") is None:
            return {"ok": False, "error": "systemctl --user is not available"}
        unit = """[Unit]
Description=Bergr push alerts for herdr-core

[Service]
ExecStart=/usr/bin/env python3 -I %%h/.local/bin/bergr-notify
Restart=always
RestartSec=5
Environment=PATH=%s

[Install]
WantedBy=default.target
""" % path
        write_atomic(BIN, script, 0o755)
        write_atomic(UNIT_PATH, unit, 0o644)
        active = query("systemctl", "--user", "is-active", "--quiet", UNIT) == 0
        if sh("systemctl", "--user", "daemon-reload") != 0:
            return {"ok": False, "error": "systemctl --user daemon-reload failed"}
        if sh("systemctl", "--user", "enable", "--now", UNIT) != 0:
            return {"ok": False, "error": "systemctl --user enable failed"}
        if active:
            sh("systemctl", "--user", "restart", UNIT)
        result["linger"] = sh("loginctl", "enable-linger") == 0
    if DRY:
        result["planned"] = planned
    return result


def uninstall():
    if OS == "windows":
        sh("schtasks", "/End", "/TN", TASK)
        sh("schtasks", "/Delete", "/TN", TASK, "/F")
        files = [BIN]
    elif OS == "darwin":
        sh("launchctl", "bootout", "gui/%d/%s" % (os.getuid(), LABEL))
        files = [PLIST_PATH, BIN]
    else:
        sh("systemctl", "--user", "disable", "--now", UNIT)
        files = [UNIT_PATH, BIN]
    for f in files:
        try:
            os.remove(f)
        except OSError:
            pass
    if OS == "linux":
        sh("systemctl", "--user", "daemon-reload")
    result = {"ok": True, "os": OS}
    if DRY:
        result["planned"] = planned
    return result


def main():
    try:
        args = json.loads(base64.b64decode(sys.argv[1]))
        op = args.get("op")
        if op == "status":
            out = status()
        elif op == "install":
            out = install(args.get("script", ""))
        elif op == "uninstall":
            out = uninstall()
        else:
            out = {"ok": False, "error": "unknown op"}
    except Exception as e:  # one JSON line no matter what
        out = {"ok": False, "error": str(e)}
    print(json.dumps(out))


main()
