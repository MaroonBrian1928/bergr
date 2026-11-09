#!/usr/bin/env python3 -I
"""Tests for bergr/Push/install-helper.py. Run: python3 -I scripts/test_install_helper.py"""
import base64, json, os, stat, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.join(HERE, "..", "bergr", "Push", "install-helper.py")
NOTIFY = os.path.join(HERE, "..", "bergr", "Push", "bergr-notify.py")
LOADER = "import base64,sys;exec(base64.b64decode(sys.argv.pop(1)))"


class InstallHelperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = os.path.join(self.tmp.name, "home")
        self.bin = os.path.join(self.tmp.name, "fakebin")
        os.makedirs(self.home)
        os.makedirs(self.bin)
        self.hc = os.path.join(self.bin, "hc")
        with open(self.hc, "w") as f:
            f.write("#!/bin/sh\n")
        os.chmod(self.hc, 0o755)
        with open(NOTIFY) as f:
            self.script = f.read()

    def run_op(self, op, os_name="linux", with_hc=True, **extra):
        env = {"HOME": self.home, "BERGR_HELPER_DRY_RUN": "1", "BERGR_HELPER_OS": os_name,
               "PATH": (self.bin + ":" if with_hc else "") + "/usr/bin:/bin", "SHELL": "/nonexistent"}
        args = base64.b64encode(json.dumps(dict(op=op, **extra)).encode()).decode()
        installer = base64.b64encode(open(INSTALLER, "rb").read()).decode()
        out = subprocess.run([sys.executable, "-I", "-c", LOADER, installer, args], env=env,
                             capture_output=True, text=True, check=True).stdout
        self.assertEqual(len(out.strip().splitlines()), 1)
        return json.loads(out)

    def path(self, *p):
        return os.path.join(self.home, *p)

    def test_linux_install(self):
        r = self.run_op("install", script=self.script)
        self.assertTrue(r["ok"])
        self.assertEqual(r["version"], 1)
        script = self.path(".local", "bin", "bergr-notify")
        self.assertEqual(stat.S_IMODE(os.stat(script).st_mode), 0o755)
        unit = open(self.path(".config", "systemd", "user", "bergr-notify.service")).read()
        self.assertIn("Environment=PATH=" + self.bin + ":/usr/local/bin:/usr/bin:/bin", unit)
        self.assertIn("ExecStart=/usr/bin/env python3 -I %h/.local/bin/bergr-notify", unit)
        self.assertIn("Restart=always", unit)
        self.assertIn("systemctl --user daemon-reload", r["planned"])
        self.assertIn("systemctl --user enable --now bergr-notify", r["planned"])
        self.assertIn("loginctl enable-linger", r["planned"])

    def test_darwin_install(self):
        r = self.run_op("install", os_name="darwin", script=self.script)
        self.assertTrue(r["ok"])
        plist = open(self.path("Library", "LaunchAgents", "dev.bergr.notify.plist")).read()
        self.assertIn("<string>-I</string>", plist)
        self.assertIn(self.path(".local", "bin", "bergr-notify"), plist)
        self.assertIn(self.bin + ":/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin", plist)
        self.assertIn("bergr-notify.log", plist)
        self.assertTrue(any(c.startswith("launchctl bootstrap gui/") for c in r["planned"]))

    def test_status(self):
        r = self.run_op("status")
        self.assertFalse(r["installed"])
        self.assertIsNone(r["version"])
        self.run_op("install", script=self.script)
        r = self.run_op("status")
        self.assertTrue(r["installed"])
        self.assertEqual(r["version"], 1)
        self.assertEqual(r["os"], "linux")

    def test_uninstall_keeps_config(self):
        self.run_op("install", script=self.script)
        cfg = self.path(".config", "bergr", "push.json")
        os.makedirs(os.path.dirname(cfg))
        with open(cfg, "w") as f:
            f.write("{}")
        r = self.run_op("uninstall")
        self.assertTrue(r["ok"])
        self.assertFalse(os.path.exists(self.path(".local", "bin", "bergr-notify")))
        self.assertFalse(os.path.exists(self.path(".config", "systemd", "user", "bergr-notify.service")))
        self.assertTrue(os.path.exists(cfg))
        self.assertTrue(self.run_op("uninstall")["ok"])  # idempotent

    def test_missing_hc(self):
        os.remove(self.hc)
        r = self.run_op("install", script=self.script, with_hc=False)
        self.assertEqual(r, {"ok": False, "error": "hc not found"})


if __name__ == "__main__":
    unittest.main()
