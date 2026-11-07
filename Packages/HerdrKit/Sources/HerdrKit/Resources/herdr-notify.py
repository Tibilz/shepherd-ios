#!/usr/bin/env python3
"""herdr-notify: sends ntfy push notifications when herdr agents need attention.

Installed and configured by the herdr iPhone app. Standard library only (Python >= 3.8).
Config: <dir>/config.json (re-read on change). Never logs the ntfy topic or token.
"""
import argparse
import base64
import copy
import json
import os
import socket
import sys
import threading
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Dict, Iterator, List, Optional

DEFAULT_CONFIG = {
    "version": 1,
    "enabled": True,
    "ntfyServer": "https://ntfy.sh",
    "ntfyTopic": "",
    "ntfyToken": None,
    "socket": "",
    "serverId": "",
    "serverName": "herdr",
    "events": {"blocked": True, "done": True, "idle": False},
    "defaultAgentEnabled": True,
    "agents": {},
}

IDLE_SETTLE_SECONDS = 5.0


def log(msg: str) -> None:
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, file=sys.stderr, flush=True)


class LogThrottle:
    """Logs a repeating error once, then at most every `interval` seconds with a count,
    and one line when it recovers. Keeps the log small while herdr or ntfy is down."""

    def __init__(self, interval: float = 300.0, clock=time.monotonic, sink=None):
        self.interval = interval
        self.clock = clock
        self.sink = sink or log
        self._state: Dict[str, list] = {}  # key -> [last_logged_at, suppressed]

    def error(self, key: str, msg: str) -> None:
        st = self._state.get(key)
        now = self.clock()
        if st is None:
            self._state[key] = [now, 0]
            self.sink(msg)
        elif now - st[0] >= self.interval:
            self.sink("%s (%d× seit der letzten Meldung)" % (msg, st[1] + 1))
            st[0], st[1] = now, 0
        else:
            st[1] += 1

    def ok(self, key: str, msg: str) -> None:
        if self._state.pop(key, None) is not None:
            self.sink(msg)


# ---------------------------------------------------------------------------
# Config


def merge_config(raw: dict) -> dict:
    c = copy.deepcopy(DEFAULT_CONFIG)
    for k, v in raw.items():
        if k == "events" and isinstance(v, dict):
            c["events"].update(v)
        else:
            c[k] = v
    return c


class ConfigWatcher:
    """Reloads the config file when its mtime changes; keeps the last valid config on errors."""

    def __init__(self, path: str):
        self.path = path
        self._mtime = None
        self._config = copy.deepcopy(DEFAULT_CONFIG)

    def current(self) -> dict:
        try:
            mtime = os.stat(self.path).st_mtime
        except OSError:
            return self._config
        if mtime != self._mtime:
            try:
                with open(self.path, encoding="utf-8") as f:
                    raw = json.load(f)
                if not isinstance(raw, dict):
                    raise ValueError("config is not an object")
                self._config = merge_config(raw)
                self._mtime = mtime
            except (OSError, ValueError) as e:
                log("config ungültig, behalte vorherige: %s" % type(e).__name__)
                self._mtime = mtime
        return self._config


# ---------------------------------------------------------------------------
# Transition detection


@dataclass
class Notice:
    key: str
    name: str
    kind: str  # "blocked" | "done" | "idle"
    title: Optional[str]
    pane_id: str


class Tracker:
    """Turns successive agent lists into notices. The very first update only records state."""

    def __init__(self):
        self._started = False
        self._state: Dict[str, dict] = {}

    @staticmethod
    def key_of(a: dict) -> str:
        return a.get("name") or a["pane_id"]

    @staticmethod
    def name_of(a: dict) -> str:
        return a.get("name") or a.get("display_agent") or a.get("agent") or a["pane_id"]

    def update(self, agents: List[dict], now: float) -> List[Notice]:
        notices: List[Notice] = []
        seen = set()
        for a in agents:
            key = self.key_of(a)
            seen.add(key)
            status = a.get("agent_status") or "unknown"
            prev = self._state.get(key)

            def notice(kind: str) -> Notice:
                return Notice(key=key, name=self.name_of(a), kind=kind, title=a.get("title"), pane_id=a["pane_id"])

            if prev is None:
                st = {"status": status, "since": now, "idle_pending": False}
                self._state[key] = st
                if self._started and status in ("blocked", "done"):
                    notices.append(notice(status))
                continue

            if status != prev["status"]:
                came_from_working = prev["status"] == "working"
                prev.update(status=status, since=now, idle_pending=(status == "idle" and came_from_working))
                if status in ("blocked", "done"):
                    notices.append(notice(status))
            elif status == "idle" and prev["idle_pending"] and now - prev["since"] >= IDLE_SETTLE_SECONDS:
                prev["idle_pending"] = False
                notices.append(notice("idle"))

        for gone in set(self._state) - seen:
            del self._state[gone]
        self._started = True
        return notices

    def has_pending(self) -> bool:
        """True while an idle notice is waiting for its settle time."""
        return any(st["idle_pending"] for st in self._state.values())


