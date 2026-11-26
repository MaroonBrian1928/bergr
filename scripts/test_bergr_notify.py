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

    def test_other_machines_terminals_dont_alert(self):
        state, _ = notify.alerts_for(None, line(term(addr="popos/t2", state="working", turn=5)))
        state, alerts = notify.alerts_for(state, line(term(addr="popos/t2", state="done", turn=6)))
        self.assertEqual(alerts, [])

    def test_non_integer_turn_is_logged_once(self):
        notify._BAD_TURN_LOGGED.clear()
        logged = []
        real = notify.log
        notify.log = logged.append
        try:
            state, _ = notify.alerts_for(None, line(term(state="working", turn="x")))
            state, alerts = notify.alerts_for(state, line(term(state="blocked", turn="x")))
            state, _ = notify.alerts_for(state, line(term(state="working", turn="y")))
            state, _ = notify.alerts_for(state, line(term(state="blocked", turn="y")))
        finally:
            notify.log = real
        self.assertEqual(alerts, [])
        self.assertEqual(len([m for m in logged if "turn is not an integer" in m]), 1)

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
        for state, level in (("blocked", "active"), ("error", "active"), ("done", "passive")):
            _, _, data = notify.relay_request(self.DEVICE, "T", "B", "t1", "pop", state)
            self.assertEqual(json.loads(data)["state"], state)
            self.assertEqual(notify.URGENCY[state], level)
        _, _, data = notify.relay_request(self.DEVICE, "T", "B", "t1", "pop")
        self.assertNotIn("state", json.loads(data))

    def test_apns_payload_interruption_level(self):
        self.assertEqual(notify.apns_payload("T", "B", "t1", "m", "error")["aps"]["interruption-level"], "active")
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
        notify.send_relay = lambda d, t, b, a, h, s=None, q=None, ans=None: hosts.append(h)
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


class HeartbeatTests(unittest.TestCase):
    DEVICE = {"relay": "https://relay.example", "secret": "s3cret", "host_id": "H"}

    def setUp(self):
        self.poster = notify.ActivityPoster()
        self.relay = FakeRelay()
        patch = mock.patch.object(notify.urllib.request, "urlopen", self.relay)
        patch.start()
        self.addCleanup(patch.stop)

    def beat(self, terms, now):
        return self.poster.heartbeat(self.DEVICE, terms, "box", now)

    def test_idle_machine_beats_every_five_minutes(self):
        self.assertTrue(self.beat(fleet(), 1000))
        self.assertFalse(self.beat(fleet(), 1299))
        self.assertTrue(self.beat(fleet(), 1300))
        self.assertEqual(len(self.relay.calls), 2)

    def test_beat_carries_id_name_counts_and_version(self):
        self.beat(fleet(blocked=1, working=2, done=3), 1000)
        self.assertEqual(self.relay.calls[0], {"machine": "H", "name": "box", "needsYou": 1, "working": 2,
                                               "done": 3, "version": notify.VERSION})

    def test_failed_beat_retries_after_30s(self):
        self.relay.down = True
        self.assertFalse(self.beat(fleet(working=1), 1000))
        self.assertFalse(self.beat(fleet(working=1), 1029))
        self.relay.down = False
        self.assertTrue(self.beat(fleet(working=1), 1030))

    def test_beat_does_not_disturb_activity_posts(self):
        self.beat(fleet(working=1), 1000)
        self.poster.post(self.DEVICE, fleet(), "box", 1000)
        self.assertEqual(len(self.relay.calls), 1)  # only the beat; zero counts post nothing


class PrefsTests(unittest.TestCase):
    """Per-kind switches, muted agents and quiet hours (v13); no prefs behaves as before."""
    DEVICE = {"id": "abcd", "relay": "https://r.example", "secret": "s"}
    NOON = 1704110400  # 2024-01-01 12:00:00 UTC

    def quiet(self, start, end, offset=0, **kw):
        return dict({"quiet": {"start": start, "end": end}, "tz_offset": offset}, **kw)

    def test_no_prefs_allows_everything(self):
        for st in ("blocked", "error", "done", None):
            self.assertTrue(notify.prefs_allow(None, st, "t1"))
            self.assertTrue(notify.prefs_allow({}, st, "t1"))
        self.assertTrue(notify.prefs_allow("junk", "done", "t1"))

    def test_kinds(self):
        prefs = {"kinds": {"needs_you": True, "finished": False, "error": True}}
        self.assertTrue(notify.prefs_allow(prefs, "blocked", "t1"))
        self.assertFalse(notify.prefs_allow(prefs, "done", "t1"))
        self.assertTrue(notify.prefs_allow(prefs, "error", "t1"))
        self.assertFalse(notify.prefs_allow({"kinds": {"needs_you": False}}, "blocked", "t1"))

    def test_muted_agent_even_for_needs_you(self):
        prefs = {"muted": ["t1"]}
        self.assertFalse(notify.prefs_allow(prefs, "blocked", "t1"))
        self.assertTrue(notify.prefs_allow(prefs, "blocked", "t2"))

    def test_quiet_hours_same_day_window(self):
        prefs = self.quiet(11 * 60, 13 * 60)  # noon is inside
        self.assertFalse(notify.prefs_allow(prefs, "done", "t1", self.NOON))
        self.assertFalse(notify.prefs_allow(prefs, "error", "t1", self.NOON))
        self.assertTrue(notify.prefs_allow(prefs, "blocked", "t1", self.NOON))
        self.assertTrue(notify.prefs_allow(prefs, "done", "t1", self.NOON + 3600))  # 13:00 is outside

    def test_quiet_hours_crossing_midnight(self):
        prefs = self.quiet(22 * 60, 7 * 60)
        at = lambda hour, minute=0: self.NOON + (hour - 12) * 3600 + minute * 60
        self.assertFalse(notify.prefs_allow(prefs, "done", "t1", at(23)))
        self.assertFalse(notify.prefs_allow(prefs, "done", "t1", at(3)))
        self.assertFalse(notify.prefs_allow(prefs, "done", "t1", at(6, 59)))
        self.assertTrue(notify.prefs_allow(prefs, "done", "t1", at(7)))
        self.assertTrue(notify.prefs_allow(prefs, "done", "t1", at(12)))
        self.assertTrue(notify.prefs_allow(prefs, "done", "t1", at(21, 59)))
        self.assertFalse(notify.prefs_allow(prefs, "done", "t1", at(22)))
        self.assertTrue(notify.prefs_allow(prefs, "blocked", "t1", at(23)))

    def test_quiet_hours_use_the_phones_time_zone(self):
        prefs = self.quiet(22 * 60, 7 * 60, offset=-300)  # UTC-5: noon UTC is 07:00, outside
        self.assertTrue(notify.prefs_allow(prefs, "done", "t1", self.NOON))
        self.assertFalse(notify.prefs_allow(prefs, "done", "t1", self.NOON - 3600))  # 06:00 local
        named = dict(prefs, tz="America/New_York")
        self.assertFalse(notify.prefs_allow(named, "done", "t1", self.NOON - 3600))
        self.assertTrue(notify.prefs_allow(named, "done", "t1", self.NOON))

    def test_empty_or_bad_quiet_window_is_ignored(self):
        self.assertTrue(notify.prefs_allow(self.quiet(60, 60), "done", "t1", self.NOON))
        self.assertTrue(notify.prefs_allow({"quiet": {"start": "x", "end": 1}}, "done", "t1", self.NOON))

    def test_test_alert_always_passes(self):
        self.assertTrue(notify.prefs_allow({"kinds": {"finished": False}, "muted": ["test"]}, None, "test"))

    def send(self, device, state, address="t1"):
        sent = []
        orig = notify.send_relay
        notify.send_relay = lambda d, *a: sent.append(d["id"])
        try:
            notify.send_alert({"devices": [device]}, "t", "b", address, "pop", notify.JwtCache(), state=state)
        finally:
            notify.send_relay = orig
        return sent

    def test_send_alert_honours_prefs_per_device(self):
        off = dict(self.DEVICE, prefs={"kinds": {"finished": False}})
        self.assertEqual(self.send(off, "done"), [])
        self.assertEqual(self.send(off, "blocked"), ["abcd"])
        self.assertEqual(self.send(dict(self.DEVICE, prefs={"muted": ["t1"]}), "blocked"), [])
        self.assertEqual(self.send(dict(self.DEVICE, prefs={"muted": ["t1"]}), "blocked", "t2"), ["abcd"])

    def test_old_registration_without_prefs_behaves_as_before(self):
        for state in ("blocked", "error", "done", None):
            self.assertEqual(self.send(self.DEVICE, state), ["abcd"])

    def test_version_is_bumped(self):
        self.assertGreaterEqual(notify.VERSION, 13)


