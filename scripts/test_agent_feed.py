#!/usr/bin/env python3 -I
"""Tests for bergr/Chat/agent-feed.py. Run: python3 -I scripts/test_agent_feed.py"""
import base64, json, os, subprocess, sys, tempfile, time, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "bergr", "Chat", "agent-feed.py")
SOURCE = open(SCRIPT, encoding="utf-8").read()


def load(agent, home, pid="0", cwd="/work", hint="-"):
    """Executes the script as the app does (exec of its source), minus main()."""
    os.environ["HOME"] = home
    old = sys.argv
    sys.argv = ["agent-feed", agent, pid, cwd, hint]
    ns = {"__name__": "agent_feed_test"}
    try:
        exec(compile(SOURCE, SCRIPT, "exec"), ns)
    finally:
        sys.argv = old
    return ns


def write_jsonl(path, rows):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        for r in rows:
            f.write(json.dumps(r) + "\n")


def b64(n):
    return base64.b64encode(b"x" * n).decode()


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()


class ClaudeParse(Base):
    def parse(self, content, kind="assistant"):
        ns = load("claude", self.home)
        return list(ns["Claude"]().parse({"type": kind, "uuid": "u1", "message": {"content": content}}))

    def test_todowrite_is_plan(self):
        todos = [{"content": "A", "status": "completed", "activeForm": "Doing A"},
                 {"content": "B", "status": "in_progress", "activeForm": "Doing B"},
                 {"content": "C", "status": "pending", "activeForm": "Doing C"}]
        evs = self.parse([{"type": "tool_use", "id": "t1", "name": "TodoWrite", "input": {"todos": todos}}])
        self.assertEqual(evs, [{"t": "plan", "id": "plan", "steps": [
            {"text": "A", "status": "completed"}, {"text": "B", "status": "in_progress"},
            {"text": "C", "status": "pending"}]}])

    def test_image_block(self):
        block = {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": b64(100)}}
        evs = self.parse([block], kind="user")
        self.assertEqual(evs, [{"t": "image", "id": "u1.0", "role": "user", "mime": "image/png", "data": b64(100)}])

    def test_oversized_image_skipped(self):
        big = {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": b64(1_500_001)}}
        ok = {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": b64(1_500_000)}}
        self.assertEqual(self.parse([big]), [])
        self.assertEqual(len(self.parse([ok])), 1)


class CodexParse(Base):
    def parse(self, payload):
        ns = load("codex", self.home)
        return list(ns["Codex"]().parse({"type": "response_item", "payload": payload}))

    def test_update_plan_is_plan(self):
        args = json.dumps({"plan": [{"step": "One", "status": "completed"}, {"step": "Two", "status": "in_progress"}]})
        evs = self.parse({"type": "function_call", "name": "update_plan", "call_id": "c1", "arguments": args})
        self.assertEqual(evs, [{"t": "plan", "id": "plan", "steps": [
            {"text": "One", "status": "completed"}, {"text": "Two", "status": "in_progress"}]}])

    def test_input_image(self):
        url = "data:image/jpeg;base64," + b64(50)
        evs = self.parse({"type": "message", "role": "user", "id": "m1",
                          "content": [{"type": "input_image", "image_url": url}]})
        self.assertEqual(evs, [{"t": "image", "id": "m1.img0", "role": "user", "mime": "image/jpeg", "data": b64(50)}])

    def test_oversized_input_image_skipped(self):
        url = "data:image/png;base64," + b64(2_000_000)
        self.assertEqual(self.parse({"type": "message", "role": "user", "id": "m1",
                                     "content": [{"type": "input_image", "image_url": url}]}), [])


class CodexToolImages(Base):
    def parse(self, output):
        parser = load("codex", self.home)["Codex"]()
        return list(parser.parse({"type": "response_item", "payload": {
            "type": "custom_tool_call_output", "id": "result1", "call_id": "call1", "output": output}}))

    def test_code_mode_mixed_output_images_render_as_assistant(self):
        images = [{"type": "input_image", "image_url": "data:image/png;base64," + b64(100)},
                  {"type": "input_image", "image_url": "data:image/jpeg;base64," + b64(200)}]
        events = self.parse([{"type": "input_text", "text": "Screenshot inspected"}, *images])
        self.assertEqual([e["t"] for e in events], ["toolout", "image", "image"])
        self.assertEqual(events[0]["text"], "Screenshot inspected")
        self.assertEqual([e["role"] for e in events[1:]], ["assistant", "assistant"])
        self.assertEqual([e["id"] for e in events[1:]], ["result1.toolimage0", "result1.toolimage1"])

    def test_serialized_result_and_mcp_image(self):
        image = {"type": "image", "mimeType": "image/png", "data": b64(100)}
        events = self.parse(json.dumps({"content": [image]}))
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["mime"], "image/png")
        self.assertEqual(events[0]["data"], b64(100))

    def test_duplicate_large_and_external_images_are_skipped(self):
        image = {"type": "input_image", "image_url": "data:image/png;base64," + b64(100)}
        events = self.parse([image, image,
            {"type": "input_image", "image_url": "data:image/png;base64," + b64(1_500_001)},
            {"type": "input_image", "image_url": "https://example.test/image.png"}])
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["data"], b64(100))


class CodexQuestion(Base):
    def test_request_user_input_becomes_question(self):
        m = load("codex", self.home)
        src = m["Codex"]() if "Codex" in m else None
        line = {"type": "response_item", "payload": {"type": "function_call", "id": "fc1", "call_id": "c1",
                "name": "request_user_input_async",
                "arguments": json.dumps({"questions": [{"title": "Which?", "options": ["Keep", "Commit"]}]})}}
        evs = list(src.parse(line)) if src else []
        self.assertEqual(evs, [{"t": "question", "id": "fc1-q0", "title": "Which?", "options": ["Keep", "Commit"],
                               "async": True, "group": "fc1", "index": 0, "count": 1}])

    def test_freeform_async_question_and_targeted_answer(self):
        m = load("codex", self.home)
        src = m["Codex"]()
        question = {"type": "response_item", "payload": {"type": "function_call", "call_id": "call-test",
                    "name": "functions.request_user_input_async",
                    "arguments": json.dumps({"questions": [{"title": "Where is the file?"}]})}}
        evs = list(src.parse(question))
        self.assertTrue(evs[0]["async"])
        self.assertEqual(evs[0]["options"], [])
        body = json.dumps([{"answer": "src/example.swift", "question": "Where is the file?",
                            "questionItemId": json.dumps(["request_user_input_async", "call-test", 0])}])
        reply = {"type": "response_item", "payload": {"type": "message", "role": "user", "id": "reply-test",
                 "content": [{"type": "input_text", "text": "<send_user_message_question_reply>\n" + body
                               + "\n</send_user_message_question_reply>"}]}}
        answered = list(src.parse(reply))
        self.assertEqual(answered[0]["id"], evs[0]["id"])
        self.assertEqual(answered[0]["answer"], "src/example.swift")
        self.assertEqual(answered[1]["text"], "src/example.swift")

    def test_blocking_question_uses_question_text(self):
        src = load("codex", self.home)["Codex"]()
        evs = list(src.parse({"type": "response_item", "payload": {"type": "function_call", "id": "q",
            "name": "request_user_input", "arguments": json.dumps({"questions": [{"header": "Location",
            "question": "Which file should change?", "options": [{"label": "First"}]}]})}}))
        self.assertEqual(evs[0]["title"], "Which file should change?")


class MemoryCitations(Base):
    def test_folds_into_one_line(self):
        m = load("codex", self.home)
        raw = ("Done.\n\n<oai-mem-citation>\n<citation_entries>\nMEMORY.md:54-58|note=[project test conventions\n"
               "and localhost mock]\n</citation_entries>\n<rollout_ids>\nabc\n</rollout_ids>\n</oai-mem-citation>")
        self.assertEqual(m["memory_citations"](raw), ("Done.", "From memory: project test conventions and localhost mock"))
        self.assertEqual(m["memory_citations"]("plain"), ("plain", None))


class QueuedMessages(Base):
    def test_queue_operations_track_the_queue(self):
        ns = load("claude", self.home)
        c = ns["Claude"]()
        def op(**kw):
            return list(c.parse({"type": "queue-operation", **kw}))
        self.assertEqual(op(operation="enqueue", content="a"), [{"t": "queued", "items": ["a"]}])
        self.assertEqual(op(operation="enqueue", content="b"), [{"t": "queued", "items": ["a", "b"]}])
        self.assertEqual(op(operation="remove", content="b", reason="absorbed_mid_turn"), [{"t": "queued", "items": ["a"]}])
        self.assertEqual(op(operation="dequeue"), [{"t": "queued", "items": []}])
        self.assertEqual(op(operation="dequeue"), [])

    def test_queued_notices_are_hidden_but_keep_their_place(self):
        ns = load("claude", self.home)
        c = ns["Claude"]()
        def op(**kw):
            return list(c.parse({"type": "queue-operation", **kw}))
        self.assertEqual(op(operation="enqueue", content="<task-notification>\n<task-id>x</task-id>"),
                         [{"t": "queued", "items": []}])
        self.assertEqual(op(operation="enqueue", content="mine"), [{"t": "queued", "items": ["mine"]}])
        self.assertEqual(op(operation="dequeue"), [{"t": "queued", "items": ["mine"]}])
        self.assertEqual(op(operation="enqueue", content="<b>bold</b> isn't a notice? it is hidden too"),
                         [{"t": "queued", "items": ["mine"]}])

    def test_mid_turn_message_is_a_user_message(self):
        ns = load("claude", self.home)
        evs = list(ns["Claude"]().parse({"type": "attachment", "uuid": "a1", "attachment": {
            "type": "queued_command", "prompt": "Can you give me the list", "commandMode": "prompt",
            "origin": {"kind": "human"}}}))
        self.assertEqual(evs, [{"t": "msg", "id": "a1.0", "role": "user", "text": "Can you give me the list"}])

    def test_other_attachments_are_skipped(self):
        ns = load("claude", self.home)
        evs = list(ns["Claude"]().parse({"type": "attachment", "uuid": "a2", "attachment": {
            "type": "queued_command", "prompt": "/compact", "commandMode": "bash", "origin": {"kind": "human"}}}))
        self.assertEqual(evs, [])
        evs = list(ns["Claude"]().parse({"type": "attachment", "uuid": "a3", "attachment": {"type": "hook_output"}}))
        self.assertEqual(evs, [])


class ToolResultImages(Base):
    def test_image_a_tool_read_shows_inline(self):
        ns = load("claude", self.home)
        evs = list(ns["Claude"]().parse({"type": "user", "uuid": "r1", "message": {"content": [
            {"type": "tool_result", "tool_use_id": "toolu_9", "content": [
                {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "iVBORw0KGgo="}}]}]}}))
        images = [e for e in evs if e["t"] == "image"]
        self.assertEqual(images, [{"t": "image", "id": "r1.0.0", "role": "assistant", "mime": "image/png",
                                   "data": "iVBORw0KGgo=", "fromTool": True}])


