#!/usr/bin/env python3 -I
"""Tests for bergr/Push/bergr-notify.py. Run: python3 -I scripts/test_bergr_notify.py"""
import base64, importlib.util, json, os, subprocess, tempfile, unittest, urllib.error
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "bergr", "Push", "bergr-notify.py")
spec = importlib.util.spec_from_file_location("bergr_notify", SCRIPT)
notify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(notify)


def term(addr="t1", state="blocked", turn=5, seen=None, notify=True, app="claude-code",
         msg="needs approval", kind="permission", where="~ / 1", title="Herdrdev board"):
    labels = {"where": where}
    if seen is not None:
        labels["herdr.seen"] = str(seen)
    status = None if state is None else {"app": app, "msg": msg, "state": state, "kind": kind}
    return {"address": addr, "cwd": "/Users/me", "labels": labels, "notify": notify,
            "state": "live", "status": status, "title": title, "turn": turn}


def line(*terms):
    return json.dumps({"terminals": list(terms)})


def b64decode(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def raw_to_der(raw):
    def integer(b):
        b = b.lstrip(b"\0") or b"\0"
        if b[0] & 0x80:
            b = b"\0" + b
        return b"\x02" + bytes([len(b)]) + b
    body = integer(raw[:32]) + integer(raw[32:])
    return b"\x30" + bytes([len(body)]) + body


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name

    def tearDown(self):
        self.tmp.cleanup()

    def make_key(self):
        key = os.path.join(self.dir, "key.pem")
        pub = os.path.join(self.dir, "pub.pem")
        subprocess.run(["openssl", "ecparam", "-genkey", "-name", "prime256v1", "-out", key],
                       check=True, capture_output=True)
        subprocess.run(["openssl", "ec", "-in", key, "-pubout", "-out", pub],
                       check=True, capture_output=True)
        return key, pub

    def verify(self, pub, data, der):
        data_path = os.path.join(self.dir, "data.bin")
        sig_path = os.path.join(self.dir, "sig.der")
        with open(data_path, "wb") as f:
            f.write(data)
        with open(sig_path, "wb") as f:
            f.write(der)
        res = subprocess.run(["openssl", "dgst", "-sha256", "-verify", pub, "-signature", sig_path, data_path],
                             capture_output=True)
        return res.returncode == 0


class Alerts(Base):
    def test_first_line_no_alert(self):
        state, alerts = notify.alerts_for(None, line(term(state="blocked", turn=5)))
        self.assertEqual(alerts, [])
        self.assertEqual(state["last"], {"t1": ("blocked", 5)})

    def test_working_to_blocked_alerts(self):
        state, _ = notify.alerts_for(None, line(term(state="working", turn=5)))
        state, alerts = notify.alerts_for(state, line(term(state="blocked", turn=5)))
        self.assertEqual(len(alerts), 1)
        self.assertEqual(alerts[0]["address"], "t1")
        self.assertEqual(alerts[0]["title"], "Claude needs you")
        self.assertEqual(alerts[0]["body"], "~ / 1 — needs approval (permission)")

    def test_blocked_permission_carries_question(self):
        state, _ = notify.alerts_for(None, line(term(state="working", turn=5)))
        _, alerts = notify.alerts_for(state, line(term(state="blocked", turn=5)))
        self.assertEqual(alerts[0]["q"], {"title": "needs approval", "options": ["Yes", "No"], "keys": True})

    def test_other_alerts_carry_no_question(self):
        state, _ = notify.alerts_for(None, line(term(state="working", turn=5)))
        _, alerts = notify.alerts_for(state, line(term(state="blocked", turn=5, kind="question")))
        self.assertNotIn("q", alerts[0])
        for end in ("done", "error"):
            state, _ = notify.alerts_for(None, line(term(state="working", turn=5)))
            _, alerts = notify.alerts_for(state, line(term(state=end, turn=5)))
            self.assertEqual(len(alerts), 1)
            self.assertNotIn("q", alerts[0])

    def test_question_is_encrypted_with_the_alert(self):
        import base64
        key = bytes(range(64))
        q = {"title": "Run it?", "options": ["Yes", "No"], "keys": True}
        dev = {"relay": "https://r.example", "secret": "s", "key": base64.b64encode(key).decode()}
        _, _, data = notify.relay_request(dev, "T", "B", "t1", "pop", "blocked", q)
        self.assertNotIn(b"Run it", data)
        blob = base64.b64decode(json.loads(data)["e"])
        self.assertEqual(notify.decrypt_alert(key, blob)["q"], q)
        _, _, data = notify.relay_request(dev, "T", "B", "t1", "pop", "done")
        self.assertNotIn("q", notify.decrypt_alert(key, base64.b64decode(json.loads(data)["e"])))

    def test_dangerous_command_gets_no_approve_buttons(self):
        for cmd in ("rm -rf /tmp/x", "git push --force origin main", "sudo apt install x"):
            state, _ = notify.alerts_for(None, line(term(state="working", turn=5)))
            _, alerts = notify.alerts_for(state, line(term(state="blocked", turn=5, msg="Bash: " + cmd)))
            self.assertEqual(len(alerts), 1)
            self.assertNotIn("q", alerts[0], cmd)
        state, _ = notify.alerts_for(None, line(term(state="working", turn=5)))
        _, alerts = notify.alerts_for(state, line(term(state="blocked", turn=5, msg="Bash: rm file")))
        self.assertIn("q", alerts[0])

    def test_dangerous_patterns(self):
        yes = ["rm -rf build", "rm -fr /", "rm -r -f x", "rm -Rf x", "git push --force", "git push -f origin x",
               "git push origin main --force-with-lease", "git reset --hard HEAD~1", "git clean -fd", "sudo rm x",
               "mkfs.ext4 /dev/sda1", "dd if=/dev/zero of=/dev/sda", "DROP TABLE users", "drop database x",
               "TRUNCATE users", "chmod -R 777 /srv", "echo x > /dev/sda", "rails db:migrate:reset",
               "prisma migrate reset", "artisan migrate:rollback"]
        no = ["rm file", "rm -f file", "rm -r dir", "git push", "git push -u origin main", "git reset HEAD file",
              "git clean -n", "pseudo sudoku", "chmod 755 x", "chmod -R 755 x", "dd of=x", "migrate up",
              "output truncated", "ls > /dev/null", "git push --follow-tags"]
        for t in yes:
            self.assertIsNotNone(notify.dangerous_reason(t), t)
        for t in no:
            self.assertIsNone(notify.dangerous_reason(t), t)

    def test_done_body_is_last_two_sentences_under_limit(self):
        msg = "First thing. Second thing. Third thing! Final bit done."
        _, body = notify.format_alert(term(state="done", msg=msg), "done")
        self.assertTrue(body.endswith("Third thing! Final bit done."))
        self.assertNotIn("First", body)
        _, body = notify.format_alert(term(state="done", msg="word " * 100 + "end."), "done")
        self.assertLessEqual(len(body), notify.BODY_MAX)
        self.assertTrue(body.endswith("end."))

    def test_same_turn_not_repeated(self):
        state, _ = notify.alerts_for(None, line(term(state="working", turn=5)))
        state, alerts = notify.alerts_for(state, line(term(state="blocked", turn=5)))
        self.assertEqual(len(alerts), 1)
        state, _ = notify.alerts_for(state, line(term(state="working", turn=5)))
        state, alerts = notify.alerts_for(state, line(term(state="blocked", turn=5)))
        self.assertEqual(alerts, [])

    def test_new_turn_alerts_again(self):
        state, _ = notify.alerts_for(None, line(term(state="working", turn=5)))
        state, _ = notify.alerts_for(state, line(term(state="blocked", turn=5)))
        state, _ = notify.alerts_for(state, line(term(state="working", turn=6)))
        state, alerts = notify.alerts_for(state, line(term(state="blocked", turn=6)))
        self.assertEqual(len(alerts), 1)
        self.assertEqual(alerts[0]["turn"], 6)

    def test_notify_false_suppressed(self):
        state, _ = notify.alerts_for(None, line(term(state="working", turn=5, notify=False)))
        state, alerts = notify.alerts_for(state, line(term(state="blocked", turn=5, notify=False)))
        self.assertEqual(alerts, [])

    def test_seen_turn_suppressed(self):
        state, _ = notify.alerts_for(None, line(term(state="working", turn=5, seen=5)))
        state, alerts = notify.alerts_for(state, line(term(state="blocked", turn=5, seen=5)))
        self.assertEqual(alerts, [])
        state, _ = notify.alerts_for(state, line(term(state="working", turn=6, seen=5)))
        state, alerts = notify.alerts_for(state, line(term(state="done", turn=6, seen=5, kind=None)))
        self.assertEqual(len(alerts), 1)

    def test_bad_seen_label_counts_as_unseen(self):
        state, _ = notify.alerts_for(None, line(term(state="working", turn=5)))
        state, alerts = notify.alerts_for(state, line(term(state="blocked", turn=5, seen="abc")))
        self.assertEqual(len(alerts), 1)

    def test_error_alerts_once_with_machine_in_title(self):
        state, _ = notify.alerts_for(None, line(term(state="working")), "pop")
        state, alerts = notify.alerts_for(state, line(term(state="error", msg="crashed")), "pop")
        self.assertEqual([a["title"] for a in alerts], ["Claude hit an error on pop"])
        self.assertEqual(alerts[0]["state"], "error")
        _, again = notify.alerts_for(state, line(term(state="error", msg="crashed")), "pop")
        self.assertEqual(again, [])

    def test_titles_name_the_machine(self):
        self.assertEqual(notify.format_alert(term(state="blocked"), "blocked", "pop")[0], "Claude needs you on pop")
        self.assertEqual(notify.format_alert(term(state="done"), "done", "pop")[0], "Claude finished on pop")

    def test_done_alert_text(self):
        state, _ = notify.alerts_for(None, line(term(state="working", turn=3)))
        state, alerts = notify.alerts_for(state, line(term(state="done", turn=3, kind=None,
                                                           msg="added Send now override")))
        self.assertEqual(alerts[0]["title"], "Claude finished")
        self.assertEqual(alerts[0]["body"], "~ / 1 — added Send now override")

    def test_app_names_and_kind_suffix(self):
        self.assertEqual(notify.format_alert(term(app="codex", kind=None), "blocked")[0], "Codex needs you")
        self.assertEqual(notify.format_alert(term(app="antigravity"), "done")[0], "Antigravity finished")
        self.assertEqual(notify.format_alert(term(app="aider"), "done")[0], "aider finished")
        self.assertEqual(notify.format_alert(term(kind="question"), "blocked")[1],
                         "~ / 1 — needs approval (question)")
        self.assertEqual(notify.format_alert(term(kind="permission"), "done")[1], "~ / 1 — needs approval")

    def test_body_truncated(self):
        title, body = notify.format_alert(term(msg="x" * 400, kind=None), "done")
        self.assertEqual(len(body), 180)

    def test_status_null_no_alert(self):
        state, _ = notify.alerts_for(None, line(term(state="working", turn=5)))
        state, alerts = notify.alerts_for(state, line(term(state=None, turn=5)))
        self.assertEqual(alerts, [])

    def test_malformed_lines_ignored(self):
        state, _ = notify.alerts_for(None, line(term(state="working", turn=5)))
        for bad in ["{not json", "[]", '{"terminals": 3}', '{"nothing": []}', "null"]:
            new, alerts = notify.alerts_for(state, bad)
            self.assertEqual(alerts, [])
            self.assertEqual(new, state)
        state, alerts = notify.alerts_for(state, json.dumps({"terminals": [3, None, term(state="blocked", turn=5)]}))
        self.assertEqual(len(alerts), 1)

    def test_apns_payload_shape(self):
        self.assertEqual(notify.apns_payload("T", "B", "t1", "mac"), {
            "aps": {"alert": {"title": "T", "body": "B"}, "sound": "default", "thread-id": "t1"},
            "address": "t1", "host": "mac"})


class Crypto(Base):
    def test_der_to_raw_synthetic(self):
        r = b"\x80" + b"\x01" * 31  # high bit set: DER gets a leading 0x00
        s = b"\x00" * 31 + b"\x05"  # leading zeros are not minimal DER
        raw = notify.der_to_raw(raw_to_der(r + s))
        self.assertEqual(raw, r + s)
        small = b"\x00" * 31 + b"\x01"
        self.assertEqual(notify.der_to_raw(raw_to_der(small + small)), small + small)
        with self.assertRaises(ValueError):
            notify.der_to_raw(b"junk")

    def test_der_to_raw_openssl_signatures(self):
        key, pub = self.make_key()
        saw_leading_zero = False
        for i in range(40):
            data = f"message {i}".encode()
            der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key], input=data,
                                 capture_output=True, check=True).stdout
            self.assertEqual(der[0], 0x30)
            r_len = der[3]
            self.assertEqual(der[2], 0x02)
            self.assertEqual(der[4 + r_len], 0x02)
            r = der[4:4 + r_len]
            s_len = der[5 + r_len]
            s = der[6 + r_len:6 + r_len + s_len]
            saw_leading_zero |= len(r) == 33 or len(s) == 33
            raw = notify.der_to_raw(der)
            self.assertEqual(len(raw), 64)
            self.assertEqual(raw, r.lstrip(b"\0").rjust(32, b"\0") + s.lstrip(b"\0").rjust(32, b"\0"))
            self.assertTrue(self.verify(pub, data, raw_to_der(raw)))
        self.assertTrue(saw_leading_zero)

    def test_make_jwt_verifies(self):
        key, pub = self.make_key()
        now = 1_700_000_000
        jwt = notify.make_jwt("TEAM123456", "KEY123", key, now)
        self.assertNotIn("=", jwt)
        head, claims, sig = jwt.split(".")
        self.assertEqual(json.loads(b64decode(head)), {"alg": "ES256", "kid": "KEY123"})
        self.assertEqual(json.loads(b64decode(claims)), {"iss": "TEAM123456", "iat": now})
        self.assertEqual(f"{head}.{claims}", notify.signing_input("KEY123", "TEAM123456", now))
        self.assertTrue(self.verify(pub, f"{head}.{claims}".encode(), raw_to_der(b64decode(sig))))

    def test_jwt_cache_reuses_for_50_minutes(self):
        calls = []

        def fake(*args):
            calls.append(args)
            return f"token{len(calls)}"
        real = notify.make_jwt
        notify.make_jwt = fake
        try:
            cache = notify.JwtCache()
            apns = {"team_id": "T", "key_id": "K", "key_path": "/x.p8"}
            first = cache.get(apns, 1000)
            self.assertEqual(cache.get(apns, 1000 + 49 * 60), first)
            self.assertEqual(len(calls), 1)
            self.assertNotEqual(cache.get(apns, 1000 + 50 * 60), first)
            self.assertEqual(len(calls), 2)
        finally:
            notify.make_jwt = real

    def test_config_missing_then_loaded(self):
        path = os.path.join(self.dir, "push.json")
        watcher = notify.ConfigWatcher(path)
        self.assertIsNone(watcher.get())
        with open(path, "w") as f:
            json.dump({"mode": "ntfy", "ntfy": {"url": "https://example.invalid/t"}}, f)
        self.assertEqual(watcher.get()["mode"], "ntfy")