class HealthAlertTests(unittest.TestCase):
    G = 1 << 30

    def test_disk_alerts_once_per_crossing_and_rearms(self):
        flags = {}
        alerts, flags = notify.health_alerts(flags, disk=(4 * self.G, 100 * self.G))
        self.assertEqual([a[0] for a in alerts], ["disk"])
        alerts, flags = notify.health_alerts(flags, disk=(3 * self.G, 100 * self.G))
        self.assertEqual(alerts, [])
        alerts, flags = notify.health_alerts(flags, disk=(5.5 * self.G, 100 * self.G))  # inside margin
        self.assertEqual(alerts, [])
        self.assertTrue(flags["disk"])
        alerts, flags = notify.health_alerts(flags, disk=(50 * self.G, 100 * self.G))
        self.assertFalse(flags["disk"])
        alerts, flags = notify.health_alerts(flags, disk=(2 * self.G, 100 * self.G))
        self.assertEqual(len(alerts), 1)

    def test_disk_percent_threshold(self):
        alerts, _ = notify.health_alerts({}, disk=(10 * self.G, 1000 * self.G))
        self.assertEqual(len(alerts), 1)

    def test_battery_needs_discharging_and_rearms(self):
        self.assertEqual(notify.health_alerts({}, battery=(10, False))[0], [])
        alerts, flags = notify.health_alerts({}, battery=(14, True))
        self.assertEqual([a[0] for a in alerts], ["battery"])
        self.assertEqual(notify.health_alerts(flags, battery=(12, True))[0], [])
        _, flags = notify.health_alerts(flags, battery=(12, False))  # plugged in
        self.assertFalse(flags["battery"])
        self.assertEqual(len(notify.health_alerts(flags, battery=(9, True))[0]), 1)

    def test_parse_pmset(self):
        out = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t87%; discharging; 5:00 remaining"
        self.assertEqual(notify.parse_pmset(out), (87, True))
        self.assertEqual(notify.parse_pmset("\t100%; charged; 0:00"), (100, False))
        self.assertIsNone(notify.parse_pmset("Now drawing from 'AC Power'"))

    def test_check_health_sends_once_as_error_and_persists(self):
        sent = []
        path = os.path.join(tempfile.mkdtemp(), "health-state.json")
        send = lambda cfg, title, body, addr, host, jwt, **kw: sent.append(kw.get("state"))
        low = (1 * self.G, 100 * self.G)
        for _ in range(3):
            notify.check_health({}, "pop", None, path, disk=low, sender=send)
        self.assertEqual(sent, ["error"])
        notify.check_health({}, "pop", None, path, disk=(80 * self.G, 100 * self.G), sender=send)
        notify.check_health({}, "pop", None, path, disk=low, sender=send)
        self.assertEqual(len(sent), 2)

    def test_error_alert_honours_prefs(self):
        dev = {"id": "abcd", "relay": "https://r", "secret": "s", "prefs": {"kinds": {"error": False}}}
        self.assertFalse(notify.prefs_allow(dev["prefs"], "error", "health"))
        self.assertTrue(notify.prefs_allow({"kinds": {"error": True}}, "error", "health"))
        quiet = {"quiet": {"start": 0, "end": 1439}, "tz_offset": 0}
        self.assertFalse(notify.prefs_allow(quiet, "error", "health", now=3600))

    def test_version_bumped_for_health(self):
        self.assertGreaterEqual(notify.VERSION, 14)


CASES = json.load(open(os.path.join(HERE, "..", "bergrTests", "approval-rule-cases.json"), encoding="utf-8"))
PROMPT = CASES["prompt"][0]["lines"]