class Backlog(Base):
    PNG = "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAEUlEQVR4nGNgYGD4z8DAwMAAAA0ABftJ5UQAAAAASUVORK5CYII="

    def test_history_sends_placeholders_then_images_newest_first(self):
        ns = load("claude", self.home)
        evs = [{"t": "version", "running": "1", "installed": "3"},
               {"t": "image", "id": "a", "role": "user", "mime": "image/png", "data": self.PNG},
               {"t": "msg", "id": "m"},
               {"t": "image", "id": "b", "role": "assistant", "mime": "image/png", "data": self.PNG, "fromTool": True},
               {"t": "version", "running": "3", "installed": None}]
        head, later = ns["backlog"](evs)
        self.assertEqual([e["t"] for e in head], ["image", "msg", "image", "version"])
        self.assertNotIn("data", head[0])
        self.assertEqual((head[0]["width"], head[0]["height"]), (3, 2))
        self.assertEqual([e["id"] for e in later], ["b", "a"])
        self.assertTrue(all(e["data"] == self.PNG for e in later))

    def test_jpeg_size(self):
        import base64
        ns = load("claude", self.home)
        jpeg = b"\xff\xd8\xff\xe0\x00\x04ab\xff\xc0\x00\x11\x08\x01\x2c\x02\x58\x03"
        self.assertEqual(ns["image_size"](base64.b64encode(jpeg).decode()), (600, 300))


