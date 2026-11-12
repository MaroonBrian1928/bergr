# Stage 2 of Bergr's chat helper launch. The command line carries only a tiny stage 1 that execs
# the first line of stdin; that line defines D (JSON: sha, argv) and execs this file. It runs the
# helper cached as <cache>/agent-feed-<sha>.py, or asks the app for the source ({"t":"need-source"},
# answered with one base64 line), verifies its SHA-256, caches it atomically and runs it.
# Bergr compresses nothing here on purpose: it must stay small and boring.
import base64, glob, hashlib, os, sys

sys.stdout.reconfigure(encoding="utf-8", newline=chr(10))
sys.stderr.reconfigure(encoding="utf-8")
_sha = D["sha"]
if os.name == "nt":
    _dir = os.path.join(os.environ.get("LOCALAPPDATA") or os.path.expanduser("~"), "bergr", "cache")
else:
    _dir = os.path.join(os.path.expanduser("~"), ".cache", "bergr")
_path = os.path.join(_dir, "agent-feed-" + _sha + ".py")
_src = None
try:
    with open(_path, "rb") as _f:
        _b = _f.read()
    if hashlib.sha256(_b).hexdigest() == _sha:
        _src = _b
except OSError:
    pass
if _src is None:
    sys.stdout.write('{"t":"need-source"}\n')
    sys.stdout.flush()
    try:
        _b = base64.b64decode(sys.stdin.buffer.readline())
    except Exception:
        _b = b""
    if hashlib.sha256(_b).hexdigest() != _sha:
        sys.stdout.write('{"t":"error","text":"The chat helper arrived damaged."}\n')
        sys.stdout.flush()
        sys.exit(1)
    try:
        os.makedirs(_dir, exist_ok=True)
        _tmp = _path + "." + str(os.getpid()) + ".tmp"
        with open(_tmp, "wb") as _f:
            _f.write(_b)
        os.replace(_tmp, _path)
        _old = sorted(glob.glob(os.path.join(_dir, "agent-feed-*.py")), key=os.path.getmtime, reverse=True)
        for _p in _old[3:]:
            try:
                os.remove(_p)
            except OSError:
                pass
    except OSError:
        pass  # no cache: run from memory
    _src = _b
sys.argv = D["argv"]
exec(compile(_src, "agent-feed.py", "exec"))