class ApnsKeyTests(unittest.TestCase):
    def test_per_environment_keys(self):
        apns = {"team_id": "T", "sandbox": {"key_id": "S", "key_path": "s.p8"},
                "production": {"key_id": "P", "key_path": "p.p8"}}
        self.assertEqual(notify.apns_key(apns, True)["key_id"], "S")
        self.assertEqual(notify.apns_key(apns, False)["key_id"], "P")

    def test_single_key_serves_both(self):
        apns = {"team_id": "T", "key_id": "K", "key_path": "k.p8"}
        self.assertEqual(notify.apns_key(apns, True)["key_id"], "K")
        self.assertEqual(notify.apns_key(apns, False)["key_path"], "k.p8")

    def test_missing_environment_raises(self):
        with self.assertRaises(KeyError):
            notify.apns_key({"team_id": "T", "sandbox": {"key_id": "S", "key_path": "s"}}, False)


def ev(kind, address, data):
    return json.dumps({"jsonrpc": "2.0", "method": "event",
                       "params": {"seq": 1, "type": kind, "terminal": address, "data": data}})


class EventStreamTests(unittest.TestCase):
    def start(self, **kw):
        state, alerts = notify.alerts_for(None, line(term(**kw)))
        self.assertEqual(alerts, [])
        return state

    def test_status_event_alerts(self):
        state = self.start(state="working", turn=5, seen=4)
        state, alerts = notify.alerts_for(state, ev("status", "t1", {"status": {"app": "claude-code", "state": "done"}}))
        self.assertEqual([a["title"] for a in alerts], ["Claude finished"])

    def test_done_then_turn(self):
        state = self.start(state="working", turn=5, seen=5)
        state, alerts = notify.alerts_for(state, ev("status", "t1", {"status": {"app": "claude-code", "state": "done"}}))
        self.assertEqual(alerts, [])  # turn 5 already seen
        state, alerts = notify.alerts_for(state, ev("turn", "t1", {"turn": 6}))
        self.assertEqual([(a["turn"], a["state"]) for a in alerts], [(6, "done")])

    def test_heartbeat_and_unknown_ignored(self):
        state = self.start(state="working", turn=5)
        same, alerts = notify.alerts_for(state, json.dumps({"jsonrpc": "2.0", "method": "heartbeat", "params": {"seq": 2}}))
        self.assertEqual((same, alerts), (state, []))

    def test_seen_label_event_suppresses(self):
        state = self.start(state="working", turn=5, seen=4)
        state, _ = notify.alerts_for(state, ev("labels", "t1", {"labels": {"herdr.seen": "5"}}))
        state, alerts = notify.alerts_for(state, ev("status", "t1", {"status": {"app": "claude-code", "state": "done"}}))
        self.assertEqual(alerts, [])

    def test_created_terminal_then_blocked(self):
        state = self.start(state="working", turn=5)
        new = term(addr="t9", state="working", turn=1)
        state, _ = notify.alerts_for(state, ev("created", "t9", new))
        state, alerts = notify.alerts_for(state, ev("status", "t9", {"status": {"app": "codex", "state": "blocked", "kind": "permission"}}))
        self.assertEqual([a["title"] for a in alerts], ["Codex needs you"])