class ClaudeQuestions(Base):
    def test_question_cards_and_their_answers(self):
        ns = load("claude", self.home)
        c = ns["Claude"]()
        q = [{"question": "Pick a color?", "header": "Color", "multiSelect": False,
              "options": [{"label": "Red", "description": "Warm"}, {"label": "Blue", "description": "Cool"}]},
             {"question": "Pick a size?", "header": "Size", "multiSelect": False,
              "options": [{"label": "Small"}, {"label": "Large"}]}]
        evs = list(c.parse({"type": "assistant", "uuid": "a", "message": {"content": [
            {"type": "tool_use", "id": "toolu_q", "name": "AskUserQuestion", "input": {"questions": q}}]}}))
        cards = [e for e in evs if e["t"] == "question"]
        self.assertEqual([(e["id"], e["title"], e["options"], e["index"]) for e in cards],
                         [("toolu_q-q0", "Pick a color?", ["Red", "Blue"], 0), ("toolu_q-q1", "Pick a size?", ["Small", "Large"], 1)])
        self.assertEqual(cards[0]["details"], ["Warm", "Cool"])
        self.assertTrue(all(e["keys"] and "answer" not in e for e in cards))
        evs = list(c.parse({"type": "user", "uuid": "r", "toolUseResult": {"answers": {"Pick a color?": "Blue", "Pick a size?": "Small"}},
                            "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_q", "content": "answered"}]}}))
        answered = {e["id"]: e["answer"] for e in evs if e["t"] == "question"}
        self.assertEqual(answered, {"toolu_q-q0": "Blue", "toolu_q-q1": "Small"})

    def test_declined_question_closes(self):
        ns = load("claude", self.home)
        c = ns["Claude"]()
        list(c.parse({"type": "assistant", "uuid": "a", "message": {"content": [
            {"type": "tool_use", "id": "toolu_x", "name": "AskUserQuestion",
             "input": {"questions": [{"question": "Go?", "options": [{"label": "Yes"}, {"label": "No"}]}]}}]}}))
        evs = list(c.parse({"type": "user", "uuid": "r", "toolUseResult": "Error: rejected",
                            "message": {"content": [{"type": "tool_result", "tool_use_id": "toolu_x", "content": "rejected", "is_error": True}]}}))
        self.assertEqual([e["answer"] for e in evs if e["t"] == "question"], ["Skipped"])


