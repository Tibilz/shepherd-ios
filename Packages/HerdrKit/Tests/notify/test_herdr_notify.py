"""Tests for herdr-notify. Run: python3 -m unittest discover -s Packages/HerdrKit/Tests/notify -v"""
import sys
sys.dont_write_bytecode = True  # keep the bundled resource dir clean
import base64
import importlib.util
import json
import os
import pathlib
import tempfile
import time
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "Sources" / "HerdrKit" / "Resources" / "herdr-notify.py"


def load_module():
    spec = importlib.util.spec_from_file_location("herdr_notify", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


hn = load_module()


def agent(pane, status, name=None, title=None, display=None):
    return {"pane_id": pane, "agent_status": status, "name": name, "title": title, "display_agent": display}


def cfg(**over):
    c = json.loads(json.dumps(hn.DEFAULT_CONFIG))
    c.update({"ntfyTopic": "herdr-test", "serverId": "6B7D0C1E-2F3A-4B5C-8D9E-0F1A2B3C4D5E", "serverName": "VPS 2"})
    for k, v in over.items():
        c[k] = v
    return c


class TrackerTests(unittest.TestCase):
    def test_firstUpdateIsSilent(self):
        t = hn.Tracker()
        self.assertEqual(t.update([agent("w1:p1", "blocked", "rev")], 0), [])

    def test_blockedNotifiesOnce(self):
        t = hn.Tracker()
        t.update([agent("w1:p1", "working", "rev")], 0)
        n = t.update([agent("w1:p1", "blocked", "rev")], 1)
        self.assertEqual([(x.key, x.kind) for x in n], [("rev", "blocked")])
        self.assertEqual(t.update([agent("w1:p1", "blocked", "rev")], 2), [])

    def test_doneAfterWorking(self):
        t = hn.Tracker()
        t.update([agent("w1:p1", "working", "rev")], 0)
        n = t.update([agent("w1:p1", "done", "rev")], 1)
        self.assertEqual([x.kind for x in n], ["done"])

    def test_idleNeedsFiveSeconds(self):
        t = hn.Tracker()
        t.update([agent("w1:p1", "working", "rev")], 0)
        self.assertEqual(t.update([agent("w1:p1", "idle", "rev")], 10), [])
        self.assertEqual(t.update([agent("w1:p1", "idle", "rev")], 12), [])
        n = t.update([agent("w1:p1", "idle", "rev")], 15.5)
        self.assertEqual([x.kind for x in n], ["idle"])
        self.assertEqual(t.update([agent("w1:p1", "idle", "rev")], 30), [])

    def test_idleFlappingIgnored(self):
        t = hn.Tracker()
        t.update([agent("w1:p1", "working", "rev")], 0)
        t.update([agent("w1:p1", "idle", "rev")], 1)
        t.update([agent("w1:p1", "working", "rev")], 3)
        self.assertEqual(t.update([agent("w1:p1", "working", "rev")], 9), [])

    def test_newAgentAfterStartNotifies(self):
        t = hn.Tracker()
        t.update([], 0)
        n = t.update([agent("w2:p1", "blocked", None)], 1)
        self.assertEqual([(x.key, x.kind) for x in n], [("w2:p1", "blocked")])

    def test_vanishedAgentForgotten(self):
        t = hn.Tracker()
        t.update([agent("w1:p1", "blocked", "rev")], 0)
        t.update([], 1)
        n = t.update([agent("w1:p1", "blocked", "rev")], 2)
        self.assertEqual([x.kind for x in n], ["blocked"])

    def test_keyFallsBackToPaneAndNameToDisplay(self):
        t = hn.Tracker()
        t.update([agent("w1:p1", "working", None, display="Claude Code")], 0)
        n = t.update([agent("w1:p1", "blocked", None, display="Claude Code")], 1)[0]
        self.assertEqual(n.key, "w1:p1")
        self.assertEqual(n.name, "Claude Code")


class FilterTests(unittest.TestCase):
    N = hn.Notice(key="rev", name="rev", kind="blocked", title=None, pane_id="w1:p1")

    def test_perAgentSwitch(self):
        self.assertFalse(hn.allowed(cfg(agents={"rev": False}), self.N))
        self.assertTrue(hn.allowed(cfg(agents={"other": False}), self.N))
        self.assertFalse(hn.allowed(cfg(defaultAgentEnabled=False), self.N))
        self.assertTrue(hn.allowed(cfg(defaultAgentEnabled=False, agents={"rev": True}), self.N))

    def test_globalSwitch(self):
        self.assertFalse(hn.allowed(cfg(enabled=False), self.N))

    def test_eventSwitches(self):
        self.assertFalse(hn.allowed(cfg(events={"blocked": False, "done": True, "idle": True}), self.N))
        idle = hn.Notice(key="rev", name="rev", kind="idle", title=None, pane_id="w1:p1")
        self.assertFalse(hn.allowed(cfg(), idle))
        self.assertTrue(hn.allowed(cfg(events={"blocked": True, "done": True, "idle": True}), idle))


class ConfigTests(unittest.TestCase):
    def test_defaultsMerged(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "config.json")
            with open(p, "w") as f:
                json.dump({"ntfyTopic": "herdr-x", "events": {"idle": True}}, f)
            c = hn.ConfigWatcher(p).current()
            self.assertEqual(c["ntfyTopic"], "herdr-x")
            self.assertTrue(c["events"]["idle"])
            self.assertTrue(c["events"]["blocked"])
            self.assertTrue(c["enabled"])

    def test_brokenConfigKeepsPrevious(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "config.json")
            with open(p, "w") as f:
                json.dump({"ntfyTopic": "herdr-good"}, f)
            w = hn.ConfigWatcher(p)
            self.assertEqual(w.current()["ntfyTopic"], "herdr-good")
            time.sleep(0.01)
            with open(p, "w") as f:
                f.write("{kaputt")
            os.utime(p, (time.time() + 5, time.time() + 5))
            self.assertEqual(w.current()["ntfyTopic"], "herdr-good")

    def test_changeIsPickedUp(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "config.json")
            with open(p, "w") as f:
                json.dump({"ntfyTopic": "a"}, f)
            w = hn.ConfigWatcher(p)
            w.current()
            with open(p, "w") as f:
                json.dump({"ntfyTopic": "b"}, f)
            os.utime(p, (time.time() + 5, time.time() + 5))
            self.assertEqual(w.current()["ntfyTopic"], "b")


class MessageTests(unittest.TestCase):
    def test_blockedMessage(self):
        n = hn.Notice(key="rev", name="rev", kind="blocked", title="Review", pane_id="w1:p1")
        m = hn.build_message(cfg(), n)
        self.assertEqual(m["url"], "https://ntfy.sh/herdr-test")
        self.assertEqual(m["headers"]["Priority"], "high")
        self.assertEqual(m["headers"]["Tags"], "warning")
        self.assertIn("VPS 2", m["body"])
        self.assertIn("Review", m["body"])
        self.assertEqual(m["headers"]["Click"], "herdrapp://server/6B7D0C1E-2F3A-4B5C-8D9E-0F1A2B3C4D5E/agent/rev")
        self.assertNotIn("Authorization", m["headers"])

    def test_umlautTitleIsEncoded(self):
        n = hn.Notice(key="prüfer", name="Prüfer", kind="done", title=None, pane_id="w1:p1")
        m = hn.build_message(cfg(), n)
        title = m["headers"]["Title"]
        self.assertTrue(title.startswith("=?UTF-8?B?"))
        decoded = base64.b64decode(title[len("=?UTF-8?B?"):-2]).decode()
        self.assertEqual(decoded, "“Prüfer” is done")
        title.encode("ascii")

    def test_asciiTitlePlain(self):
        n = hn.Notice(key="rev", name="rev", kind="idle", title=None, pane_id="w1:p1")
        # Typographic quotes make it non-ASCII, so it is always encoded; check decoded text.
        t = hn.build_message(cfg(), n)["headers"]["Title"]
        self.assertEqual(base64.b64decode(t[10:-2]).decode(), "“rev” is ready")

    def test_clickUrlEncodesTarget(self):
        n = hn.Notice(key="w1:p2", name="Codex", kind="blocked", title=None, pane_id="w1:p2")
        self.assertTrue(hn.build_message(cfg(), n)["headers"]["Click"].endswith("/agent/w1%3Ap2"))

    def test_tokenAddsAuthorization(self):
        n = hn.Notice(key="rev", name="rev", kind="blocked", title=None, pane_id="w1:p1")
        m = hn.build_message(cfg(ntfyToken="tk_123", ntfyServer="https://ntfy.example.org/"), n)
        self.assertEqual(m["headers"]["Authorization"], "Bearer tk_123")
        self.assertEqual(m["url"], "https://ntfy.example.org/herdr-test")


if __name__ == "__main__":
    unittest.main()


class LogThrottleTests(unittest.TestCase):
    def setUp(self):
        self.lines = []
        self.now = [1000.0]
        self.t = hn.LogThrottle(interval=300, clock=lambda: self.now[0], sink=self.lines.append)

    def test_repeatedErrorLoggedOnce(self):
        for _ in range(100):
            self.t.error("list", "agent.list fehlgeschlagen: ConnectionRefusedError")
        self.assertEqual(len(self.lines), 1)

    def test_summaryAfterInterval(self):
        for _ in range(10):
            self.t.error("list", "agent.list fehlgeschlagen")
        self.now[0] += 301
        self.t.error("list", "agent.list fehlgeschlagen")
        self.assertEqual(len(self.lines), 2)
        self.assertIn("10×", self.lines[1])

    def test_recoveryIsLoggedOnceAndResets(self):
        self.t.error("list", "kaputt")
        self.t.ok("list", "agent.list wieder in Ordnung")
        self.t.ok("list", "agent.list wieder in Ordnung")
        self.t.error("list", "kaputt")
        self.assertEqual(self.lines[1:], ["agent.list wieder in Ordnung", "kaputt"])

    def test_keysAreIndependent(self):
        self.t.error("list", "a")
        self.t.error("ntfy", "b")
        self.assertEqual(self.lines, ["a", "b"])