class RelayTests(unittest.TestCase):
    DEVICE = {"id": "abcd", "relay": "https://relay.example/", "secret": "s3cret", "name": "Phone"}

    def test_relay_request(self):
        url, headers, data = notify.relay_request(self.DEVICE, "T" * 150, "body", "t1", "pop")
        self.assertEqual(url, "https://relay.example/v1/push")
        self.assertEqual(headers["authorization"], "Bearer s3cret")
        payload = json.loads(data)
        self.assertEqual(len(payload["title"]), 100)
        self.assertEqual(payload["address"], "t1")
        self.assertNotIn("token", payload)

    KEY = bytes(range(64))
    # Same vector is asserted in bergrTests/PushAlertV2Tests.swift (key 0..63, nonce 0..15, title T, body B).
    VECTOR = "AgABAgMEBQYHCAkKCwwNDg8BGrgqFxuhYcg/RAosGAW89KEcGJy32QB42sNYgJdhGxLagnREd3oaxkvJy0KpFqLcQfc5fD/rqQ=="

    def test_encrypt_vector(self):
        self.assertEqual(notify.encrypt_alert(self.KEY, "T", "B", nonce=bytes(range(16))), self.VECTOR)

    def test_v2_round_trip_long_text(self):
        body = "é" * 300  # several keystream blocks, multibyte
        blob = base64.b64decode(notify.encrypt_alert(self.KEY, "Title", body))
        self.assertEqual(blob[0], 2)
        self.assertEqual(notify.decrypt_alert(self.KEY, blob), {"title": "Title", "body": body})

    def test_v2_tamper_is_rejected(self):
        blob = bytearray(base64.b64decode(self.VECTOR))
        for i in (0, 5, 20, len(blob) - 1):
            bad = bytearray(blob)
            bad[i] ^= 1
            with self.assertRaises(ValueError):
                notify.decrypt_alert(self.KEY, bytes(bad))
        with self.assertRaises(ValueError):
            notify.decrypt_alert(bytes(reversed(self.KEY)), bytes(blob))

    def test_encrypt_no_openssl(self):
        with mock.patch.object(notify.subprocess, "run", side_effect=AssertionError("subprocess used")):
            notify.encrypt_alert(self.KEY, "T", "B")

    def test_relay_request_carries_state(self):
        for state, level in (("blocked", "time-sensitive"), ("error", "time-sensitive"), ("done", "passive")):
            _, _, data = notify.relay_request(self.DEVICE, "T", "B", "t1", "pop", state)
            self.assertEqual(json.loads(data)["state"], state)
            self.assertEqual(notify.URGENCY[state], level)
        _, _, data = notify.relay_request(self.DEVICE, "T", "B", "t1", "pop")
        self.assertNotIn("state", json.loads(data))

    def test_apns_payload_interruption_level(self):
        self.assertEqual(notify.apns_payload("T", "B", "t1", "m", "error")["aps"]["interruption-level"], "time-sensitive")
        self.assertEqual(notify.apns_payload("T", "B", "t1", "m", "done")["aps"]["interruption-level"], "passive")

    def test_relay_request_encrypted(self):
        import base64
        dev = dict(self.DEVICE, key=base64.b64encode(self.KEY).decode())
        _, _, data = notify.relay_request(dev, "Title", "Secret body", "t1", "pop")
        payload = json.loads(data)
        self.assertEqual(set(payload), {"e", "address", "host"})
        self.assertNotIn(b"Secret", data)

    def test_relay_request_bad_key_sends_no_text(self):
        dev = dict(self.DEVICE, key="AAAA")
        _, _, data = notify.relay_request(dev, "Title", "Secret body", "t1", "pop")
        payload = json.loads(data)
        self.assertEqual(payload["body"], "An agent needs you")
        self.assertNotIn(b"Secret", data)

    def test_relay_devices_need_no_key(self):
        sent = []
        orig = notify.send_relay
        notify.send_relay = lambda d, *a: sent.append(d["id"])
        try:
            n = notify.send_alert({"devices": [self.DEVICE]}, "t", "b", "t1", "pop", notify.JwtCache())
        finally:
            notify.send_relay = orig
        self.assertEqual((n, sent), (1, ["abcd"]))

    def test_device_with_alerts_off_gets_none(self):
        sent = []
        orig = notify.send_relay
        notify.send_relay = lambda d, *a: sent.append(d["id"])
        try:
            n = notify.send_alert({"devices": [dict(self.DEVICE, alerts=False)]}, "t", "b", "t1", "pop", notify.JwtCache())
        finally:
            notify.send_relay = orig
        self.assertEqual((n, sent), (0, []))

    def test_relay_sends_host_id(self):
        hosts = []
        orig = notify.send_relay
        notify.send_relay = lambda d, t, b, a, h, s=None, q=None: hosts.append(h)
        try:
            notify.send_alert({"devices": [dict(self.DEVICE, host_id="UUID-1")]}, "t", "b", "t1", "pop", notify.JwtCache())
        finally:
            notify.send_relay = orig
        self.assertEqual(hosts, ["UUID-1"])


