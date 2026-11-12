#!/usr/bin/env python3 -I
"""Tests for bergr/Chat/recent-sessions.py. Run: python3 -I scripts/test_recent_sessions.py"""
import json, os, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "bergr", "Chat", "recent-sessions.py")
NS = {"__name__": "recent_test"}
exec(compile(open(SCRIPT, encoding="utf-8").read(), SCRIPT, "exec"), NS)


def write(path, rows, mtime):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, separators=(",", ":")) + "\n")
    os.utime(path, (mtime, mtime))


def claude_rows(first, n=2):
    rows = [{"type": "user", "isMeta": True, "message": {"role": "user", "content": "<local-command-caveat>x"}},
            {"type": "user", "message": {"role": "user", "content": first}}]
    for _ in range(n):
        rows.append({"type": "assistant", "message": {"role": "assistant", "content": []}})
    return rows


def codex_rows(sid, cwd, first, n=1):
    rows = [{"type": "session_meta", "payload": {"id": sid, "cwd": cwd}},
            {"type": "event_msg", "payload": {"type": "user_message", "message": first}}]
    for _ in range(n):
        rows.append({"type": "event_msg", "payload": {"type": "agent_message", "message": "ok"}})
    return rows


class Recent(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def test_claude_titles_order_and_counts(self):
        d = os.path.join(self.home, ".claude", "projects", "-work-app")
        write(os.path.join(d, "old.jsonl"), claude_rows("first old"), 1000)
        write(os.path.join(d, "new.jsonl"), claude_rows([{"type": "text", "text": "fix the\nbug  now"}], 3), 2000)
        write(os.path.join(self.home, ".claude", "projects", "-other", "x.jsonl"), claude_rows("nope"), 3000)
        got = NS["recent"]("claude", "/work/app", self.home)
        self.assertEqual([g["id"] for g in got], ["new", "old"])
        self.assertEqual(got[0]["title"], "fix the bug now")
        self.assertEqual(got[0]["count"], 4)
        self.assertEqual(got[1]["title"], "first old")

    def test_title_capped_at_80(self):
        d = os.path.join(self.home, ".claude", "projects", "-w")
        write(os.path.join(d, "a.jsonl"), claude_rows("x" * 200), 1)
        title = NS["recent"]("claude", "/w", self.home)[0]["title"]
        self.assertEqual(len(title), 80)
        self.assertTrue(title.endswith("\u2026"))

    def test_cap_of_20(self):
        d = os.path.join(self.home, ".claude", "projects", "-w")
        for i in range(25):
            write(os.path.join(d, "s%02d.jsonl" % i), claude_rows("m%d" % i), 1000 + i)
        got = NS["recent"]("claude", "/w", self.home)
        self.assertEqual(len(got), 20)
        self.assertEqual(got[0]["id"], "s24")

    def test_windows_path_key(self):
        d = os.path.join(self.home, ".claude", "projects", "C--Users-me-app")
        write(os.path.join(d, "w.jsonl"), claude_rows("win"), 5)
        self.assertEqual(len(NS["recent"]("claude", "C:\\Users\\me\\app", self.home)), 1)
        # A drive letter's case differs between shells.
        self.assertEqual(len(NS["recent"]("claude", "c:\\Users\\me\\app", self.home)), 1)

    def test_codex_matches_cwd(self):
        base = os.path.join(self.home, ".codex", "sessions", "2026", "11", "01")
        write(os.path.join(base, "rollout-a.jsonl"), codex_rows("id-a", "/work/app", "<environment_context>"), 10)
        write(os.path.join(base, "rollout-b.jsonl"), codex_rows("id-b", "/work/app/", "add tests", 2), 20)
        write(os.path.join(base, "rollout-c.jsonl"), codex_rows("id-c", "/elsewhere", "no"), 30)
        got = NS["recent"]("codex", "/work/app", self.home)
        self.assertEqual([g["id"] for g in got], ["id-b", "id-a"])
        self.assertEqual(got[0]["title"], "add tests")
        self.assertEqual(got[0]["count"], 3)
        self.assertEqual(got[1]["title"], "")

    def test_codex_windows_cwd(self):
        base = os.path.join(self.home, ".codex", "sessions", "2026", "11", "01")
        write(os.path.join(base, "rollout-w.jsonl"), codex_rows("id-w", "C:\\Users\\Me\\app", "hi"), 10)
        self.assertEqual(len(NS["recent"]("codex", "c:/users/me/app", self.home)), 1)

    def test_nothing(self):
        self.assertEqual(NS["recent"]("claude", "/none", self.home), [])
        self.assertEqual(NS["recent"]("codex", "/none", self.home), [])
        self.assertEqual(NS["recent"]("agy", "/none", self.home), [])


if __name__ == "__main__":
    unittest.main()
