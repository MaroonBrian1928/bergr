import importlib.util, json, os, tempfile, time, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "st", os.path.join(HERE, "..", "bergr", "Chat", "search-transcripts.py"))
st = importlib.util.module_from_spec(spec)
spec.loader.exec_module(st)


def write(path, rows, mtime):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")
    os.utime(path, (mtime, mtime))


def claude(role, content, sid="s1"):
    return {"type": role, "sessionId": sid, "cwd": "/w/app", "timestamp": "2026-01-01T00:00:00Z",
            "message": {"role": role, "content": content}}


def codex(role, text):
    kind = "input_text" if role == "user" else "output_text"
    return {"type": "response_item", "timestamp": "t",
            "payload": {"type": "message", "role": role, "content": [{"type": kind, "text": text}]}}


class SearchTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        now = time.time()
        write(os.path.join(self.home, ".claude/projects/p/a.jsonl"), [
            claude("user", "How do I fix the flux capacitor?", "a"),
            claude("assistant", [{"type": "text", "text": "Replace the flux capacitor fuse first."}], "a"),
        ], now - 100)
        write(os.path.join(self.home, ".claude/projects/p/b.jsonl"), [
            claude("user", "unrelated", "b"),
            claude("assistant", [{"type": "tool_use", "name": "Bash", "input": {"command": "grep zebra"}}], "b"),
            claude("user", [{"type": "tool_result", "content": "zebra output"}], "b"),
            claude("assistant", [{"type": "thinking", "thinking": "zebra"}], "b"),
        ], now - 50)
        write(os.path.join(self.home, ".codex/sessions/2026/01/rollout-1.jsonl"), [
            {"type": "session_meta", "payload": {"id": "cx1", "cwd": "/w/codex"}},
            codex("user", "<environment_context>zebra</environment_context>"),
            codex("user", "Please add a zebra crossing"),
        ], now - 10)

    def test_text_only_not_tool_noise(self):
        r = st.search("zebra", self.home)
        self.assertEqual([h["agent"] for h in r["hits"]], ["codex"])
        self.assertEqual(r["hits"][0]["session"], "cx1")
        self.assertEqual(r["hits"][0]["cwd"], "/w/codex")

    def test_snippet_and_title(self):
        r = st.search("FLUX", self.home)
        self.assertEqual(len(r["hits"]), 1)
        h = r["hits"][0]
        self.assertIn("flux capacitor", h["snippet"].lower())
        self.assertEqual(h["title"], "How do I fix the flux capacitor?")
        self.assertEqual(h["session"], "a")

    def test_newest_first(self):
        write(os.path.join(self.home, ".claude/projects/p/c.jsonl"),
              [claude("user", "zebra again", "c")], time.time())
        r = st.search("zebra", self.home)
        self.assertEqual([h["session"] for h in r["hits"]], ["c", "cx1"])

    def test_cap(self):
        for i in range(40):
            write(os.path.join(self.home, ".claude/projects/q/%d.jsonl" % i),
                  [claude("user", "needle %d" % i, "n%d" % i)], time.time() + i)
        r = st.search("needle", self.home)
        self.assertEqual(len(r["hits"]), 30)
        self.assertTrue(r["truncated"])
        self.assertEqual(r["hits"][0]["session"], "n39")

    def test_empty_query_and_time_budget(self):
        self.assertEqual(st.search("  ", self.home)["hits"], [])
        self.assertTrue(st.search("zebra", self.home, budget=-1)["truncated"])


if __name__ == "__main__":
    unittest.main()
