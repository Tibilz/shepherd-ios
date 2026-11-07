# herdr iOS App – Teil 2: Benachrichtigungen Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Push-Benachrichtigungen aufs iPhone, wenn ein Agent auf eine Freigabe wartet oder fertig ist – über einen Begleitdienst auf dem VPS und ntfy, global und pro Agent schaltbar, aus der App heraus installierbar.

**Architecture:** `herdr-notify` ist ein einzelnes Python-3-Skript (nur Standardbibliothek). Es abonniert herdr-Events über den Unix-Socket, vergleicht die Agent-Liste, erkennt Statuswechsel und schickt sie per HTTP an ntfy. Die App legt Skript, Konfiguration und Autostart per SSH an (`NotifyInstaller` in HerdrKit) und bearbeitet die Konfigurationsdatei. Vordergrund-Banner kommen aus einem Swift-Gegenstück zur Wechsel-Erkennung.

**Tech Stack:** Python 3 (stdlib, `unittest`), Swift 6.4 / SwiftUI, ntfy (https://ntfy.sh), systemd `--user` oder cron.

**Spec:** `docs/superpowers/specs/2026-11-05-herdr-ios-app-design.md` (Abschnitt 5.5)
**Baut auf:** Plan Teil 1 (`docs/superpowers/plans/2026-11-05-herdr-ios-core.md`) – `RemoteShell`, `HerdrClient`, `SocketCommand`, `ShellQuote`, `LiveSession`, `DeepLink`, `AppModel`.

## Verifizierte Fakten (Testserver)

- `python3` 3.14, `curl`, `systemctl`, `loginctl`, `crontab` vorhanden; `systemctl --user` läuft; **`Linger=no`**; `https://ntfy.sh/v1/health` → 200.
- Socket-Protokoll wie Teil 1: eine JSON-Zeile pro Anfrage, Antwort `{"id","result"}`; `events.subscribe` liefert erst `{"result":{"type":"subscription_started"}}`, dann Zeilen `{"event":"pane_updated","data":{…}}`.
- `agent.list` → `{"type":"agent_list","agents":[{pane_id, name?, agent?, display_agent?, agent_status, …}]}`.
- Zustände simulierbar: `herdr --session herdrapp-test pane report-agent --source it --agent claude --state <idle|working|blocked> <pane_id>`.
- ntfy: `POST <server>/<topic>` mit Body = Nachricht, Header `Title`, `Click`, `Tags`, `Priority`, optional `Authorization: Bearer <token>`.

## Global Constraints

- Skript nur Python-Standardbibliothek, lauffähig ab Python 3.8.
- Dienst legt **nur** an: `~/.config/herdr-notify/` (Skript, `config.json`, `run.sh`, `herdr-notify.pid`, `log`) und `~/.config/systemd/user/herdr-notify.service` **oder** eigene, mit `# herdr-notify` markierte crontab-Zeilen. Deinstallation entfernt genau diese Dinge.
- Die App führt **nie sudo** aus. Ist Linger aus, nutzt der Installer cron und zeigt optional `sudo loginctl enable-linger <user>` als Hinweis.
- Jede Installation/Deinstallation zeigt vorher, was passiert, und braucht eine Bestätigung.
- ntfy-Topic: `herdr-` + 24 zufällige Zeichen `[a-z0-9]` (Geheimnis, nie in Logs der App).
- Click-URL: `herdrapp://server/<serverId>/agent/<target>` (Format aus `DeepLink`, Teil 1).
- Texte auf Deutsch. Titel: `„<name>“ wartet auf Freigabe`, `„<name>“ ist fertig`, `„<name>“ ist bereit`; Body: `<serverName>` und ggf. `title` des Agents.
- Höchstens **eine** Nachricht pro Statuswechsel; beim Start bekannte Zustände erzeugen keine Nachricht; `idle` nach `working` nur wenn `events.idle` und der Zustand ≥ 5 s stabil ist.
- Pro-Agent-Schalter hängen am Schlüssel `name ?? pane_id`; nicht eingetragene Agents nutzen `defaultAgentEnabled`.
- Test-Server-Aktionen auf Testserver nur in Session `herdrapp-test`; Testnachrichten nur an ein frisch erzeugtes Zufalls-Topic.

## Konfigurationsformat (`~/.config/herdr-notify/config.json`)

```json
{
  "version": 1,
  "enabled": true,
  "ntfyServer": "https://ntfy.sh",
  "ntfyTopic": "herdr-abc…",
  "ntfyToken": null,
  "socket": "/home/ubuntu/.config/herdr/herdr.sock",
  "serverId": "6B7D0C1E-…",
  "serverName": "VPS 2",
  "events": { "blocked": true, "done": true, "idle": false },
  "defaultAgentEnabled": true,
  "agents": { "reviewer": false }
}
```

## Review Focus

1. **herdr-Server wird neu gestartet oder ist kurz weg** → Dienst verbindet sich alle 5 s neu, stürzt nicht ab, schickt danach keine Flut alter Zustände – Test in Task 2 (`reconnectsWithoutReplayingState`).
2. **ntfy nicht erreichbar / Timeout** → Dienst loggt, verwirft die Nachricht, läuft weiter (kein Hängen > 10 s) – Test in Task 2 (`ntfyFailureDoesNotStopLoop`).
3. **Konfiguration wird von der App während des Laufs geändert oder ist kaputt** → Änderung wirkt ohne Neustart; kaputtes JSON behält die letzte gültige Konfiguration – Test in Task 1 (`brokenConfigKeepsPrevious`).
4. **Bestehende crontab des Nutzers** → Installation/Deinstallation lässt fremde Zeilen unverändert – Test in Task 3 (`cronInstallPreservesForeignLines`).
5. **Agent-Namen mit Sonderzeichen / Umlauten** → Titel korrekt (UTF-8 in HTTP-Headern via RFC 2047 oder ntfy-`X-Title` mit `=?UTF-8?B?…?=`), Click-URL prozentkodiert – Test in Task 1 (`umlautTitleIsEncoded`).

---

## Dateistruktur

```
Packages/HerdrKit/Sources/HerdrKit/Resources/herdr-notify.py   Begleitdienst (eine Datei, wird per SSH installiert)
Packages/HerdrKit/Tests/notify/test_herdr_notify.py            Python-Tests (unittest), laufen auf dem Mac
Packages/HerdrKit/Sources/HerdrKit/Notify/NotifyConfig.swift   Codable-Abbild von config.json + Topic-Generator
Packages/HerdrKit/Sources/HerdrKit/Notify/NotifyInstaller.swift Status, Installieren, Konfig lesen/schreiben, Deinstallieren, Testnachricht
Packages/HerdrKit/Sources/HerdrKit/Notify/AgentTransitions.swift Swift-Wechsel-Erkennung für In-App-Banner
Packages/HerdrKit/Tests/HerdrKitTests/NotifyTests.swift
App/Views/NotificationsView.swift                              Einrichten, Status, Schalter, ntfy-Abo (QR + Link)
App/Views/StatusBanner.swift                                   Vordergrund-Banner
App/Stores/AppModel.swift (ändern)                             Notify-Konfig je Server, Banner-Queue
App/Views/AgentDetailView.swift, ServerOverviewView.swift (ändern)  Glocke / Einstieg
```

---

### Task 1: herdr-notify – Kernlogik (Python)

**Files:**
- Create: `Packages/HerdrKit/Sources/HerdrKit/Resources/herdr-notify.py`, `Packages/HerdrKit/Tests/notify/test_herdr_notify.py`
- Modify: `Packages/HerdrKit/Package.swift` (Resource `.copy("Resources/herdr-notify.py")` im Target `HerdrKit`)

**Interfaces (Python, Modul per `importlib` aus Pfad geladen):**
- `DEFAULT_CONFIG: dict` (Werte wie oben, `enabled=True`, Events `blocked/done=True`, `idle=False`, `defaultAgentEnabled=True`, `agents={}`)
- `class ConfigWatcher: __init__(path); current() -> dict` – lädt bei geänderter mtime neu, mischt über `DEFAULT_CONFIG`, behält bei Fehler die letzte gültige.
- `@dataclass Notice: key: str; name: str; kind: str  # "blocked"|"done"|"idle"; title: str|None; pane_id: str`
- `class Tracker: update(agents: list[dict], now: float) -> list[Notice]` – erster Aufruf merkt nur; danach Regeln aus Global Constraints; verschwundene Agents vergessen; `idle` erst nach 5 s Stabilität (Folgeaufrufe liefern es dann).
- `def allowed(cfg: dict, n: Notice) -> bool`
- `def build_message(cfg: dict, n: Notice) -> dict` mit Schlüsseln `url, body, headers` (`Title` RFC-2047-kodiert falls nicht ASCII, `Click`, `Tags` = `warning`/`white_check_mark`/`zzz`, `Priority` = `high` für blocked sonst `default`, `Authorization` falls Token).

- [ ] **Step 1: Tests schreiben** (`unittest`): `firstUpdateIsSilent`, `blockedNotifiesOnce` (blocked, blocked → 1 Notice), `doneAfterWorking`, `idleNeedsFiveSecondsAndFlag` (working→idle bei t=0 → nichts; t=6 → idle-Notice, wenn `events.idle`), `idleFlappingIgnored` (working→idle→working innerhalb 5 s → nichts), `newAgentAfterStartNotifies` (nur der allererste `update`-Aufruf ist still; ein später neu erscheinender Agent im Zustand blocked → Notice), `vanishedAgentForgotten` (Agent verschwindet und taucht blocked wieder auf → Notice), `perAgentSwitch`, `globalSwitch`, `eventSwitches`, `brokenConfigKeepsPrevious`, `umlautTitleIsEncoded` (`„Prüfer“` → Header beginnt mit `=?UTF-8?B?`), `clickUrlEncodesTarget` (`w1:p2` → `w1%3Ap2`), `tokenAddsAuthorization`.
- [ ] **Step 2:** Run `python3 -m unittest discover -s Packages/HerdrKit/Tests/notify -v` → FAIL (Modul/Funktionen fehlen).
- [ ] **Step 3:** Implementieren.
- [ ] **Step 4:** Gleicher Befehl → alle PASS.
- [ ] **Step 5:** Commit `feat(notify): herdr-notify core logic`.

### Task 2: herdr-notify – Laufzeit (Socket, Schleife, ntfy)

**Files:** Modify `herdr-notify.py`, `test_herdr_notify.py`

**Interfaces:**
- `class HerdrSocket: __init__(path, timeout=10); request(method, params={}) -> dict` (eigene Verbindung pro Anfrage, liest erste Zeile); `subscribe(types: list[str]) -> Iterator[dict]` (eine dauerhafte Verbindung, liefert geparste Zeilen; erste muss `subscription_started` sein, sonst `RuntimeError`).
- `def post_ntfy(msg: dict, timeout=10) -> bool` (urllib; Fehler → `False`, geloggt).
- `def run(config_path: str, poll_interval=15.0, reconnect_delay=5.0, stop: threading.Event|None=None)` – Hauptschleife: Socket aus Konfig; Abo auf `pane.updated, pane.created, pane.closed, pane.agent_detected`; jedes Event → `agent.list` (entprellt 0,5 s) → `Tracker.update` → `allowed` → `post_ntfy`; zusätzlich alle `poll_interval` s ein `agent.list`; bei Socket-Fehler `reconnect_delay` warten, neu verbinden, **Tracker behalten** (keine Wiederholung bekannter Zustände); `enabled=False` → nichts senden, aber weiter beobachten.
- CLI: `python3 herdr-notify.py --config <pfad>`; schreibt PID nach `<configdir>/herdr-notify.pid`; Log nach stderr (Zeitstempel, nie Topic/Token).

- [ ] **Step 1: Tests** mit Fake-herdr (Unix-Socket-Server im Tempdir, antwortet auf `events.subscribe` und `agent.list` aus einer veränderbaren Liste) und Fake-ntfy (`http.server` auf 127.0.0.1, sammelt Requests): `endToEndBlockedReachesNtfy`, `reconnectsWithoutReplayingState` (Fake-Socket schließen, Status unverändert, neu öffnen → keine zusätzliche Nachricht), `ntfyFailureDoesNotStopLoop` (ntfy antwortet 500 / nicht erreichbar → nächste Notice kommt trotzdem an), `disabledSendsNothing`, `configChangeAppliesLive`.
- [ ] **Step 2:** FAIL → **Step 3:** implementieren → **Step 4:** PASS (gleicher Befehl wie Task 1).
- [ ] **Step 5:** Commit `feat(notify): socket loop and ntfy delivery`.

### Task 3: NotifyConfig + NotifyInstaller (Swift)

**Files:** Create `Notify/NotifyConfig.swift`, `Notify/NotifyInstaller.swift`, `Tests/HerdrKitTests/NotifyTests.swift`

**Interfaces:**
- `struct NotifyConfig: Codable, Equatable, Sendable { var version = 1; var enabled = true; var ntfyServer = "https://ntfy.sh"; var ntfyTopic: String; var ntfyToken: String?; var socket: String; var serverId: UUID; var serverName: String; var events = Events(); var defaultAgentEnabled = true; var agents: [String: Bool] = [:]; struct Events: Codable, Equatable, Sendable { var blocked = true; var done = true; var idle = false }; func isEnabled(agent key: String) -> Bool; static func randomTopic() -> String; var subscribeURL: URL }` (`subscribeURL` = `ntfyServer/ntfyTopic`)
- `enum NotifyMode: String, Sendable { case systemd, cron, none }`
- `struct NotifyStatus: Equatable, Sendable { var installed: Bool; var running: Bool; var mode: NotifyMode; var linger: Bool; var python: Bool }`
- `struct NotifyInstaller { init(shell: RemoteShell, baseDir: String = "~/.config/herdr-notify"); func status() async throws -> NotifyStatus; func plannedActions(linger: Bool) -> [String]; func install(config: NotifyConfig) async throws -> NotifyMode; func readConfig() async throws -> NotifyConfig?; func writeConfig(_ c: NotifyConfig) async throws; func uninstall() async throws; func sendTest(config: NotifyConfig) async throws }`
  - Name/Marker leiten sich aus `baseDir` ab: `name` = letzte Pfadkomponente (Standard `herdr-notify`), crontab-Marker `# <name>`, Unit `~/.config/systemd/user/<name>.service`.
  - Alle Dateiinhalte per `printf %s <base64> | base64 -d > <datei>`; alles in `SocketCommand.login(…)`.
  - `status()`: ein Skript, das `key=value`-Zeilen ausgibt (`installed`, `running` via PID-Datei + `kill -0`, `mode`, `linger` via `loginctl show-user "$USER" -p Linger`, `python` via `command -v python3`).
  - `install`: Verzeichnis, Skript (aus `Bundle.module`), `config.json` (Rechte 600), `run.sh`; Linger=yes → systemd-Unit `Restart=always`, `systemctl --user daemon-reload && systemctl --user enable --now herdr-notify`; sonst cron: `(crontab -l 2>/dev/null | grep -v '# <name>$'; echo '@reboot <dir>/run.sh # <name>'; echo '* * * * * <dir>/run.sh # <name>') | crontab -` und sofort `run.sh`.
  - `run.sh`: startet den Dienst nur, wenn PID-Datei fehlt oder Prozess tot (`nohup python3 … >> log 2>&1 &`).
  - `uninstall`: Dienst stoppen (systemd disable --now bzw. `kill $(cat pid)`), eigene crontab-Zeilen entfernen, Unit und Verzeichnis löschen.
  - `sendTest`: `curl -fsS -m 10 -H 'Title: herdr Test' -d 'Benachrichtigungen funktionieren.' <server>/<topic>` (Topic quoted).
- [ ] **Step 1: Tests** (FakeShell aus Teil 1, erweitert um frei definierbare Antworten pro Befehls-Teilstring): `configRoundTripMatchesPythonKeys` (JSON-Schlüssel exakt wie im Konfigurationsformat), `randomTopicFormat` (Regex `^herdr-[a-z0-9]{24}$`), `agentSwitchFallsBackToDefault`, `statusParsing`, `installUsesCronWithoutLinger` (Befehl enthält `crontab -` und `# herdr-notify`, nicht `systemctl`), `installUsesSystemdWithLinger`, `cronInstallPreservesForeignLines` (Befehl filtert nur `# herdr-notify`), `uninstallRemovesOnlyOwnFiles` (keine `rm` außerhalb `~/.config/herdr-notify` und der Unit), `scriptIsBundled` (Resource lesbar, beginnt mit `#!/usr/bin/env python3`), `configWrittenWithMode600`.
- [ ] **Step 2:** `cd Packages/HerdrKit && swift test --filter NotifyTests` → FAIL → **Step 3:** implementieren → **Step 4:** PASS, ganze Suite grün.
- [ ] **Step 5:** Commit `feat(kit): notify config and installer`.

### Task 4: Live-Test auf Testserver (Test-Session)

**Files:** Create `Packages/HerdrSSH/Tests/IntegrationTests/NotifyIntegrationTests.swift`

- [ ] **Step 1:** Integrationstest (gleiche Env-Variablen wie Teil 1): erzeugt Zufalls-Topic, installiert mit `socket` der Session `herdrapp-test` **und** `configDir`-Überschreibung `~/.config/herdr-notify-it` (damit ein späterer echter Dienst unberührt bleibt; dafür `NotifyInstaller(shell:baseDir:)` mit Standard `~/.config/herdr-notify`), simuliert per `pane report-agent … --state working` dann `blocked` auf dem eigenen Pane, liest `https://ntfy.sh/<topic>/json?poll=1` per `curl` auf dem VPS und erwartet eine Nachricht mit Titel „… wartet auf Freigabe“; danach `uninstall()` und prüft, dass `~/.config/herdr-notify-it` weg ist und keine `herdr-notify-it`-crontab-Zeile bleibt.
- [ ] **Step 2:** Run `HERDR_IT_HOST=203.0.113.10 HERDR_IT_USER=ubuntu HERDR_IT_KEY=~/.ssh/id_ed25519 swift test --filter NotifyIntegrationTests` → PASS.
- [ ] **Step 3:** Commit `test(notify): live install round trip on VPS`.

### Task 5: App – Benachrichtigungen einrichten und schalten

**Files:** Create `App/Views/NotificationsView.swift`; Modify `App/Stores/AppModel.swift`, `App/Views/ServerOverviewView.swift`, `App/Views/AgentDetailView.swift`

**Interfaces:**
- `AppModel`: `private(set) var notifyConfigs: [UUID: NotifyConfig]`; `func loadNotify(_ serverId: UUID) async throws -> (NotifyStatus, NotifyConfig?)`; `func installNotify(_ serverId: UUID) async throws -> NotifyMode` (erzeugt Topic, `socket` aus `HerdrClient.status`); `func updateNotify(_ serverId: UUID, _ change: (inout NotifyConfig) -> Void) async throws`; `func uninstallNotify(_ serverId: UUID) async throws`.
- NotificationsView: Status-Zeile (läuft / gestoppt / nicht eingerichtet; Modus systemd/cron); „Einrichten“ → Bestätigungsblatt mit `plannedActions` → install; danach Abschnitt „Auf dem iPhone abonnieren“: Topic-Link (`subscribeURL`, `Link` + Kopieren), QR-Code (CoreImage `CIQRCodeGenerator`), Anleitung „ntfy-App → + → Server/Topic“; „Testnachricht senden“; Schalter global + Ereignisse (wartet / fertig / bereit); Liste aller Agents aus dem Snapshot plus bekannte Schlüssel aus `agents` mit Schaltern; Linger-Hinweis mit kopierbarem `sudo loginctl enable-linger <user>` wenn Modus cron; „Entfernen“ mit Bestätigung.
- Einstieg: Glocken-Symbol in der Toolbar der ServerOverview → NotificationsView; in AgentDetailView eine Glocke (`bell` / `bell.slash`), die `agents[target]` umschaltet (nur sichtbar, wenn eingerichtet).
- [ ] **Step 1:** Implementieren; `xcodebuild … -skipPackagePluginValidation build` → `BUILD SUCCEEDED`.
- [ ] **Step 2:** Commit `feat(app): notification setup and switches`.

### Task 6: Vordergrund-Banner

**Files:** Create `Notify/AgentTransitions.swift`, `App/Views/StatusBanner.swift`; Modify `Client/LiveSession.swift`, `AppModel.swift`, `HerdrApp.swift`; Test in `NotifyTests.swift`

**Interfaces:**
- `enum AgentTransitions { static func diff(old: HerdrSnapshot?, new: HerdrSnapshot) -> [AgentTransition] }`; `struct AgentTransition: Equatable, Sendable { let target: String; let name: String; let to: AgentStatus }` – nur Wechsel **nach** `blocked` oder `done`, nicht beim ersten Snapshot (`old == nil`).
- `LiveSession`: `public var onTransitions: (@MainActor ([AgentTransition]) -> Void)?`, aufgerufen in `loadSnapshot`.
- `AppModel`: `var banner: BannerItem?` (Server, Transition), setzt beim Callback nur, wenn der Agent nicht gerade offen ist; Banner verschwindet nach 4 s; Tippen → Deep Link.
- [ ] **Step 1: Tests:** `firstSnapshotHasNoTransitions`, `toBlockedIsReported`, `stayingBlockedIsSilent`, `toWorkingIsSilent`, `doneReported`.
- [ ] **Step 2:** FAIL → implementieren → PASS (`swift test`), App-Build `BUILD SUCCEEDED`.
- [ ] **Step 3:** Commit `feat(app): in-app status banner`.

### Task 7: README

- [ ] **Step 1:** Abschnitt „Benachrichtigungen“: ntfy-App installieren, in der App „Einrichten“, Topic abonnieren (QR), Testnachricht; Linger-Hinweis; was auf dem Server angelegt wird und wie man es entfernt; Datenschutz-Hinweis (ntfy.sh ist ein öffentlicher Dienst, Topic geheim halten, eigener ntfy-Server möglich).
- [ ] **Step 2:** Alle Suiten grün (`python3 -m unittest …`, `swift test` in beiden Packages, App-Build). Commit `docs: notifications guide`.