class ApprovalRuleTests(unittest.TestCase):
    """The same cases as bergrTests/ApprovalRuleTests.swift."""

    def test_shared_match_cases(self):
        ctx = CASES["context"]
        for c in CASES["match"]:
            rule = {"machine": ctx["machine"], "cwd": ctx["cwd"], "agent": ctx["agent"],
                    "command": c["rule"], "prefix": c["prefix"]}
            if "expires" in c:
                rule["expires"] = c["expires"]
            got = notify.rule_matches(rule, c.get("machine", ctx["machine"]), c.get("cwd", ctx["cwd"]),
                                      c.get("agent", ctx["agent"]), c["command"], now=c.get("now"))
            self.assertEqual(got, c["expect"], c)

    def test_shared_dangerous_cases(self):
        for t in CASES["dangerous"]["yes"]:
            self.assertIsNotNone(notify.dangerous_reason(t), t)
        for t in CASES["dangerous"]["no"]:
            self.assertIsNone(notify.dangerous_reason(t), t)

    def test_shared_ask_cases(self):
        for c in CASES["ask"]:
            self.assertEqual(notify.ask_match(c["text"], c["patterns"]), c["expect"], c)

    def test_expired_or_malformed_expiry_never_matches(self):
        rule = {"machine": "M1", "cwd": "/a", "agent": "claude-code", "command": "ls", "prefix": False}
        self.assertTrue(notify.rule_matches(dict(rule, expires=notify.time.time() + 60), "M1", "/a", "claude-code", "ls"))
        self.assertFalse(notify.rule_matches(dict(rule, expires=notify.time.time() - 1), "M1", "/a", "claude-code", "ls"))
        self.assertFalse(notify.rule_matches(dict(rule, expires="soon"), "M1", "/a", "claude-code", "ls"))

    def test_ask_pattern_blocks_auto_answer_and_alert_buttons(self):
        cfg = self._cfg()
        cfg["devices"].append({"id": "e", "host_id": "M1", "askPatterns": ["npm t*t"]})
        calls = []
        self.assertIsNone(notify.auto_answer(cfg, "t1", self._spy(self._runner([PROMPT]), calls)))
        self.assertNotIn("keys", [a[1] for a in calls])
        q = {"title": "Bash: npm test", "options": ["Yes", "No"], "keys": True}
        self.assertIsNone(notify.alert_answers(cfg, {"q": q, "title": "t", "body": "b"}))
        self.assertEqual(notify.alert_answers(self._cfg(), {"q": q, "title": "t", "body": "b"}), q)

    def test_shared_prompt_cases(self):
        for c in CASES["prompt"]:
            self.assertEqual(notify.prompt_command(c["lines"], c["cols"], c["agent"]), c["expect"], c["name"])

    def test_malformed_rules_never_match(self):
        for rule in (None, [], {}, {"machine": "M1", "cwd": "/a", "agent": "claude-code", "command": "ls", "prefix": "yes"}):
            self.assertFalse(notify.rule_matches(rule, "M1", "/a", "claude-code", "ls -l"))

    def _runner(self, screens, cwd="/home/u/app", kind="permission"):
        screens = list(screens)
        def run(args):
            if args[1] == "get":
                return json.dumps({"address": "t1", "cols": 80, "cwd": "/home/u", "foreground": {"cwd": cwd},
                                   "status": {"app": "claude-code", "state": "blocked", "kind": kind}})
            if args[1] == "read":
                return json.dumps({"text": "\n".join(screens.pop(0) if len(screens) > 1 else screens[0])})
            return ""
        return run

    def _cfg(self, command="npm test", prefix=False):
        rule = {"machine": "M1", "cwd": "/home/u/app", "agent": "claude-code", "command": command, "prefix": prefix}
        return {"devices": [{"id": "d", "relay": "https://r", "secret": "s", "host_id": "M1", "rules": [rule]}]}

    def _spy(self, runner, calls):
        def spy(args):
            calls.append(args)
            return runner(args)
        return spy

    def test_auto_answer_presses_enter_when_a_rule_covers_it(self):
        calls = []
        done = notify.auto_answer(self._cfg(), "t1", self._spy(self._runner([PROMPT]), calls))
        self.assertEqual(done[0], "npm test")
        self.assertEqual(calls[-1], ["hc", "keys", "t1", "enter"])
        calls = []
        self.assertIsNotNone(notify.auto_answer(self._cfg("npm", prefix=True), "t1", self._spy(self._runner([PROMPT]), calls)))

    def test_auto_answer_refuses(self):
        changed = [l.replace("npm test   ", "npm tests  ") for l in PROMPT]
        other_machine = {"devices": [{"id": "d", "host_id": "M2", "rules": self._cfg()["devices"][0]["rules"]}]}
        cases = [
            (self._cfg("npm"), "t1", self._runner([PROMPT])),                      # exact rule, other command
            (self._cfg(), "popos/t1", self._runner([PROMPT])),                     # another machine's terminal
            (self._cfg(), "t1", self._runner([PROMPT], cwd="/home/u/other")),      # other folder
            (self._cfg(), "t1", self._runner([PROMPT], kind="question")),          # not a permission prompt
            (self._cfg(), "t1", self._runner([PROMPT, changed])),                  # changed before pressing
            (other_machine, "t1", self._runner([PROMPT])),                         # rule for another machine
            ({"devices": []}, "t1", self._runner([PROMPT])),
        ]
        for i, (cfg, address, runner) in enumerate(cases):
            calls = []
            self.assertIsNone(notify.auto_answer(cfg, address, self._spy(runner, calls)), i)
            self.assertNotIn("keys", [a[1] for a in calls], i)

    def test_auto_answer_is_logged(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "auto-approvals.json")
            rule = self._cfg()["devices"][0]["rules"][0]
            notify.record_auto_answer(path, "npm test", rule, {"address": "t1"}, now=5)
            entries = notify.record_auto_answer(path, "npm test", rule, {"address": "t1"}, now=6)
            self.assertEqual([e["at"] for e in entries], [5, 6])
            self.assertEqual(entries[0]["cwd"], "/home/u/app")

    def test_version_bumped_for_rules(self):
        self.assertGreaterEqual(notify.VERSION, 18)