class PastedMessages(Base):
    def test_pasted_reply_is_shown_unwrapped(self):
        ns = load("claude", self.home)
        evs = list(ns["Claude"]().parse({"type": "user", "uuid": "p1", "message": {
            "content": '\n\n<pasted_content id="81b7">\nFirst line\n\n1. Second\n</pasted_content id="81b7">\n'}}))
        self.assertEqual(evs, [{"t": "msg", "id": "p1.0", "role": "user", "text": "First line\n\n1. Second"}])

    def test_text_around_a_paste_is_kept(self):
        ns = load("claude", self.home)
        evs = list(ns["Claude"]().parse({"type": "user", "uuid": "p2", "message": {
            "content": 'Look at this:\n\n<pasted_content id="1">\nerror X\n</pasted_content id="1">\n'}}))
        self.assertEqual(evs[0]["text"], "Look at this:\n\nerror X")

    def test_skill_command_is_the_users_message(self):
        # A skill's slash command starts with <command-message>; dropping it left the reply
        # "queued" in the chat forever, below the answers to it.
        ns = load("claude", self.home)
        evs = list(ns["Claude"]().parse({"type": "user", "uuid": "s1", "message": {"content":
            "<command-message>tools:review</command-message>\n<command-name>/tools:review</command-name>\n"
            "<command-args>do all of these</command-args>"}}))
        self.assertEqual(evs[0]["text"], "/tools:review do all of these")


class ShellCommands(Base):
    def test_bang_command_and_output(self):
        ns = load("claude", self.home)
        c = ns["Claude"]()
        evs = list(c.parse({"type": "user", "uuid": "b1", "message": {"content": "<bash-input>ls -a</bash-input>"}}))
        self.assertEqual(evs, [{"t": "msg", "id": "b1.0", "role": "user", "text": "!ls -a"}])
        evs = list(c.parse({"type": "user", "uuid": "b2", "message": {
            "content": "<bash-stdout>a\nb</bash-stdout><bash-stderr></bash-stderr>"}}))
        self.assertEqual(evs, [{"t": "msg", "id": "b2.0", "role": "assistant", "text": "```\na\nb\n```"}])
        evs = list(c.parse({"type": "user", "uuid": "b3", "message": {
            "content": "<bash-stdout>main -&gt; main &amp; x</bash-stdout>"}}))
        self.assertEqual(evs[0]["text"], "```\nmain -> main & x\n```")


    def test_codex_user_shell_command(self):
        ns = load("codex", self.home)
        text = ("<user_shell_command>\n<command>\necho hi\n</command>\n<result>\nExit code: 0\n"
                "Duration: 0.03 seconds\nOutput:\nhi\n\n</result>\n</user_shell_command>")
        evs = list(ns["Codex"]().parse({"type": "response_item", "payload": {
            "type": "message", "id": "m1", "role": "user", "content": [{"type": "input_text", "text": text}]}}))
        self.assertEqual(evs, [{"t": "msg", "id": "m1", "role": "user", "text": "!echo hi"},
                               {"t": "msg", "id": "m1-out", "role": "assistant", "text": "```\nhi\n```"}])

    def test_codex_failed_command_shows_exit_code(self):
        ns = load("codex", self.home)
        text = ("<user_shell_command><command>false</command><result>\nExit code: 1\nDuration: 0 seconds\n"
                "Output:\n</result></user_shell_command>")
        evs = list(ns["Codex"]().parse({"type": "response_item", "payload": {
            "type": "message", "id": "m2", "role": "user", "content": [{"type": "input_text", "text": text}]}}))
        self.assertEqual(evs[1]["text"], "```\n(exit code 1)\n```")

    def test_antigravity_shell_commands_from_history(self):
        import json as j
        base = os.path.join(self.home, ".gemini", "antigravity-cli")
        os.makedirs(base)
        with open(os.path.join(base, "history.jsonl"), "w") as fh:
            fh.write(j.dumps({"display": "ls", "timestamp": 5000, "workspace": "/work", "type": "shell"}) + "\n")
            fh.write(j.dumps({"display": "hello", "timestamp": 6000, "workspace": "/work"}) + "\n")
            fh.write(j.dumps({"display": "pwd", "timestamp": 7000, "workspace": "/elsewhere", "type": "shell"}) + "\n")
        ns = load("antigravity", self.home)
        evs, offset = ns["Antigravity"]().shell_commands(0)
        self.assertEqual(evs, [{"t": "msg", "id": "h5000", "role": "user", "text": "!ls"}])
        self.assertEqual(ns["Antigravity"]().shell_commands(offset)[0], [])


