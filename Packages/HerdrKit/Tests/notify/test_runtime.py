"""Runtime tests for herdr-notify with a fake herdr socket and a fake ntfy server."""
import sys
sys.dont_write_bytecode = True
import http.server
import json
import os
import socket
import tempfile
import threading
import time
import unittest

from test_herdr_notify import hn, agent


class FakeHerdr:
    """Unix-socket server speaking herdr's line protocol (agent.list + events.subscribe)."""

    def __init__(self, path):
        self.path = path
        self.agents = []
        self.list_calls = 0
        self.subscribers = []
        self.subscriptions = []  # params of every events.subscribe
        self.status_events_only = False  # like real herdr: status changes emit only pane.agent_status_changed
        self.lock = threading.Lock()
        self.srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.srv.bind(path)
        self.srv.listen(16)
        self.running = True
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while self.running:
            try:
                conn, _ = self.srv.accept()
            except OSError:
                return
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn):
        f = conn.makefile("rwb")
        line = f.readline()
        if not line:
            conn.close()
            return
        req = json.loads(line)
        if req["method"] == "events.subscribe":
            with self.lock:
                self.subscriptions.append(req["params"]["subscriptions"])
            f.write(json.dumps({"id": req["id"], "result": {"type": "subscription_started"}}).encode() + b"\n")
            f.flush()
            with self.lock:
                self.subscribers.append((conn, f))
            return
        if req["method"] == "agent.list":
            with self.lock:
                self.list_calls += 1
                agents = list(self.agents)
            f.write(json.dumps({"id": req["id"], "result": {"type": "agent_list", "agents": agents}}).encode() + b"\n")
        f.flush()
        conn.close()

    def set_agents(self, agents, emit=True):
        with self.lock:
            self.agents = agents
            subs = list(self.subscribers)
            wanted = self.subscriptions[-1] if self.subscriptions else []
        if not emit:
            return
        for conn, f in subs:
            try:
                if self.status_events_only:
                    for a in agents:
                        if {"type": "pane.agent_status_changed", "pane_id": a["pane_id"]} in wanted:
                            f.write(json.dumps({"event": "pane.agent_status_changed",
                                                "data": {"pane_id": a["pane_id"], "agent_status": a["agent_status"]}}).encode() + b"\n")
                else:
                    f.write(b'{"event":"pane_updated","data":{"type":"pane_updated"}}\n')
                f.flush()
            except OSError:
                pass

    def drop_subscribers(self):
        with self.lock:
            subs, self.subscribers = self.subscribers, []
        for conn, f in subs:
            try:
                conn.shutdown(socket.SHUT_RDWR)
                conn.close()
            except OSError:
                pass

    def stop(self):
        self.running = False
        self.drop_subscribers()
        self.srv.close()