class LiveActivityTests(unittest.TestCase):
    def terms(self):
        return {t["address"]: t for t in [term("t1", "blocked"), term("t2", "working"), term("t3", "working"),
                                         term("t4", "done"), term("t5", "idle")]}

    def test_counts_without_names(self):
        s = notify.activity_summary(self.terms())
        self.assertEqual(s, {"needsYou": 1, "working": 2, "done": 1})

    def test_rows_only_when_asked_needs_first(self):
        s = notify.activity_summary(self.terms(), rows=True, host_id="H", machine="box")
        self.assertEqual([r["address"] for r in s["rows"]], ["t1", "t2", "t3"])
        self.assertTrue(s["rows"][0]["needsYou"])
        self.assertEqual(s["rows"][0]["kind"], "claude")
        self.assertEqual((s["rows"][0]["host"], s["rows"][0]["machine"]), ("H", "box"))

    def test_when_a_post_is_due(self):
        p = notify.ActivityPoster()
        summary = {"needsYou": 0, "working": 1, "done": 0}
        self.assertTrue(p.due("s", summary, 1000))
        p.devices["s"].update(last=summary, at=1000, active=True)
        self.assertFalse(p.due("s", summary, 1001))            # within 2 s
        self.assertFalse(p.due("s", summary, 1100))            # unchanged, active: every 5 min
        self.assertTrue(p.due("s", dict(summary, working=2), 1003))  # changed
        self.assertTrue(p.due("s", summary, 1301))
        p.devices["s"].update(active=False, at=1000)
        self.assertFalse(p.due("s", summary, 1061))           # inactive, unchanged: no idle beat
        self.assertTrue(p.due("s", summary, 1300))            # but a beat while a count is non-zero

    def test_post_sends_counts_and_learns_full_mode(self):
        p = notify.ActivityPoster()
        sent = []

        class Resp:
            def __init__(self, body): self.body, self.status = body, 200
            def __enter__(self): return self
            def __exit__(self, *a): return False
            def read(self): return json.dumps(self.body).encode()

        def fake(req, timeout=0):
            sent.append(json.loads(req.data))
            return Resp({"active": True, "mode": "full"})
        real = notify.urllib.request.urlopen
        notify.urllib.request.urlopen = fake
        try:
            device = {"relay": "https://r", "secret": "s", "host_id": "H"}
            p.post(device, self.terms(), "box", 1000)
            p.post(device, self.terms(), "box", 1003)
        finally:
            notify.urllib.request.urlopen = real
        self.assertNotIn("rows", sent[0])
        self.assertTrue(sent[0]["urgent"])
        self.assertEqual(sent[0]["machine"], "H")
        self.assertEqual(len(sent[1]["rows"]), 3)   # full mode learnt: rows right away
        self.assertFalse(sent[1]["urgent"])