class ClaudeModels(Base):
    def test_models_from_claude_code_catalog(self):
        import json as j
        d = os.path.join(self.home, ".claude", "cache", "model-catalog")
        os.makedirs(d)
        with open(os.path.join(d, "x-cc.json"), "w") as fh:
            j.dump({"catalog": {"config": {"models": [
                {"id": "claude-fable-5-2", "name": "Fable 5.2", "description": "Toughest", "section": "main",
                 "badge": {"message": "Included until November 16"},
                 "thinking": {"effort_options": [{"id": "low"}, {"id": "high"}]},
                 "runtime": {"default_effort": "high"}},
                {"id": "claude-opus-4-6", "name": "Opus 4.6", "section": "overflow"}]}}}, fh)
        ns = load("claude", self.home)
        self.assertEqual(ns["list_models"](), [{
            "id": "claude-fable-5-2", "name": "Fable 5.2", "description": "Toughest", "efforts": ["low", "high"],
            "note": "Included until November 16", "default_effort": "high"}])

    def test_built_in_list_without_a_catalog(self):
        ns = load("claude", self.home)
        self.assertEqual(ns["list_models"]()[0]["id"], "claude-opus-5-5")


class ClaudeVersion(Base):
    def setUp(self):
        super().setUp()
        import json as j
        for v in ("2.1.300", "2.1.322"):
            os.makedirs(os.path.join(self.home, ".local", "share", "claude", "versions", v))
        d = os.path.join(self.home, ".claude", "cache", "model-catalog")
        os.makedirs(d)
        with open(os.path.join(d, "x-cc.json"), "w") as fh:
            j.dump({"catalog": {"config": {"models": [
                {"id": "claude-fable-5-2", "name": "Fable 5.2", "section": "main", "min_claude_code_version": "2.1.290"},
                {"id": "claude-new", "name": "New", "section": "main", "min_claude_code_version": "2.1.320"}]}}}, fh)

    def version(self, running):
        ns = load("claude", self.home)
        evs = list(ns["Claude"]().parse({"type": "user", "version": running, "uuid": "v", "message": {"content": "hi"}}))
        return evs[0]

    def test_banner_when_a_model_needs_the_installed_version(self):
        self.assertEqual(self.version("2.1.310"),
                         {"t": "version", "running": "2.1.310", "installed": "2.1.322", "needs": ["New"]})

    def test_newer_version_no_model_needs(self):
        self.assertEqual(self.version("2.1.321"),
                         {"t": "version", "running": "2.1.321", "installed": "2.1.322", "needs": []})

    def test_up_to_date(self):
        self.assertEqual(self.version("2.1.322"),
                         {"t": "version", "running": "2.1.322", "installed": None, "needs": []})


class ToolOutput(Base):
    def test_claude_tool_result(self):
        ns = load("claude", self.home)
        rows = "\n".join(f"line {i}" for i in range(30))
        evs = list(ns["Claude"]().parse({"type": "user", "uuid": "u2", "message": {"content": [
            {"type": "tool_result", "tool_use_id": "toolu_1", "content": rows}]}}))
        self.assertEqual(len(evs), 1)
        self.assertEqual(evs[0]["t"], "toolout")
        self.assertEqual(evs[0]["id"], "toolu_1")
        self.assertEqual(evs[0]["text"].split("\n"), [f"line {i}" for i in range(18, 30)])

    def test_claude_block_list_result(self):
        ns = load("claude", self.home)
        evs = list(ns["Claude"]().parse({"type": "user", "uuid": "u2", "message": {"content": [
            {"type": "tool_result", "tool_use_id": "t", "content": [{"type": "text", "text": "ok"}]}]}}))
        self.assertEqual(evs, [{"t": "toolout", "id": "t", "text": "ok"}])

    def test_empty_result_skipped(self):
        ns = load("claude", self.home)
        self.assertEqual(list(ns["Claude"]().parse({"type": "user", "uuid": "u", "message": {"content": [
            {"type": "tool_result", "tool_use_id": "t", "content": "  \n"}]}})), [])

    def test_char_limit(self):
        ns = load("claude", self.home)
        tail = ns["tool_tail"]("x" * 5000)
        self.assertEqual(len(tail), 1200)

    def test_codex_output_matches_call(self):
        ns = load("codex", self.home)
        c = ns["Codex"]()
        call = list(c.parse({"type": "response_item", "payload": {
            "type": "function_call", "id": "fc_1", "call_id": "call_1", "name": "shell", "arguments": "{}"}}))
        self.assertEqual(call[0]["id"], "fc_1")
        out = list(c.parse({"type": "response_item", "payload": {
            "type": "function_call_output", "call_id": "call_1", "output": json.dumps({"output": "a\nb"})}}))
        self.assertEqual(out, [{"t": "toolout", "id": "fc_1", "text": "a\nb"}])

    def test_codex_code_mode_call_shows_the_command(self):
        ns = load("codex", self.home)
        src = 'text(await tools.exec_command({cmd:"python3 - <<\'PY\'\\nprint(1)\\nPY", yield_time_ms:1000}))'
        ev = list(ns["Codex"]().parse({"type": "response_item", "payload": {
            "type": "custom_tool_call", "id": "ct1", "call_id": "c1", "name": "exec", "input": src}}))
        self.assertEqual(ev[0]["name"], "exec_command")
        self.assertTrue(ev[0]["summary"].startswith("python3 - <<'PY'"), ev[0]["summary"])
        self.assertNotIn("tools.", ev[0]["summary"])

    def test_codex_custom_output_plain(self):
        ns = load("codex", self.home)
        out = list(ns["Codex"]().parse({"type": "response_item", "payload": {
            "type": "custom_tool_call_output", "call_id": "c9", "output": "done"}}))
        self.assertEqual(out, [{"t": "toolout", "id": "c9", "text": "done"}])