class FakeNtfy:
    def __init__(self):
        self.received = []
        self.status = 200
        outer = self

        class H(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
                outer.received.append({"path": self.path, "body": body, "headers": dict(self.headers)})
                self.send_response(outer.status)
                self.end_headers()

            def log_message(self, *a):
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = "http://127.0.0.1:%d" % self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def stop(self):
        self.httpd.shutdown()


def wait_for(cond, timeout=5.0):
    end = time.time() + timeout
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.02)
    return cond()


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(dir="/tmp")  # short path: AF_UNIX limit
        self.sock = os.path.join(self.dir, "h.sock")
        self.herdr = FakeHerdr(self.sock)
        self.ntfy = FakeNtfy()
        self.cfg_path = os.path.join(self.dir, "config.json")
        self.write_cfg()
        self.stop = threading.Event()

    def tearDown(self):
        self.stop.set()
        if hasattr(self, "thread"):
            self.thread.join(5)
        self.herdr.stop()
        self.ntfy.stop()

    def write_cfg(self, **over):
        c = {"ntfyServer": self.ntfy.url, "ntfyTopic": "herdr-t", "socket": self.sock,
             "serverId": "S1", "serverName": "VPS"}
        c.update(over)
        with open(self.cfg_path, "w") as f:
            json.dump(c, f)
        os.utime(self.cfg_path, (time.time() + len(json.dumps(over)) + 1,) * 2)

    def start(self):
        self.thread = threading.Thread(target=hn.run, kwargs=dict(
            config_path=self.cfg_path, poll_interval=0.3, reconnect_delay=0.2, debounce=0.05, stop=self.stop), daemon=True)
        self.thread.start()

    def test_endToEndBlockedReachesNtfy(self):
        self.herdr.set_agents([agent("w1:p1", "working", "rev")], emit=False)
        self.start()
        self.assertTrue(wait_for(lambda: self.herdr.list_calls >= 1 and self.herdr.subscribers))
        self.herdr.set_agents([agent("w1:p1", "blocked", "rev")])
        self.assertTrue(wait_for(lambda: len(self.ntfy.received) == 1))
        r = self.ntfy.received[0]
        self.assertEqual(r["path"], "/herdr-t")
        self.assertEqual(r["headers"]["Priority"], "high")
        self.assertEqual(r["headers"]["Click"], "herdrapp://server/S1/agent/rev")
        time.sleep(0.8)
        self.assertEqual(len(self.ntfy.received), 1)

    def test_reconnectsWithoutReplayingState(self):
        self.herdr.set_agents([agent("w1:p1", "working", "rev")], emit=False)
        self.start()
        self.assertTrue(wait_for(lambda: self.herdr.subscribers))
        self.herdr.set_agents([agent("w1:p1", "blocked", "rev")])
        self.assertTrue(wait_for(lambda: len(self.ntfy.received) == 1))
        self.herdr.drop_subscribers()
        self.assertTrue(wait_for(lambda: self.herdr.subscribers, 3))
        self.herdr.set_agents([agent("w1:p1", "blocked", "rev")])
        time.sleep(0.8)
        self.assertEqual(len(self.ntfy.received), 1)
        self.herdr.set_agents([agent("w1:p1", "done", "rev")])
        self.assertTrue(wait_for(lambda: len(self.ntfy.received) == 2))

    def test_ntfyFailureDoesNotStopLoop(self):
        self.ntfy.status = 500
        self.herdr.set_agents([agent("w1:p1", "working", "rev")], emit=False)
        self.start()
        self.assertTrue(wait_for(lambda: self.herdr.subscribers))
        self.herdr.set_agents([agent("w1:p1", "blocked", "rev")])
        self.assertTrue(wait_for(lambda: len(self.ntfy.received) == 1))
        self.ntfy.status = 200
        self.herdr.set_agents([agent("w1:p1", "done", "rev")])
        self.assertTrue(wait_for(lambda: len(self.ntfy.received) == 2))
        self.assertTrue(self.thread.is_alive())

    def test_unreachableNtfyDoesNotStopLoop(self):
        self.write_cfg(ntfyServer="http://127.0.0.1:9")
        self.herdr.set_agents([agent("w1:p1", "working", "rev")], emit=False)
        self.start()
        self.assertTrue(wait_for(lambda: self.herdr.subscribers))
        self.herdr.set_agents([agent("w1:p1", "blocked", "rev")])
        time.sleep(0.5)
        self.write_cfg(ntfyServer=self.ntfy.url, x=1)
        self.herdr.set_agents([agent("w1:p1", "done", "rev")])
        self.assertTrue(wait_for(lambda: len(self.ntfy.received) == 1))
        self.assertTrue(self.thread.is_alive())

    def test_disabledSendsNothing(self):
        self.write_cfg(enabled=False)
        self.herdr.set_agents([agent("w1:p1", "working", "rev")], emit=False)
        self.start()
        self.assertTrue(wait_for(lambda: self.herdr.subscribers))
        self.herdr.set_agents([agent("w1:p1", "blocked", "rev")])
        time.sleep(0.8)
        self.assertEqual(self.ntfy.received, [])

    def test_configChangeAppliesLive(self):
        self.herdr.set_agents([agent("w1:p1", "working", "rev")], emit=False)
        self.start()
        self.assertTrue(wait_for(lambda: self.herdr.subscribers))
        self.write_cfg(agents={"rev": False})
        time.sleep(0.1)
        self.herdr.set_agents([agent("w1:p1", "blocked", "rev")])
        time.sleep(0.8)
        self.assertEqual(self.ntfy.received, [])

    def test_subscribesToStatusChangesPerAgentPane(self):
        self.herdr.status_events_only = True
        self.herdr.set_agents([agent("w1:p1", "working", "rev")], emit=False)
        self.start()
        want = {"type": "pane.agent_status_changed", "pane_id": "w1:p1"}
        self.assertTrue(wait_for(lambda: self.herdr.subscriptions and want in self.herdr.subscriptions[-1]))
        self.assertTrue(wait_for(lambda: self.herdr.subscribers))
        time.sleep(0.1)
        self.herdr.set_agents([agent("w1:p1", "blocked", "rev")])
        # Must arrive via the event, well before the 0.3 s poll would matter: use a long poll interval.
        self.assertTrue(wait_for(lambda: len(self.ntfy.received) == 1, 2))

    def test_resubscribesWhenNewAgentAppears(self):
        self.herdr.status_events_only = True
        self.herdr.set_agents([agent("w1:p1", "working", "rev")], emit=False)
        self.start()
        self.assertTrue(wait_for(lambda: self.herdr.subscribers))
        self.herdr.set_agents([agent("w1:p1", "working", "rev"), agent("w2:p1", "working", "b")], emit=False)
        want = {"type": "pane.agent_status_changed", "pane_id": "w2:p1"}
        self.assertTrue(wait_for(lambda: self.herdr.subscriptions and want in self.herdr.subscriptions[-1], 3))

    def test_herdrDownAtStartRecovers(self):
        self.herdr.stop()
        os.unlink(self.sock)
        self.start()
        time.sleep(0.5)
        self.assertTrue(self.thread.is_alive())
        self.herdr = FakeHerdr(self.sock)
        self.herdr.set_agents([agent("w1:p1", "working", "rev")], emit=False)
        self.assertTrue(wait_for(lambda: self.herdr.subscribers, 3))
        self.herdr.set_agents([agent("w1:p1", "blocked", "rev")])
        self.assertTrue(wait_for(lambda: len(self.ntfy.received) == 1))


if __name__ == "__main__":
    unittest.main()
