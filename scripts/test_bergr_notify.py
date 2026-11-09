#!/usr/bin/env python3 -I
"""Tests for bergr/Push/bergr-notify.py. Run: python3 -I scripts/test_bergr_notify.py"""
import base64, importlib.util, json, os, subprocess, tempfile, unittest

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
        self.assertEqual(state["last"], {"t1": "blocked"})

    def test_working_to_blocked_alerts(self):
        state, _ = notify.alerts_for(None, line(term(state="working", turn=5)))
        state, alerts = notify.alerts_for(state, line(term(state="blocked", turn=5)))
        self.assertEqual(len(alerts), 1)
        self.assertEqual(alerts[0]["address"], "t1")
        self.assertEqual(alerts[0]["title"], "Claude needs you")
        self.assertEqual(alerts[0]["body"], "~ / 1 — needs approval (permission)")

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


if __name__ == "__main__":
    unittest.main()