class HintLookup(Base):
    def old(self, path, rows=({"type": "user"},)):
        write_jsonl(path, rows)
        past = time.time() - 3600
        os.utime(path, (past, past))

    def test_claude_hint_older_than_process(self):
        path = os.path.join(self.home, ".claude", "projects", "-work", "abc-123.jsonl")
        self.old(path)
        ns = load("claude", self.home, hint="abc-123")
        ns["STARTED"] = time.time() - 60  # the process started after the file was last written
        self.assertEqual(ns["Claude"]().locate(), path)

    def test_claude_pid_file_wins_over_hint(self):
        other = os.path.join(self.home, ".claude", "projects", "-work", "other.jsonl")
        hinted = os.path.join(self.home, ".claude", "projects", "-work", "hinted.jsonl")
        write_jsonl(other, [{}])
        write_jsonl(hinted, [{}])
        write_jsonl(os.path.join(self.home, ".claude", "sessions", "4242.json"), [])
        with open(os.path.join(self.home, ".claude", "sessions", "4242.json"), "w") as f:
            json.dump({"sessionId": "other", "cwd": "/work"}, f)
        ns = load("claude", self.home, pid="4242", hint="hinted")
        ns["descendants"] = lambda pid: [pid]
        self.assertEqual(ns["Claude"]().locate(), other)

    def test_claude_no_hint_stale_file_not_found(self):
        self.old(os.path.join(self.home, ".claude", "projects", "-work", "abc-123.jsonl"))
        ns = load("claude", self.home)
        ns["STARTED"] = time.time() - 60
        self.assertIsNone(ns["Claude"]().locate())

    def test_codex_hint_older_than_process(self):
        path = os.path.join(self.home, ".codex", "sessions", "2026", "01", "02", "rollout-2026-01-02T03-04-05-abc-123.jsonl")
        self.old(path)
        ns = load("codex", self.home, hint="abc-123")
        ns["STARTED"] = time.time() - 60
        ns["open_files"] = lambda pids: []
        self.assertEqual(ns["Codex"]().locate(), path)

    def test_hint_with_glob_chars_ignored(self):
        ns = load("claude", self.home, hint="*")
        self.assertIsNone(ns["HINT"])


def codex_meta_row(**kw):
    payload = {"id": "x", "timestamp": "2026-01-02T03:00:00Z", "cwd": "/work"}
    payload.update(kw)
    return {"type": "session_meta", "payload": payload}