def allowed(cfg: dict, n: Notice) -> bool:
    if not cfg.get("enabled", True):
        return False
    if not cfg.get("events", {}).get(n.kind, False):
        return False
    agents = cfg.get("agents") or {}
    if n.key in agents:
        return bool(agents[n.key])
    return bool(cfg.get("defaultAgentEnabled", True))


# ---------------------------------------------------------------------------
# Messages

TITLES = {"blocked": "„%s“ wartet auf Freigabe", "done": "„%s“ ist fertig", "idle": "„%s“ ist bereit"}
TAGS = {"blocked": "warning", "done": "white_check_mark", "idle": "zzz"}


def header_value(text: str) -> str:
    """HTTP headers must be ASCII; ntfy decodes RFC 2047 encoded words."""
    try:
        text.encode("ascii")
        return text
    except UnicodeEncodeError:
        return "=?UTF-8?B?%s?=" % base64.b64encode(text.encode("utf-8")).decode("ascii")


def build_message(cfg: dict, n: Notice) -> dict:
    server = (cfg.get("ntfyServer") or "https://ntfy.sh").rstrip("/")
    url = "%s/%s" % (server, urllib.parse.quote(cfg.get("ntfyTopic") or "", safe=""))
    body = cfg.get("serverName") or "herdr"
    if n.title:
        body += " · " + n.title
    click = "herdrapp://server/%s/agent/%s" % (cfg.get("serverId") or "", urllib.parse.quote(n.key, safe=""))
    headers = {
        "Title": header_value(TITLES[n.kind] % n.name),
        "Click": click,
        "Tags": TAGS[n.kind],
        "Priority": "high" if n.kind == "blocked" else "default",
    }
    if cfg.get("ntfyToken"):
        headers["Authorization"] = "Bearer %s" % cfg["ntfyToken"]
    return {"url": url, "body": body, "headers": headers}


# ---------------------------------------------------------------------------
# herdr socket


class HerdrSocket:
    """herdr's Unix-socket protocol: one JSON line per request, one JSON line per response."""

    def __init__(self, path: str, timeout: float = 10.0):
        self.path = path
        self.timeout = timeout
        self._id = 0

    def _connect(self) -> socket.socket:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        s.connect(self.path)
        return s

    def _line(self, method: str, params: dict) -> bytes:
        self._id += 1
        return json.dumps({"id": "notify-%d" % self._id, "method": method, "params": params}).encode() + b"\n"

    def request(self, method: str, params: Optional[dict] = None) -> dict:
        with self._connect() as s:
            s.sendall(self._line(method, params or {}))
            f = s.makefile("rb")
            line = f.readline()
        if not line:
            raise ConnectionError("leere Antwort")
        msg = json.loads(line)
        if "error" in msg:
            raise RuntimeError("herdr: %s" % msg["error"].get("code"))
        return msg.get("result") or {}

    def subscribe(self, subscriptions: List[dict], stop: threading.Event,
                  restart: Optional[threading.Event] = None) -> Iterator[dict]:
        """Yields events until stop/restart is set or the connection ends."""
        s = self._connect()
        try:
            s.sendall(self._line("events.subscribe", {"subscriptions": subscriptions}))
            s.settimeout(0.2)
            buf = b""
            started = False
            while not stop.is_set() and not (restart and restart.is_set()):
                try:
                    chunk = s.recv(65536)
                except socket.timeout:
                    continue
                if not chunk:
                    raise ConnectionError("Abo beendet")
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    if not line.strip():
                        continue
                    msg = json.loads(line)
                    if not started:
                        if (msg.get("result") or {}).get("type") != "subscription_started":
                            raise RuntimeError("Abo nicht gestartet")
                        started = True
                        continue
                    yield msg
        finally:
            s.close()


