#!/usr/bin/env python3 -I
"""Tests for bergr/Push/install-helper.py. Run: python3 -I scripts/test_install_helper.py"""
import base64, json, os, re, stat, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
INSTALLER = os.path.join(HERE, "..", "bergr", "Push", "install-helper.py")
NOTIFY = os.path.join(HERE, "..", "bergr", "Push", "bergr-notify.py")
NOTIFY_VERSION = int(re.search(r"^VERSION = (\d+)", open(NOTIFY).read(), re.M).group(1))
# As Bergr runs it (PushRegistration): one stdin line sets sys.argv and execs the installer.
# Not argv: the helper source outgrows Linux's 128 KB limit on a single argument.
LOADER = "import sys;exec(sys.stdin.buffer.readline())"


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
               "LOCALAPPDATA": os.path.join(self.home, "AppData", "Local"),
               "PATH": (self.bin + ":" if with_hc else "") + "/usr/bin:/bin", "SHELL": "/nonexistent"}
        args = base64.b64encode(json.dumps(dict(op=op, **extra)).encode()).decode()
        installer = base64.b64encode(open(INSTALLER, "rb").read()).decode()
        line = f"import base64,sys;sys.argv=['-c','{args}'];exec(base64.b64decode('{installer}'))\n"
        out = subprocess.run([sys.executable, "-I", "-c", LOADER], input=line, env=env,
                             capture_output=True, text=True, check=True).stdout
        self.assertEqual(len(out.strip().splitlines()), 1)
        return json.loads(out)

    def path(self, *p):
        return os.path.join(self.home, *p)

    def test_linux_install(self):
        r = self.run_op("install", script=self.script)
        self.assertTrue(r["ok"])
        self.assertEqual(r["version"], NOTIFY_VERSION)
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

    def test_windows_install_registers_scheduled_task(self):
        r = self.run_op("install", os_name="windows", script=self.script)
        self.assertTrue(r["ok"])
        script = self.path("AppData", "Local", "bergr", "bergr-notify.py")
        self.assertTrue(os.path.exists(script))
        create = next(c for c in r["planned"] if c.startswith("schtasks /Create"))
        task = self.path("AppData", "Local", "bergr", "bergr-notify-task.xml")
        self.assertEqual(create, "schtasks /Create /TN BergrNotify /XML " + task + " /F")
        definition = open(task, encoding="utf-16").read()
        self.assertIn("<LogonTrigger>", definition)
        self.assertIn("<LogonType>S4U</LogonType>", definition)
        self.assertIn("<Interval>PT5M</Interval>", definition)
        self.assertEqual(r["logon"], "S4U")
        self.assertIn("<RunLevel>LeastPrivilege</RunLevel>", definition)
        self.assertIn("<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>", definition)
        self.assertIn("<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>", definition)
        self.assertIn("<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>", definition)
        self.assertIn('<Arguments>-I "%s"</Arguments>' % script, definition)
        self.assertIn("schtasks /Run /TN BergrNotify", r["planned"])
        self.assertFalse(any("systemctl" in c or "launchctl" in c for c in r["planned"]))
        u = self.run_op("uninstall", os_name="windows")
        self.assertIn("schtasks /Delete /TN BergrNotify /F", u["planned"])
        self.assertFalse(os.path.exists(script))
        self.assertFalse(os.path.exists(task))

    def test_windows_finds_hc_in_herdr_core_folder(self):
        hc = self.path("AppData", "Local", "Programs", "herdr-core", "hc.exe")
        os.makedirs(os.path.dirname(hc))
        with open(hc, "w") as f:
            f.write("")
        os.chmod(hc, 0o755)
        r = self.run_op("install", os_name="windows", with_hc=False, script=self.script)
        self.assertTrue(r["ok"], r)
        os.remove(hc)
        r = self.run_op("install", os_name="windows", with_hc=False, script=self.script)
        self.assertEqual(r, {"ok": False, "error": "hc not found"})

    def test_status(self):
        r = self.run_op("status")
        self.assertFalse(r["installed"])
        self.assertIsNone(r["version"])
        self.run_op("install", script=self.script)
        r = self.run_op("status")
        self.assertTrue(r["installed"])
        self.assertEqual(r["version"], NOTIFY_VERSION)
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