class CodexSubagents(Base):
    def setUp(self):
        super().setUp()
        self.day = os.path.join(self.home, ".codex", "sessions", "2026", "01", "02")
        self.main = os.path.join(self.day, "rollout-2026-01-02T03-00-00-main.jsonl")
        write_jsonl(self.main, [codex_meta_row(id="main", thread_source="user"),
                                {"type": "response_item", "timestamp": "2026-01-02T03:00:05Z", "payload": {
                                    "type": "function_call", "id": "fc_spawn", "call_id": "c1",
                                    "name": "spawn_agent", "arguments": "{}"}}])
        past = time.time() - 600
        os.utime(self.main, (past, past))
        # Newer than the main thread: a forked sub-agent and a guardian review.
        self.child = os.path.join(self.day, "rollout-2026-01-02T03-00-10-child.jsonl")
        write_jsonl(self.child, [
            codex_meta_row(id="child", timestamp="2026-01-02T03:00:10Z", thread_source="subagent",
                           forked_from_id="main", agent_nickname="Hubble",
                           source={"subagent": {"thread_spawn": {"parent_thread_id": "main"}}}),
            {"type": "response_item", "payload": {"type": "function_call", "name": "shell", "call_id": "k1"}},
            {"type": "response_item", "payload": {"type": "message", "role": "assistant",
                                                  "content": [{"type": "output_text", "text": "a\nChecked it"}]}}])
        self.guardian = os.path.join(self.day, "rollout-2026-01-02T03-00-20-guard.jsonl")
        write_jsonl(self.guardian, [codex_meta_row(id="guard", thread_source="guardian_review",
                                                   source={"subagent": "guardian_review"})])

    def test_main_never_switches_to_a_child(self):
        ns = load("codex", self.home)
        ns["STARTED"] = 0
        ns["open_files"] = lambda pids: []
        self.assertEqual(ns["Codex"]().locate(), self.main)
        ns["open_files"] = lambda pids: [self.child, self.guardian]
        self.assertEqual(ns["Codex"]().locate(), self.main)

    def test_is_main_rules(self):
        ns = load("codex", self.home)
        is_main = ns["codex_is_main"]
        self.assertTrue(is_main({}))
        self.assertTrue(is_main({"thread_source": "user"}))
        self.assertFalse(is_main({"thread_source": "user", "parent_thread_id": "p"}))
        self.assertFalse(is_main({"forked_from_id": "p"}))
        self.assertFalse(is_main({"thread_source": "subagent"}))
        self.assertFalse(is_main({"source": {"subagent": {}}}))

    def test_subagent_event_with_nickname_and_anchor(self):
        ns = load("codex", self.home)
        c = ns["Codex"]()
        for d in [json.loads(l) for l in open(self.main)]:
            list(c.parse(d))
        tracks = c.subagents(self.main)
        self.assertEqual([t.id for t in tracks], ["child"])  # the guardian never surfaces
        ev = tracks[0].event()
        self.assertEqual(ev, {"t": "subagent", "id": "child", "parent": "fc_spawn", "name": "Hubble",
                              "kind": "codex", "state": "running", "steps": 1, "summary": "Checked it"})
        self.assertIsNone(tracks[0].event())  # unchanged: nothing to send

    def test_done_after_wait_agent_result(self):
        ns = load("codex", self.home)
        c = ns["Codex"]()
        list(c.parse({"type": "response_item", "payload": {"type": "function_call", "name": "wait_agent",
                                                           "call_id": "w1", "arguments": "{}"}}))
        list(c.parse({"type": "response_item", "payload": {"type": "function_call_output", "call_id": "w1",
                                                           "output": "{\"status\": {\"child\": \"done\"}}"}}))
        tr = c.subagents(self.main)[0]
        self.assertEqual(tr.event()["state"], "done")


class ClaudeSubagents(Base):
    def setUp(self):
        super().setUp()
        self.proj = os.path.join(self.home, ".claude", "projects", "-work")
        self.main = os.path.join(self.proj, "sess.jsonl")
        write_jsonl(self.main, [{"type": "user"}])
        self.dir = os.path.join(self.proj, "sess", "subagents")

    def child(self, aid, tool_use, rows, quiet=0):
        path = os.path.join(self.dir, f"agent-{aid}.jsonl")
        write_jsonl(path, rows)
        with open(path[:-6] + ".meta.json", "w") as f:
            json.dump({"agentType": "Explore", "description": "Find things", "toolUseId": tool_use}, f)
        if quiet:
            os.utime(path, (time.time() - quiet, time.time() - quiet))
        return path

    ROWS = [{"type": "user", "isSidechain": True, "message": {"content": "go"}},
            {"type": "assistant", "isSidechain": True, "message": {"content": [
                {"type": "tool_use", "id": "x", "name": "Read", "input": {}},
                {"type": "text", "text": "first\nSecond line"}]}}]

    def parent_result(self, c, tool_use, is_async):
        list(c.parse({"type": "user", "uuid": "r", "toolUseResult": {"isAsync": is_async, "status": "completed"},
                      "message": {"content": [{"type": "tool_result", "tool_use_id": tool_use, "content": "ok"}]}}))

    def test_running(self):
        self.child("a1", "toolu_1", self.ROWS)
        c = load("claude", self.home)["Claude"]()
        ev = c.subagents(self.main)[0].event()
        self.assertEqual(ev, {"t": "subagent", "id": "a1", "parent": "toolu_1", "name": "Find things",
                              "kind": "Explore", "state": "running", "steps": 1, "summary": "Second line"})

    def test_sync_done_with_parent_result(self):
        self.child("a1", "toolu_1", self.ROWS)
        c = load("claude", self.home)["Claude"]()
        self.parent_result(c, "toolu_1", False)
        self.assertEqual(c.subagents(self.main)[0].event()["state"], "done")

    def test_async_running_until_quiet(self):
        self.child("a1", "toolu_1", self.ROWS)
        c = load("claude", self.home)["Claude"]()
        self.parent_result(c, "toolu_1", True)
        self.assertEqual(c.subagents(self.main)[0].event()["state"], "running")
        self.child("a2", "toolu_2", self.ROWS, quiet=120)
        self.parent_result(c, "toolu_2", True)
        states = {t.id: (t.event() or t.last)["state"] for t in c.subagents(self.main)}
        self.assertEqual(states, {"a1": "running", "a2": "done"})

    def test_sidechain_never_in_main_feed(self):
        c = load("claude", self.home)["Claude"]()
        self.assertEqual(list(c.parse(self.ROWS[1])), [])

    def test_old_subagents_ignored(self):
        self.child("a1", "toolu_1", self.ROWS, quiet=7 * 3600)
        c = load("claude", self.home)["Claude"]()
        self.assertEqual(c.subagents(self.main), [])