# ---------------------------------------------------------------------------
# Delivery


def post_ntfy(msg: dict, timeout: float = 10.0, throttle: Optional[LogThrottle] = None) -> bool:
    req = urllib.request.Request(msg["url"], data=msg["body"].encode("utf-8"), method="POST")
    for k, v in msg["headers"].items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            ok = 200 <= r.status < 300
    except Exception as e:  # network errors, HTTP errors, timeouts: drop and keep running
        (throttle.error if throttle else (lambda k, m: log(m)))("ntfy", "ntfy-Zustellung fehlgeschlagen: %s" % type(e).__name__)
        return False
    if throttle:
        throttle.ok("ntfy", "ntfy-Zustellung wieder in Ordnung")
    return ok


# ---------------------------------------------------------------------------
# Main loop

EVENT_TYPES = ["pane.updated", "pane.created", "pane.closed", "pane.agent_detected"]


def subscriptions_for(panes) -> List[dict]:
    """herdr emits status changes only as pane.agent_status_changed, which needs one entry per pane."""
    subs = [{"type": t} for t in EVENT_TYPES]
    subs += [{"type": "pane.agent_status_changed", "pane_id": p} for p in sorted(panes)]
    return subs


def run(config_path: str, poll_interval: float = 15.0, reconnect_delay: float = 5.0,
        debounce: float = 0.5, stop: Optional[threading.Event] = None) -> None:
    stop = stop or threading.Event()
    watcher = ConfigWatcher(config_path)
    tracker = Tracker()
    throttle = LogThrottle()
    dirty = threading.Event()
    restart = threading.Event()
    watched_lock = threading.Lock()
    watched = {"panes": frozenset()}

    def subscriber() -> None:
        while not stop.is_set():
            path = watcher.current().get("socket") or ""
            restart.clear()  # clear before reading, so a change made meanwhile is not lost
            with watched_lock:
                panes = watched["panes"]
            try:
                for _ in HerdrSocket(path).subscribe(subscriptions_for(panes), stop, restart):
                    throttle.ok("events", "Event-Abo wieder verbunden")
                    dirty.set()
                if restart.is_set():
                    continue  # agent panes changed: resubscribe right away
            except Exception as e:
                if not stop.is_set():
                    throttle.error("events", "Event-Abo unterbrochen (%s), neue Versuche alle %gs" % (type(e).__name__, reconnect_delay))
            dirty.set()  # resync once reconnected
            stop.wait(reconnect_delay)

    threading.Thread(target=subscriber, name="herdr-events", daemon=True).start()
    last_poll = 0.0
    ready = False
    while not stop.is_set():
        timeout = 1.0 if tracker.has_pending() else poll_interval
        if dirty.wait(timeout=max(0.0, min(timeout, poll_interval - (time.monotonic() - last_poll)))):
            stop.wait(debounce)  # coalesce bursts of events
        dirty.clear()
        if stop.is_set():
            break
        cfg = watcher.current()
        try:
            agents = HerdrSocket(cfg.get("socket") or "").request("agent.list").get("agents") or []
        except Exception as e:
            throttle.error("list", "agent.list fehlgeschlagen: %s (läuft herdr?)" % type(e).__name__)
            stop.wait(reconnect_delay)
            continue
        throttle.ok("list", "herdr wieder erreichbar")
        last_poll = time.monotonic()
        panes = frozenset(a["pane_id"] for a in agents if a.get("pane_id"))
        with watched_lock:
            if panes != watched["panes"]:
                watched["panes"] = panes
                restart.set()
        if not ready:
            ready = True
            log("bereit: beobachte %d Agent(s)" % len(agents))
        for n in tracker.update(agents, time.monotonic()):
            cfg = watcher.current()
            if allowed(cfg, n):
                post_ntfy(build_message(cfg, n), throttle=throttle)


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="herdr → ntfy Benachrichtigungen")
    ap.add_argument("--config", required=True)
    args = ap.parse_args(argv)
    pid_path = os.path.join(os.path.dirname(os.path.abspath(args.config)), "herdr-notify.pid")
    with open(pid_path, "w") as f:
        f.write(str(os.getpid()))
    log("herdr-notify gestartet (pid %d)" % os.getpid())
    try:
        run(args.config)
    except KeyboardInterrupt:
        pass
    finally:
        try:
            with open(pid_path) as f:
                if f.read().strip() == str(os.getpid()):
                    os.unlink(pid_path)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