class HideAfterTests(unittest.TestCase):
    def test_old_finished_agents_dont_count(self):
        now = 1_000_000.0
        old = dict(term("t1", "done"), status_ms=int((now - 2 * 86400) * 1000))
        fresh = dict(term("t2", "done"), status_ms=int((now - 60) * 1000))
        stuck = dict(term("t3", "blocked"), status_ms=int((now - 9 * 86400) * 1000))
        terms = {t["address"]: t for t in (old, fresh, stuck)}
        self.assertEqual(notify.activity_summary(terms, hide_after=86400, now=now),
                         {"needsYou": 1, "working": 0, "done": 1})
        self.assertEqual(notify.activity_summary(terms, hide_after=0, now=now)["done"], 2)

    def test_status_change_records_its_time(self):
        before = {"t1": term("t1", "working")}
        ev = json.dumps({"method": "event", "params": {"type": "status", "terminal": "t1",
                                                       "data": {"status": {"state": "done"}}}})
        after = notify.apply_event(before, ev)
        self.assertGreater(after["t1"]["status_ms"], 0)


def fleet(blocked=0, working=0, done=0, msg="needs approval"):
    """Terminals in the given numbers of states; `msg` is the text the rows would show."""
    terms = {}
    for state, n in (("blocked", blocked), ("working", working), ("done", done)):
        for i in range(n):
            terms[f"{state}{i}"] = term(f"{state}{i}", state, turn=1, msg=msg)
    return terms


