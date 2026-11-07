"""Executes the real run.sh and the cron snippet in a sandbox with fake python3/crontab."""
import sys
sys.dont_write_bytecode = True
import os
import pathlib
import shutil
import subprocess
import tempfile
import time
import unittest

RES = pathlib.Path(__file__).resolve().parents[2] / "Sources" / "HerdrKit" / "Resources"


def count_procs(pattern):
    out = subprocess.run(["ps", "-axo", "command="], capture_output=True, text=True).stdout
    return sum(1 for line in out.splitlines() if pattern in line and "grep" not in line)


class RunScriptTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="hn-", dir="/tmp")
        self.d = os.path.join(self.root, "herdr-notify")
        os.makedirs(self.d)
        shutil.copy(RES / "run.sh", os.path.join(self.d, "run.sh"))
        os.chmod(os.path.join(self.d, "run.sh"), 0o755)
        # Fake daemon: python3 that writes its pid like herdr-notify does and sleeps.
        self.bin = os.path.join(self.root, "bin")
        os.makedirs(self.bin)
        with open(os.path.join(self.bin, "python3"), "w") as f:
            f.write('#!/bin/sh\necho $$ > "$(dirname "$3")/herdr-notify.pid"\nsleep 30\n')
        os.chmod(os.path.join(self.bin, "python3"), 0o755)
        self.env = dict(os.environ, PATH=self.bin + ":/usr/bin:/bin")

    def tearDown(self):
        subprocess.run(["pkill", "-f", self.root], capture_output=True)
        time.sleep(0.1)
        subprocess.run(["pkill", "-f", self.root], capture_output=True)
        shutil.rmtree(self.root, ignore_errors=True)

    def run_sh(self):
        return subprocess.Popen(["/bin/sh", os.path.join(self.d, "run.sh")], env=self.env,
                                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def wait_pidfile(self, name, timeout=3):
        p = os.path.join(self.d, name)
        end = time.time() + timeout
        while time.time() < end:
            if os.path.exists(p) and open(p).read().strip():
                return True
            time.sleep(0.05)
        return False

    def test_concurrentStartsGiveOneSupervisor(self):
        procs = [self.run_sh() for _ in range(5)]
        for p in procs:
            p.wait(5)
        self.assertTrue(self.wait_pidfile("herdr-notify.pid"))
        time.sleep(0.5)
        self.assertEqual(count_procs(self.d + "/run.sh --supervise"), 1)
        self.assertEqual(count_procs(self.d + "/herdr-notify.py --config"), 1)

    def test_secondStartIsNoop(self):
        self.run_sh().wait(5)
        self.assertTrue(self.wait_pidfile("supervisor.pid"))
        self.run_sh().wait(5)
        time.sleep(0.3)
        self.assertEqual(count_procs(self.d + "/run.sh --supervise"), 1)

    def test_stalePidOfUnrelatedProcessIsIgnored(self):
        other = subprocess.Popen(["sleep", "30"])  # alive, but not our supervisor
        try:
            with open(os.path.join(self.d, "supervisor.pid"), "w") as f:
                f.write(str(other.pid))
            self.run_sh().wait(5)
            time.sleep(0.5)
            self.assertEqual(count_procs(self.d + "/run.sh --supervise"), 1)
        finally:
            other.kill()

    def test_staleLockDoesNotBlockForever(self):
        lock = os.path.join(self.d, "start.lock")
        os.mkdir(lock)
        old = time.time() - 300
        os.utime(lock, (old, old))
        self.run_sh().wait(5)
        self.assertTrue(self.wait_pidfile("supervisor.pid"))


class CronSnippetTests(unittest.TestCase):
    """The crontab update used by the installer, run with `set -e` like the real install script."""

    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="hc-", dir="/tmp")
        self.tab = os.path.join(self.root, "tab")
        bin_ = os.path.join(self.root, "bin")
        os.makedirs(bin_)
        with open(os.path.join(bin_, "crontab"), "w") as f:
            f.write('#!/bin/sh\nT=%s\nif [ "$1" = "-l" ]; then [ -f "$T" ] || { echo "no crontab for u" >&2; exit 1; }; cat "$T"; '
                    'elif [ "$1" = "-" ]; then cat > "$T.new" && mv "$T.new" "$T"; fi\n' % self.tab)
        os.chmod(os.path.join(bin_, "crontab"), 0o755)
        self.env = dict(os.environ, PATH=bin_ + ":/usr/bin:/bin")
        self.snippet = (RES / "cron-install.sh").read_text()

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def install(self):
        script = 'set -e\nD=/home/u/.config/herdr-notify\nN=herdr-notify\n' + self.snippet
        r = subprocess.run(["/bin/sh", "-c", script], env=self.env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        return open(self.tab).read().splitlines()

    def ours(self, lines):
        return [l for l in lines if l.endswith("# herdr-notify")]

    def test_noCrontabYet(self):
        lines = self.install()
        self.assertEqual(len(self.ours(lines)), 2)
        self.assertTrue(any(l.startswith("@reboot ") for l in lines))

    def test_onlyOwnLinesAreReplacedNotDuplicated(self):
        self.install()
        lines = self.install()
        self.assertEqual(len(self.ours(lines)), 2)
        self.assertEqual(len(lines), 2)

    def test_foreignLinesPreserved(self):
        with open(self.tab, "w") as f:
            f.write("0 3 * * * /usr/bin/backup # nightly\nMAILTO=me@example.org\n")
        lines = self.install()
        self.assertEqual(lines[:2], ["0 3 * * * /usr/bin/backup # nightly", "MAILTO=me@example.org"])
        self.assertEqual(len(self.ours(lines)), 2)


if __name__ == "__main__":
    unittest.main()