class AsTheAppRunsIt(Base):
    def test_exec_with_argv(self):
        os.makedirs(os.path.join(self.home, ".claude", "projects", "-work"))
        path = os.path.join(self.home, ".claude", "projects", "-work", "sess-1.jsonl")
        write_jsonl(path, [{"type": "user", "uuid": "u", "message": {"content": "hello"}}])
        enc = base64.b64encode(SOURCE.encode()).decode()
        cmd = [sys.executable, "-I", "-c", "import base64,sys;exec(base64.b64decode(sys.argv.pop(1)))",
               enc, "claude", "0", "/work", "sess-1"]
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                             env={"HOME": self.home, "PATH": os.environ.get("PATH", "")})
        time.sleep(2)
        p.kill()
        out, err = p.communicate()
        lines = [json.loads(l) for l in out.splitlines() if l.strip()]
        self.assertTrue(any(l.get("t") == "reset" and l.get("session") == "sess-1.jsonl" for l in lines), (out, err))
        self.assertTrue(any(l.get("t") == "msg" and l.get("text") == "hello" for l in lines), (out, err))



class PluginCommandsTests(unittest.TestCase):
    def test_layouts_enabled_and_newest(self):
        with tempfile.TemporaryDirectory() as home:
            def skill(path, desc="d"):
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w") as fh:
                    fh.write(f"---\nname: x\ndescription: {desc}\n---\n")
            cache = os.path.join(home, ".claude", "plugins", "cache")
            skill(os.path.join(cache, "m1", "flat", "v1", "delegating", "SKILL.md"))
            skill(os.path.join(cache, "m2", "nested", "1.0", "skills", "group", "wait-what", "SKILL.md"))
            skill(os.path.join(cache, "m2", "nested", "0.9", "skills", "group", "old-only", "SKILL.md"))
            skill(os.path.join(cache, "m3", "off", "v1", "skills", "hidden", "SKILL.md"))
            old = os.path.join(cache, "m2", "nested", "0.9")
            os.utime(old, (1, 1))
            with open(os.path.join(home, ".claude", "settings.json"), "w") as fh:
                json.dump({"enabledPlugins": {"flat@m1": True, "nested@m2": True, "off@m3": False}}, fh)
            ns = load("claude", home)
            names = [n for n, _ in ns["plugin_commands"]()]
            self.assertEqual(sorted(names), ["/flat:delegating", "/nested:wait-what"])

class LocalFeedStartup(Base):
    def test_models_and_usage_arrive_through_local_process(self):
        # The native Mac launches exactly this -I/-c bridge, without an SSH shell.
        catalog = os.path.join(self.home, ".codex", "models_cache.json")
        os.makedirs(os.path.dirname(catalog), exist_ok=True)
        with open(catalog, "w") as fh:
            json.dump({"models": [{"slug": "test-model", "display_name": "Test Model",
                                   "visibility": "list"}]}, fh)
        rollout = os.path.join(self.home, ".codex", "sessions", "2026", "11", "11", "rollout-test.jsonl")
        write_jsonl(rollout, [
            {"type": "session_meta", "payload": {"id": "test", "cwd": "/work", "source": "cli"}},
            {"type": "turn_context", "payload": {"model": "test-model", "effort": "high"}},
            {"type": "event_msg", "payload": {"type": "token_count", "info": {
                "last_token_usage": {"total_tokens": 1234}, "model_context_window": 100000}}},
        ])
        encoded = base64.b64encode(SOURCE.encode()).decode()
        command = "import base64,sys;exec(base64.b64decode(sys.argv.pop(1)))"
        environment = dict(os.environ, HOME=self.home)
        process = subprocess.Popen([sys.executable, "-I", "-c", command, encoded, "codex", "0", "/work", "test"],
                                   env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            stdout, stderr = process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            process.terminate()
            stdout, stderr = process.communicate(timeout=3)
        events = [json.loads(line) for line in stdout.splitlines()]
        self.assertTrue(any(ev.get("t") == "models" and ev.get("items", [{}])[0].get("id") == "test-model"
                            for ev in events), stderr)
        self.assertTrue(any(ev.get("t") == "usage" and ev.get("used") == 1234
                            and ev.get("model") == "test-model" for ev in events), stderr)


if __name__ == "__main__":
    unittest.main()