class FakeResponse:
    def __init__(self, body, status=200):
        self.body, self.status = body, status

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def read(self):
        return json.dumps(self.body).encode()


class FakeRelay:
    """Stands in for urllib.request.urlopen: records every request body, answers with `reply`."""
    def __init__(self):
        self.calls, self.reply, self.status, self.down = [], {"active": False}, 200, False

    def __call__(self, req, timeout=0):
        self.calls.append(json.loads(req.data))
        if self.down:
            raise urllib.error.URLError("relay down")
        return FakeResponse(self.reply, self.status)


ACTIVE_FULL = {"active": True, "mode": "full", "hide_after": 86400}


class PosterCadenceTests(unittest.TestCase):
    DEVICE = {"relay": "https://relay.example", "secret": "s3cret", "host_id": "H"}

    def setUp(self):
        self.poster = notify.ActivityPoster()
        self.relay = FakeRelay()
        patch = mock.patch.object(notify.urllib.request, "urlopen", self.relay)
        patch.start()
        self.addCleanup(patch.stop)

    def post(self, terms, now):
        self.poster.post(self.DEVICE, terms, "box", now)

    def activate(self):
        self.relay.reply = ACTIVE_FULL  # the relay answers every post with "active"
        self.poster.learn("s3cret", ACTIVE_FULL)

    def test_inactive_all_zero_never_posts(self):
        self.post(fleet(), 1000)
        self.post(fleet(), 1000 + 600)
        self.assertEqual(len(self.relay.calls), 0)

    def test_inactive_unchanged_nonzero_beats_only_at_300s(self):
        self.post(fleet(working=1), 1000)
        self.post(fleet(working=1), 1299)
        self.assertEqual(len(self.relay.calls), 1)
        self.post(fleet(working=1), 1300)
        self.assertEqual(len(self.relay.calls), 2)

    def test_inactive_count_change_posts_counts_only(self):
        self.post(fleet(working=1), 1000)
        self.post(fleet(working=2), 1001)  # within 2 s: not yet
        self.assertEqual(len(self.relay.calls), 1)
        self.post(fleet(working=2), 1010)
        self.assertEqual(len(self.relay.calls), 2)
        self.assertEqual(self.relay.calls[1]["working"], 2)
        self.assertNotIn("rows", self.relay.calls[1])

    def test_urgent_posts_inside_the_min_gap(self):
        self.post(fleet(working=1), 1000)
        self.post(fleet(working=1, blocked=1), 1001)
        self.assertEqual(len(self.relay.calls), 2)
        self.assertTrue(self.relay.calls[1]["urgent"])

    def test_active_text_change_in_full_mode_waits_20s(self):
        self.activate()
        self.post(fleet(working=1, msg="step 1"), 1000)
        self.post(fleet(working=1, msg="step 2"), 1005)
        self.post(fleet(working=1, msg="step 2"), 1019)
        self.assertEqual(len(self.relay.calls), 1)
        self.post(fleet(working=1, msg="step 2"), 1020)
        self.assertEqual(len(self.relay.calls), 2)
        self.assertEqual(self.relay.calls[1]["rows"][0]["status"], "step 2")

    def test_active_count_change_posts_after_2s(self):
        self.activate()
        self.post(fleet(working=1), 1000)
        self.post(fleet(working=2), 1001)
        self.assertEqual(len(self.relay.calls), 1)
        self.post(fleet(working=2), 1002)
        self.assertEqual(len(self.relay.calls), 2)

    def test_active_beats_only_while_counts_nonzero(self):
        self.activate()
        self.post(fleet(), 1000)
        self.post(fleet(), 2000)
        self.assertEqual(len(self.relay.calls), 0)
        self.post(fleet(working=1), 2001)
        self.post(fleet(working=1), 2300)
        self.assertEqual(len(self.relay.calls), 1)
        self.post(fleet(working=1), 2301)
        self.assertEqual(len(self.relay.calls), 2)

    def test_failed_post_not_recorded_and_retried_after_30s(self):
        self.relay.down = True
        self.post(fleet(working=1), 1000)
        self.assertIsNone(self.poster.devices["s3cret"]["last"])
        self.relay.down = False
        self.post(fleet(working=1), 1010)
        self.assertEqual(len(self.relay.calls), 1)  # no retry within 30 s
        self.post(fleet(working=1), 1030)
        self.assertEqual(len(self.relay.calls), 2)
        self.assertEqual(self.poster.devices["s3cret"]["last"]["working"], 1)

    def test_non_200_is_a_failure(self):
        self.relay.status = 503
        self.post(fleet(working=1), 1000)
        self.assertIsNone(self.poster.devices["s3cret"]["last"])

    def test_inactive_reply_returns_mode_to_counts(self):
        self.activate()
        self.assertEqual(self.poster.devices["s3cret"]["mode"], "full")
        self.poster.learn("s3cret", {"active": False})
        self.assertEqual(self.poster.devices["s3cret"]["mode"], "counts")

    def test_push_reply_with_active_flips_device(self):
        self.relay.reply = {"active": True, "mode": "full", "hide_after": 3600}
        notify.send_alert({"devices": [self.DEVICE]}, "T", "B", "t1", "box", notify.JwtCache(),
                          on_reply=self.poster.learn)
        d = self.poster.devices["s3cret"]
        self.assertEqual((d["active"], d["mode"], d["hide_after"]), (True, "full", 3600))

    def test_push_reply_without_active_is_ignored(self):
        self.relay.reply = {"ok": True}
        notify.send_alert({"devices": [self.DEVICE]}, "T", "B", "t1", "box", notify.JwtCache(),
                          on_reply=self.poster.learn)
        self.assertNotIn("s3cret", self.poster.devices)


if __name__ == "__main__":
    unittest.main()