class QuietCatchUpTests(unittest.TestCase):
    NOON = 1704110400  # 2024-01-01 12:00 UTC
    NIGHT = NOON + 12 * 3600
    QUIET = {"quiet": {"start": 22 * 60, "end": 7 * 60}, "tz_offset": 0}

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "quiet-drops.json")
        self.dev = {"id": "abcd", "relay": "https://r.example", "secret": "s", "name": "Phone", "prefs": self.QUIET}

    def tearDown(self):
        notify._drop_path = None
        self.dir.cleanup()

    def drop(self, state, address="t1", title="x"):
        notify.record_quiet_drop(self.path, self.dev, state, address, title)

    def test_verdict_quiet_only_for_quiet_hours(self):
        self.assertEqual(notify.prefs_verdict(self.QUIET, "done", "t1", self.NIGHT), "quiet")
        self.assertEqual(notify.prefs_verdict(self.QUIET, "blocked", "t1", self.NIGHT), "send")
        self.assertEqual(notify.prefs_verdict(self.QUIET, "done", "t1", self.NOON), "send")
        off = dict(self.QUIET, kinds={"finished": False})
        self.assertEqual(notify.prefs_verdict(off, "done", "t1", self.NIGHT), "drop")
        self.assertEqual(notify.prefs_verdict(dict(self.QUIET, muted=["t1"]), "done", "t1", self.NIGHT), "drop")

    def test_send_alert_records_quiet_drops_per_kind(self):
        notify._drop_path = self.path
        cfg = {"mode": "apns", "devices": [self.dev]}
        with mock.patch.object(notify.time, "time", return_value=self.NIGHT), \
             mock.patch.object(notify, "send_relay") as relay:
            for st, addr, title in (("done", "t1", "a"), ("done", "t2", "b"), ("error", "t1", "c"),
                                    ("error", "health", "h: Battery low"), ("error", "health", "h: Disk almost full")):
                notify.send_alert(cfg, title, "", addr, "h", notify.JwtCache(), state=st)
            relay.assert_not_called()
        self.assertEqual(notify._load_drops(self.path)["s"],
                         {"finished": 2, "error": 1, "battery": 1, "disk": 1})

    def test_disabled_kind_not_recorded(self):
        notify._drop_path = self.path
        dev = dict(self.dev, prefs=dict(self.QUIET, kinds={"finished": False}))
        with mock.patch.object(notify.time, "time", return_value=self.NIGHT):
            notify.send_alert({"devices": [dev]}, "a", "", "t1", "h", notify.JwtCache(), state="done")
        self.assertEqual(notify._load_drops(self.path), {})

    def flush(self, cfg, now):
        sent = []
        notify.flush_quiet_drops(cfg, "pop-os", None, self.path, now=now,
                                 sender=lambda c, title, body, *a, **k: sent.append((c["devices"][0]["secret"], title)))
        return sent

    def test_summary_sent_once_when_window_ends(self):
        for _ in range(3):
            self.drop("done")
        self.drop("error")
        self.drop("error", "health", "h: Battery low")
        cfg = {"devices": [self.dev]}
        self.assertEqual(self.flush(cfg, self.NOON),
                         [("s", "While you were away: 3 finished, 1 error on pop-os, low battery")])
        self.assertEqual(self.flush(cfg, self.NOON), [])
        self.assertFalse(os.path.exists(self.path))

    def test_nothing_sent_while_still_quiet_or_when_empty(self):
        self.drop("done")
        cfg = {"devices": [self.dev]}
        self.assertEqual(self.flush(cfg, self.NIGHT), [])
        self.assertIn("s", notify._load_drops(self.path))  # still counting
        os.remove(self.path)
        self.assertEqual(self.flush(cfg, self.NOON), [])

    def test_kind_switched_off_midwindow_not_counted(self):
        self.drop("done")
        dev = dict(self.dev, prefs={"kinds": {"finished": False}})
        self.assertEqual(self.flush({"devices": [dev]}, self.NOON), [])
        self.assertFalse(os.path.exists(self.path))
        self.drop("done")
        self.drop("error")
        sent = self.flush({"devices": [dev]}, self.NOON)
        self.assertEqual(sent[0][1], "While you were away: 1 error on pop-os")

    def test_removed_device_just_cleared(self):
        self.drop("done")
        self.assertEqual(self.flush({"devices": []}, self.NOON), [])
        self.assertFalse(os.path.exists(self.path))


class FakeChild:
    def __init__(self):
        self.alive, self.killed = True, False

    def poll(self):
        return None if self.alive else 0

    def kill(self):
        self.alive, self.killed = False, True

    def wait(self, timeout=None):
        return 0


class WindowsTests(unittest.TestCase):
    """The helper's Windows paths, checked on any OS by pretending os.name == "nt"."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.local = os.path.join(self.tmp.name, "Local")
        os.makedirs(os.path.join(self.local, "Programs", "herdr-core"))

    def test_setup_puts_herdr_core_on_path_once(self):
        env = {"LOCALAPPDATA": self.local, "PATH": "sysdir"}
        with mock.patch.object(notify.os, "name", "nt"):
            notify.windows_setup(env, stderr=object())
            notify.windows_setup(env, stderr=object())
        herdr = os.path.join(self.local, "Programs", "herdr-core")
        self.assertEqual(env["PATH"].split(os.pathsep), [herdr, "sysdir"])

    def test_setup_logs_to_a_file_under_pythonw(self):
        env = {"LOCALAPPDATA": self.local, "PATH": ""}
        saved = notify.sys.stderr
        try:
            with mock.patch.object(notify.os, "name", "nt"), mock.patch.object(notify.sys, "stderr", None):
                f = notify.windows_setup(env)
                self.assertIsNotNone(f)
                notify.log("hello")
                f.close()
        finally:
            notify.sys.stderr = saved
        with open(os.path.join(self.local, "bergr", "bergr-notify.log"), encoding="utf-8") as fh:
            self.assertIn("hello", fh.read())

    def test_setup_does_nothing_elsewhere(self):
        env = {"LOCALAPPDATA": self.local, "PATH": "/bin"}
        with mock.patch.object(notify.os, "name", "posix"):
            self.assertIsNone(notify.windows_setup(env, stderr=None))
        self.assertEqual(env["PATH"], "/bin")

    def test_children_get_no_console_window(self):
        if os.name != "nt":
            self.assertEqual(notify.NO_WINDOW, {})
        calls = []

        def fake_run(*a, **k):
            calls.append(k)
            raise OSError("missing")
        with mock.patch.object(notify, "NO_WINDOW", {"creationflags": 0x08000000}), \
                mock.patch.object(notify.subprocess, "run", fake_run):
            self.assertIsNone(notify._git(self.tmp.name, ["status"]))  # git missing: skipped, no crash
            with self.assertRaises(OSError):
                notify._hc_run(["hc", "list"])
        self.assertTrue(calls and all(k.get("creationflags") == 0x08000000 for k in calls))

    def test_features_avoid_posix_only_calls_on_windows(self):
        cfg_dir = os.path.join(self.tmp.name, "cfg")
        os.makedirs(cfg_dir)
        cfg = os.path.join(cfg_dir, "push.json")

        def boom(*a, **k):
            raise AssertionError("POSIX-only call on Windows")

        def no_git(cmd, *a, **k):  # git isn't installed; nothing else may be spawned
            if cmd[0] == "git":
                raise FileNotFoundError("git")
            boom()
        with mock.patch.object(notify.os, "name", "nt"), \
                mock.patch.object(notify.sys, "platform", "win32"), \
                mock.patch.object(notify.os, "getuid", boom, create=True), \
                mock.patch.object(notify.subprocess, "Popen", no_git):
            awake = notify.KeepAwake(pid=1)
            awake.update(2)  # keep-awake: nothing to spawn on Windows
            self.assertFalse(awake.held())
            self.assertIsNone(notify.battery_reading())  # disk only
            self.assertIsNotNone(notify.disk_reading(self.tmp.name))
            self.assertIsNone(notify.record_turn_baseline("t1", self.tmp.name, cfg))  # not a repo
            notify.record_pending_answer(os.path.join(cfg_dir, "answers.json"), "t1", 1, "q")


class KeepAwakeTests(unittest.TestCase):
    def make(self, platform="darwin"):
        self.t, self.spawned = [1000.0], []

        def spawn(cmd):
            self.spawned.append(cmd)
            return FakeChild()
        return notify.KeepAwake(spawn=spawn, clock=lambda: self.t[0], pid=42, platform=platform)

    def test_commands(self):
        self.assertEqual(notify.keep_awake_command(42, "darwin"), ["caffeinate", "-i", "-w", "42"])
        self.assertEqual(notify.keep_awake_command(42, "linux")[:2], ["systemd-inhibit", "--what=idle:sleep"])
        self.assertIsNone(notify.keep_awake_command(42, "win32"))

    def test_starts_once_and_releases_after_two_minutes(self):
        k = self.make()
        k.update(1)
        k.update(2)
        self.assertEqual(len(self.spawned), 1)
        child = k.child
        k.update(0)
        self.t[0] += 119
        k.update(0)
        self.assertFalse(child.killed)
        self.t[0] += 2
        k.update(0)
        self.assertTrue(child.killed)
        self.assertIsNone(k.child)

    def test_work_resuming_resets_the_grace(self):
        k = self.make()
        k.update(1)
        k.update(0)
        self.t[0] += 100
        k.update(1)
        k.update(0)
        self.t[0] += 100
        k.update(0)
        self.assertTrue(k.held())
        self.assertEqual(len(self.spawned), 1)

    def test_respawns_if_child_died(self):
        k = self.make()
        k.update(1)
        k.child.alive = False
        k.update(1)
        self.assertEqual(len(self.spawned), 2)

    def test_pref_off_releases_and_blocks(self):
        k = self.make()
        k.update(1)
        child = k.child
        k.update(1, enabled=False)
        self.assertTrue(child.killed)
        k.update(1, enabled=False)
        self.assertEqual(len(self.spawned), 1)

    def test_windows_spawns_nothing(self):
        k = self.make("win32")
        k.update(1)
        self.assertEqual(self.spawned, [])

    def test_release_kills_own_child_on_exit(self):
        k = self.make()
        k.update(1)
        child = k.child
        k.release()
        self.assertTrue(child.killed)

    def test_wanted_and_working_count(self):
        self.assertTrue(notify.keep_awake_wanted({}))
        self.assertTrue(notify.keep_awake_wanted({"devices": [{"prefs": {}}]}))
        self.assertFalse(notify.keep_awake_wanted({"devices": [{"prefs": {"keepAwake": False}}]}))
        self.assertTrue(notify.keep_awake_wanted({"devices": [{"prefs": {"keepAwake": False}}, {}]}))
        terms = {"a": {"status": {"state": "working"}}, "b": {"status": {"state": "done"}}, "c": {}}
        self.assertEqual(notify.working_count(terms), 1)


class TurnBaselineTests(Base):
    def git(self, *args, cwd=None):
        return subprocess.run(["git", "-C", cwd or self.repo] + list(args), capture_output=True, text=True, check=True).stdout

    def setUp(self):
        super().setUp()
        self.repo = os.path.join(self.dir, "repo")
        os.makedirs(self.repo)
        self.cfg = os.path.join(self.dir, "cfg", "push.json")
        self.git("init", "-q")
        self.git("config", "user.email", "t@t")
        self.git("config", "user.name", "t")
        self.write("a.txt", "one\ntwo\n")
        self.git("add", ".")
        self.git("commit", "-qm", "init")

    def write(self, name, text):
        with open(os.path.join(self.repo, name), "w") as f:
            f.write(text)

    def test_baseline_leaves_index_and_worktree_alone(self):
        self.write("a.txt", "one\nchanged\n")
        self.write("staged.txt", "s\n")
        self.git("add", "staged.txt")
        self.write("new.txt", "n\n")
        before = self.git("status", "--porcelain")
        stashes = self.git("stash", "list")
        sha = notify.record_turn_baseline("w:1.2", self.repo, self.cfg)
        self.assertTrue(sha)
        self.assertEqual(self.git("status", "--porcelain"), before)
        self.assertEqual(self.git("stash", "list"), stashes)
        self.assertEqual(self.git("rev-parse", "refs/bergr/turns/w_1_2").strip(), sha)
        with open(os.path.join(os.path.dirname(self.cfg), "turns", "w_1_2.json")) as f:
            saved = json.load(f)
        self.assertEqual(saved["sha"], sha)
        self.assertEqual(saved["untracked"], ["new.txt"])
        blob = self.git("cat-file", "-p", "refs/bergr/turns-untracked/w_1_2")
        self.assertEqual(blob.split(), ["new.txt"])

    def test_clean_tree_uses_head_and_latest_wins(self):
        head = self.git("rev-parse", "HEAD").strip()
        self.assertEqual(notify.record_turn_baseline("t1", self.repo, self.cfg), head)
        self.write("a.txt", "x\n")
        second = notify.record_turn_baseline("t1", self.repo, self.cfg)
        self.assertNotEqual(second, head)
        self.assertEqual(self.git("rev-parse", "refs/bergr/turns/t1").strip(), second)

    def test_shortstat_text_and_new_files(self):
        self.write("new0.txt", "old untracked\n")
        notify.record_turn_baseline("t1", self.repo, self.cfg)
        self.assertIsNone(notify.turn_stat("t1", self.repo, self.cfg))
        self.write("a.txt", "one\nthree\nfour\n")
        self.write("new1.txt", "n\n")
        self.assertEqual(notify.turn_stat("t1", self.repo, self.cfg), "2 files, +2 \u22121")
        _, body = notify.format_alert(term(state="done", msg="Done."), "done", stat="2 files, +2 \u22121")
        self.assertTrue(body.endswith(" \u00b7 2 files, +2 \u22121"))

    def test_turn_stat_uses_the_baseline_folder(self):
        # The terminal sits in a plain folder (home); the agent works in the repo.
        plain = os.path.join(self.dir, "home")
        os.makedirs(plain)
        notify.record_turn_baseline("t1", self.repo, self.cfg)
        self.write("a.txt", "one\nthree\n")
        self.assertEqual(notify.turn_stat("t1", plain, self.cfg), "1 file, +1 \u22121")

    def test_claude_folder_reads_the_conversation(self):
        home = os.path.join(self.dir, "h")
        os.makedirs(os.path.join(home, ".claude", "sessions"))
        os.makedirs(os.path.join(home, ".claude", "projects", "-h"))
        with open(os.path.join(home, ".claude", "sessions", "42.json"), "w") as f:
            json.dump({"sessionId": "abc-1", "cwd": home}, f)
        with open(os.path.join(home, ".claude", "projects", "-h", "abc-1.jsonl"), "w") as f:
            f.write(json.dumps({"type": "user", "cwd": home}) + "\n")
            f.write(json.dumps({"type": "assistant", "cwd": self.repo}) + "\n")
            f.write(json.dumps({"type": "summary"}) + "\n")
        self.assertEqual(notify.claude_folder(42, home=home), self.repo)
        self.assertIsNone(notify.claude_folder(7, home=home))

    def test_claude_blocked_until_retried_or_next_turn(self):
        home = os.path.join(self.dir, "hb")
        os.makedirs(os.path.join(home, ".claude", "sessions"))
        os.makedirs(os.path.join(home, ".claude", "projects", "-h"))
        with open(os.path.join(home, ".claude", "sessions", "5.json"), "w") as f:
            json.dump({"sessionId": "s-1"}, f)
        path = os.path.join(home, ".claude", "projects", "-h", "s-1.jsonl")
        call = lambda tid: {"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": tid, "name": "Bash", "input": {"command": "git push"}}]}}
        denied = {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "t1", "is_error": True,
                  "content": notify.BLOCKED + " Reason: [Destructive or Unwanted Actions]."}]}}
        def write(*rows):
            with open(path, "w") as f:
                f.write("".join(json.dumps(r) + "\n" for r in rows))
        write({"type": "user", "message": {"content": "push it"}}, call("t1"), denied)
        self.assertEqual(notify.claude_blocked(5, home=home), "git push")
        write({"type": "user", "message": {"content": "push it"}}, call("t1"), denied, call("t2"))
        self.assertIsNone(notify.claude_blocked(5, home=home))
        write(call("t1"), denied, {"type": "user", "message": {"content": "never mind"}})
        self.assertIsNone(notify.claude_blocked(5, home=home))

    def test_skips_without_repo_or_baseline(self):
        plain = os.path.join(self.dir, "plain")
        os.makedirs(plain)
        self.assertIsNone(notify.record_turn_baseline("t1", plain, self.cfg))
        self.assertIsNone(notify.record_turn_baseline("t1", None, self.cfg))
        self.assertIsNone(notify.turn_stat("t1", plain, self.cfg))
        self.assertIsNone(notify.turn_stat("nobaseline", self.repo, self.cfg))
        _, body = notify.format_alert(term(state="done"), "done", stat=None)
        self.assertNotIn("\u00b7", body)

    def test_timeout_returns_none(self):
        def boom(*a, **k):
            raise subprocess.TimeoutExpired("git", 1)
        with mock.patch.object(notify.subprocess, "run", boom):
            self.assertIsNone(notify.record_turn_baseline("t1", self.repo, self.cfg))
            self.assertIsNone(notify.turn_stat("t1", self.repo, self.cfg))

    def test_started_working_detects_transitions_only(self):
        def st(state):
            return {"last": {"a": (state, 1)}}
        self.assertEqual(notify.started_working(st("done"), st("working")), ["a"])
        self.assertEqual(notify.started_working(st("working"), st("working")), [])
        self.assertEqual(notify.started_working({"last": {}}, st("working")), [])



# ---- Remote answers (answering from a notification through the relay)

VECTOR = json.load(open(os.path.join(HERE, "..", "bergrTests", "answer-envelope-vector.json"), encoding="utf-8"))
MENU = "\n".join(["Bash command", "", "  npm test", "", "Do you want to proceed?", "❯ 1. Yes",
                  "  2. Yes, and don't ask again", "  3. No, and tell Claude what to do differently",
                  "", "Esc to cancel"])


class FakeHC:
    def __init__(self, term, text):
        self.term, self.text, self.pressed, self.reads = term, text, [], 0

    def __call__(self, args):
        if args[1] == "get":
            return json.dumps(self.term)
        if args[1] == "read":
            self.reads += 1
            return json.dumps({"text": self.text})
        if args[1] == "keys":
            self.pressed.append(args[3:])
            return ""
        raise AssertionError(args)


class RemoteAnswerTests(unittest.TestCase):
    KEY = bytes(range(64))
    MACHINE = "UUID-1"

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.path = os.path.join(self.dir, "remote-answers.json")
        self.term = term(msg="Bash: npm test")
        self.aid = notify.record_pending_answer(self.path, "t1", 5, "Bash: npm test", now=1000)

    def item(self, choice="yes", aid=None, machine=None, key=None):
        aid = aid or self.aid
        return {"id": aid, "e": notify.seal_answer(key or self.KEY, machine or self.MACHINE, aid, choice)}

    def run_answer(self, item, hc=None, cfg=None, now=1100):
        hc = hc or FakeHC(self.term, MENU)
        return notify.remote_answer(cfg or {}, self.MACHINE, self.KEY, item, self.path, hc, now), hc

    def test_shared_vector_opens_and_seals_identically(self):
        key, nonce = bytes(range(64)), base64.b64decode(VECTOR["nonce"])  # see "keyBytes"
        for c in VECTOR["cases"]:
            self.assertEqual(notify.open_answer(key, VECTOR["machine"], VECTOR["id"], c["e"]), c["choice"])
            self.assertEqual(notify.seal_answer(key, VECTOR["machine"], VECTOR["id"], c["choice"], nonce), c["e"])

    def test_tampered_wrong_machine_wrong_id_wrong_key_rejected(self):
        e = self.item()["e"]
        blob = bytearray(base64.b64decode(e))
        blob[20] ^= 1
        bad = base64.b64encode(bytes(blob)).decode()
        for args in [(self.KEY, self.MACHINE, self.aid, bad), (self.KEY, "UUID-2", self.aid, e),
                     (self.KEY, self.MACHINE, "f" * 32, e), (bytes(64), self.MACHINE, self.aid, e)]:
            with self.assertRaises(ValueError):
                notify.open_answer(*args)
        (out, _, _, _), hc = self.run_answer({"id": self.aid, "e": bad})
        self.assertEqual(out, "ignored")
        self.assertEqual(hc.pressed, [])

    def test_answers_yes_once(self):
        (out, label, rec, _), hc = self.run_answer(self.item("yes"))
        self.assertEqual((out, label), ("answered", "Yes"))
        self.assertEqual(hc.pressed, [["enter"]])
        (again, reason, _, _), hc2 = self.run_answer(self.item("yes"))
        self.assertEqual((again, reason), ("ignored", "already used"))
        self.assertEqual(hc2.pressed, [])

    def test_no_moves_to_no_option(self):
        (out, label, _, _), hc = self.run_answer(self.item("no"))
        self.assertEqual(out, "answered")
        self.assertTrue(label.startswith("No"))
        self.assertEqual(hc.pressed, [["down", "down", "enter"]])

    def test_expired_refused(self):
        (out, _, _, _), hc = self.run_answer(self.item(), now=1000 + notify.REMOTE_TTL + 1)
        self.assertEqual(out, "refused")
        self.assertEqual(hc.pressed, [])

    def test_unknown_id_ignored(self):
        (out, _, _, _), _ = self.run_answer(self.item(aid="a" * 32))
        self.assertEqual(out, "ignored")

    def test_turn_changed_refused(self):
        (out, _, _, _), hc = self.run_answer(self.item(), hc=FakeHC(term(msg="Bash: npm test", turn=6), MENU))
        self.assertEqual(out, "refused")
        self.assertEqual(hc.pressed, [])

    def test_question_changed_refused(self):
        (out, _, _, _), hc = self.run_answer(self.item(), hc=FakeHC(term(msg="Bash: npm run build"), MENU))
        self.assertEqual(out, "refused")
        self.assertEqual(hc.pressed, [])

    def test_dangerous_on_screen_refused(self):
        screen = MENU.replace("npm test", "rm -rf /")
        (out, _, _, _), hc = self.run_answer(self.item(), hc=FakeHC(self.term, screen))
        self.assertEqual(out, "refused")
        self.assertEqual(hc.pressed, [])

    def test_ask_pattern_refused(self):
        cfg = {"devices": [{"askPatterns": ["npm *"]}]}
        (out, _, _, _), hc = self.run_answer(self.item(), cfg=cfg)
        self.assertEqual(out, "refused")
        self.assertEqual(hc.pressed, [])

    def test_unknown_prompt_refused(self):
        (out, _, _, _), hc = self.run_answer(self.item(), hc=FakeHC(self.term, "just some text"))
        self.assertEqual(out, "refused")
        self.assertEqual(hc.pressed, [])

    def test_y_n_prompt(self):
        self.assertEqual(notify.answer_keys(["Overwrite file? (y/n)"], "no"), (["n"], "No"))
        self.assertIsNone(notify.answer_keys(["Overwrite file?"], "yes"))

    def test_poll_logs_and_confirms(self):
        sent, logp = [], os.path.join(self.dir, "auto.json")
        dev = {"relay": "https://r", "secret": "s", "key": base64.b64encode(self.KEY).decode(), "host_id": self.MACHINE}
        hc = FakeHC(self.term, MENU)
        notify.poll_answers({"devices": [dev]}, self.path, "pop-os", lambda *a: sent.append(a),
                            fetch=lambda d, m: [self.item()], runner=hc, log_path=logp, now=1100)
        self.assertEqual(sent[0][0], "Answered Yes on pop-os")
        entry = json.load(open(logp))[0]
        self.assertEqual((entry["source"], entry["answer"]), ("notification-remote", "Yes"))

    def test_poll_refusal_pushes_open_bergr(self):
        sent = []
        dev = {"relay": "https://r", "secret": "s", "key": base64.b64encode(self.KEY).decode(), "host_id": self.MACHINE}
        notify.poll_answers({"devices": [dev]}, self.path, "pop-os", lambda *a: sent.append(a),
                            fetch=lambda d, m: [self.item()], runner=FakeHC(term(turn=9), MENU),
                            log_path=os.path.join(self.dir, "a.json"), now=1100)
        self.assertEqual(sent[0][0], "Couldn't answer — open Bergr")

    def test_alert_carries_answer_id(self):
        blob = notify.encrypt_alert(self.KEY, "t", "b", q={"title": "x", "options": ["Yes", "No"], "keys": True},
                                    a=self.aid)
        self.assertEqual(notify.decrypt_alert(self.KEY, base64.b64decode(blob))["a"], self.aid)

class ScheduledSendTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "scheduled.json")

    def tearDown(self):
        self.dir.cleanup()

    def write(self, items):
        with open(self.path, "w") as f:
            json.dump(items, f)

    def test_sends_due_entries_and_keeps_later_ones(self):
        self.write([{"id": "a", "address": "t1", "at": 100, "text": "continue"},
                    {"id": "b", "address": "t2", "at": 500, "text": "later"}])
        ran = []
        alerts = notify.run_scheduled(self.path, "mac", runner=lambda a: ran.append(a) or "", now=200)
        self.assertEqual(ran, [["hc", "send", "t1", "continue"]])
        self.assertEqual(alerts[0]["title"], "Sent \u201ccontinue\u201d on mac")
        with open(self.path) as f:
            self.assertEqual([i["id"] for i in json.load(f)], ["b"])

    def test_failure_alerts_and_stale_entries_drop(self):
        self.write([{"id": "a", "address": "t1", "at": 100, "text": "go"},
                    {"id": "old", "address": "t1", "at": 0, "text": "x"}])
        def fail(_):
            raise RuntimeError("no such terminal")
        alerts = notify.run_scheduled(self.path, "", runner=fail, now=86500)
        self.assertEqual([a["state"] for a in alerts], ["error"])
        with open(self.path) as f:
            self.assertEqual(json.load(f), [])

    def test_missing_file_is_quiet(self):
        self.assertEqual(notify.run_scheduled(self.path, "mac", runner=lambda a: "", now=1), [])


class WatchdogTests(unittest.TestCase):
    class Screen:
        def __init__(self):
            self.text, self.reads = "a", 0

        def __call__(self, address):
            self.reads += 1
            return self.text

    def setUp(self):
        self.screen = self.Screen()
        self.wd = notify.Watchdog(reader=self.screen, host="pop-os")
        self.terms = {"t1": term("t1", state="working", msg="")}
        self.cfg = {"devices": [{"relay": "r", "secret": "s", "prefs": {}}]}

    def stuck(self, now, minutes=20):
        return self.wd.stuck(self.terms, minutes, now)

    def test_pref_minutes(self):
        self.assertEqual(notify.pref_minutes(self.cfg, "stuckMinutes", 20), 20)
        cfg = {"devices": [{"prefs": {"stuckMinutes": 0}}, {"prefs": {"stuckMinutes": 10}}, {}]}
        self.assertEqual(notify.pref_minutes(cfg, "stuckMinutes", 20), 10)
        self.assertEqual(notify.pref_minutes({"devices": [{"prefs": {"stuckMinutes": 0}}]}, "stuckMinutes", 20), 0)
        self.assertEqual(notify.pref_minutes({}, "stuckMinutes", 20), 0)

    def test_stall_alerts_once_and_rearms(self):
        self.assertEqual(self.stuck(0), [])
        self.assertEqual(self.stuck(19 * 60), [])
        alerts = self.stuck(20 * 60)
        self.assertEqual(len(alerts), 1)
        self.assertEqual(alerts[0]["title"], "Claude on pop-os has shown no output for 20 min")
        self.assertEqual(alerts[0]["state"], "error")
        self.assertEqual(self.stuck(40 * 60), [])  # once per stall
        self.screen.text = "b"  # output: re-armed
        self.assertEqual(self.stuck(41 * 60), [])
        self.assertEqual(len(self.stuck(61 * 60)), 1)

    def test_leaving_working_rearms(self):
        self.stuck(0)
        self.assertEqual(len(self.stuck(20 * 60)), 1)
        self.wd.stuck({"t1": term("t1", state="done")}, 20, 21 * 60)
        self.stuck(22 * 60)
        self.assertEqual(self.stuck(41 * 60), [])
        self.assertEqual(len(self.stuck(42 * 60)), 1)

    def test_sampling_throttled_and_only_while_working(self):
        self.stuck(0)
        self.stuck(10)
        self.stuck(59)
        self.assertEqual(self.screen.reads, 1)
        self.stuck(60)
        self.assertEqual(self.screen.reads, 2)
        self.wd.stuck({"t1": term("t1", state="done")}, 20, 200)
        self.assertEqual(self.screen.reads, 2)

    def test_off_and_unreadable(self):
        self.assertEqual(self.stuck(0, minutes=0), [])
        self.assertEqual(self.stuck(99999, minutes=0), [])
        self.assertEqual(self.screen.reads, 0)
        self.screen.text = None
        self.assertEqual(self.stuck(0), [])

    def test_stuck_alert_respects_quiet_hours_and_mute(self):
        a = self.stuck(0) or self.stuck(20 * 60)
        self.assertEqual(a[0]["state"], "error")
        quiet = {"quiet": {"start": 0, "end": 1439}, "tz": "UTC"}
        self.assertEqual(notify.prefs_verdict(quiet, "error", "t1", now=3600), "quiet")
        self.assertFalse(notify.prefs_allow({"muted": ["t1"]}, "error", "t1"))
        self.assertFalse(notify.prefs_allow({"kinds": {"error": False}}, "error", "t1"))

    def test_renudge_once_per_turn_with_new_answer_id(self):
        blocked = {"t1": term("t1", state="blocked", turn=5)}
        alert = {"address": "t1", "turn": 5, "state": "blocked", "title": "Claude needs you on pop-os", "body": "b"}
        q = {"title": "Run ls?", "options": ["Yes", "No"], "keys": True}
        self.wd.note_alert(alert, q, now=0)
        self.assertEqual(self.wd.renudge(blocked, 30, 29 * 60), [])
        out = self.wd.renudge(blocked, 30, 30 * 60)
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["title"], "Still waiting: Run ls?")
        self.assertEqual(out[0]["q"], q)
        self.assertEqual(self.wd.renudge(blocked, 30, 90 * 60), [])
        # Sent through the alert builder: a fresh answerID each time.
        d = tempfile.mkdtemp()
        path = os.path.join(d, "r.json")
        sent = []
        with mock.patch.object(notify, "send_alert", lambda *a, **k: sent.append(k)):
            notify.send_with_answer({}, alert, q, "h", None, None, path)
            notify.send_with_answer({}, out[0], out[0]["q"], "h", None, None, path)
        self.assertNotEqual(sent[0]["a"], sent[1]["a"])
        self.assertEqual(sent[1]["q"], q)

    def test_renudge_dropped_when_turn_moves_or_pref_off(self):
        alert = {"address": "t1", "turn": 5, "state": "blocked", "title": "x", "body": "b"}
        self.wd.note_alert(alert, None, now=0)
        self.assertEqual(self.wd.renudge({"t1": term("t1", state="blocked", turn=6)}, 30, 3600), [])
        self.wd.note_alert(alert, None, now=0)
        self.assertEqual(self.wd.renudge({"t1": term("t1", state="blocked", turn=5)}, 0, 3600), [])

    def test_windows_uses_no_posix_calls(self):
        src = open(SCRIPT).read()
        start = src.index("class Watchdog:")
        block = src[start:src.index("# Turn baselines (v18)")]
        for banned in ("os.fork", "signal.", "fcntl", "os.getuid", "/dev/", "pgrep", "os.kill"):
            self.assertNotIn(banned, block)
        with mock.patch.object(notify.os, "name", "nt"):
            self.wd.stuck(self.terms, 20, 0)
        self.assertEqual(notify.NO_WINDOW, {"creationflags": 0x08000000} if os.name == "nt" else {})

    def test_digest_reads_hc_with_no_window_runner(self):
        calls = []
        def runner(args):
            calls.append(args)
            return json.dumps({"text": "hello"})
        self.assertEqual(notify.screen_digest("t1", runner), notify.screen_digest("t1", runner))
        self.assertEqual(calls[0], ["hc", "read", "t1", "--json"])
        self.assertIsNone(notify.screen_digest("t1", lambda a: 1 / 0))


if __name__ == "__main__":
    unittest.main()
