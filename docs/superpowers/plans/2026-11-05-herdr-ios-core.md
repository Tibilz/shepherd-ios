# herdr iOS App – Teil 1: Kern (SSH, Keys, Übersicht, Agent, Terminal) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eine iPhone-App, die sich per SSH-Key mit herdr-Servern verbindet, Workspaces/Tabs/Agents live anzeigt, Agent-Konversationen zeigt, Prompts und Freigabe-Tasten sendet und ein interaktives Terminal bietet.

**Architecture:** Die gesamte Logik liegt im Swift-Package `HerdrKit` (läuft auf iOS und macOS, wird per `swift test` auf dem Mac getestet). Die App `HerdrApp` (XcodeGen-Projekt) ist eine dünne SwiftUI-Schicht darüber. Mit herdr wird über SSH-Exec gesprochen: eine JSON-Anfrage wird base64-kodiert in den Befehl eingebettet und per `nc -U` an den herdr-Socket geschickt; Live-Events kommen über einen dauerhaften Exec-Kanal mit `events.subscribe`.

**Tech Stack:** Swift 6.4, SwiftUI, iOS 26 / macOS 26, XcodeGen, Citadel (SSH), SwiftTerm (Terminal), Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-05-herdr-ios-app-design.md`

**Folgepläne** (werden nach diesem geschrieben, bauen auf `HerdrKit` auf): Teil 2 Benachrichtigungen (herdr-notify + ntfy + Schalter), Teil 3 Sprache (WhisperKit, Absichten, `claude -p`, Vorlesen), Teil 4 VPN-Hinweise.

## Verifizierte Fakten über herdr (Testserver, herdr 0.9.5, protocol 22)

- Socket: Zeile `socket: <pfad>` in der Ausgabe von `herdr status` (auf Testserver: `/home/ubuntu/.config/herdr/herdr.sock`).
- Protokoll: eine JSON-Zeile pro Anfrage `{"id":"…","method":"…","params":{…}}`, Antwort als JSON-Zeile `{"id":"…","result":{…}}` oder `{"id":"…","error":{"code":"…","message":"…"}}`.
- `printf '%s\n' '<json>' | nc -U -q 2 <sock>` funktioniert auf Testserver (OpenBSD-nc unter `/usr/bin/nc`).
- `events.subscribe` mit `{"subscriptions":[{"type":"pane.updated"}, …]}` antwortet `{"id":"…","result":{"type":"subscription_started"}}` und streamt danach Events. Ohne `pane_id` abonnierbar: `workspace.*`, `tab.*`, `pane.created|closed|updated|focused|moved|exited|agent_detected`, `layout.updated`. `pane.agent_status_changed` braucht `pane_id`.
- Echte Antworten (Fixtures) stehen in Task 2. `AgentInfo`-Felder laut Schema: `pane_id, workspace_id, tab_id, terminal_id, agent_status, focused, name?, agent?, display_agent?, title?, cwd?, foreground_cwd?, interactive_ready, launch_pending, revision, state_change_seq, completion_seq?`.
- `agent.read` Params: `target, source (visible|recent|recent_unwrapped|detection), lines?, format (text), strip_ansi (default true)`. Ergebnis enthält `text`, `truncated`, `revision`.
- `herdr agent attach <TARGET> [--takeover]` hängt das Terminal an einen Agent.
- `claude -p --model haiku --output-format json "…"` funktioniert auf Testserver (für Teil 3).

## Global Constraints

- Mindest-iOS **26**, nur iPhone; Package-Plattformen `.iOS(.v26), .macOS(.v26)`.
- **Kein bezahltes Developer-Konto**: keine Entitlements außer Keychain (Standard); keine Push-, Network-Extension-, iCloud- oder App-Group-Entitlements. Bundle-ID `de.kozarzewski.herdrapp`.
- Oberfläche auf **Deutsch**.
- Geheimnisse (private Keys, Passphrasen) **nur im Schlüsselbund**, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `SecAccessControl` mit `.userPresence`, nie in iCloud, nie in Logs.
- **Face ID einmal beim Öffnen**; nach > **300 s** im Hintergrund wieder sperren.
- Host-Key: beim ersten Verbinden Fingerprint bestätigen (TOFU), bei Änderung Verbindung **verweigern**.
- Die App **schließt nie** Workspaces/Tabs/Panes und stoppt/aktualisiert nie den herdr-Server.
- Remote-Befehle laufen in `bash -lc` (damit `PATH` stimmt); herdr-Pfad pro Server überschreibbar (Standard `herdr`).
- Tests auf Testserver: nur lesen bzw. in eigener Session `herdrapp-test`; nichts Bestehendes schließen oder löschen.
- Abhängigkeiten nur: Citadel, SwiftTerm (+ deren transitive). Keine weiteren ohne Grund.

## Review Focus

1. **Prompt-Text mit Sonderzeichen** (`'`, `"`, `$`, Backticks, Zeilenumbrüche, Umlaute, Emoji) muss unverändert beim Agent ankommen – Base64-Transport, Test in Task 3.
2. **Verbindung bricht ab / App geht in den Hintergrund während einer Anfrage** → klarer Fehler, automatischer Reconnect beim Zurückkehren, **ein Prompt wird nie automatisch erneut gesendet** – Test in Task 4 (`promptIsNotRetried`) und Task 5.
3. **herdr-Server läuft nicht oder `herdr` nicht im PATH** → verständliche deutsche Meldung statt rohem Fehler – Test in Task 4 (`statusParsing…`).
4. **Sehr lange Agent-Ausgabe** → `lines` auf 400 begrenzt, `truncated` wird angezeigt, UI bleibt flüssig – Test in Task 4 (`readAgentUsesLineLimit`).
5. **Host-Key ändert sich** → Verbindung abgelehnt, Warnung – Test in Task 6 (`changedHostKeyIsRejected`).

---

## Dateistruktur

```
project.yml                                   XcodeGen-Projekt (App-Target, Package-Abhängigkeit)
Packages/HerdrKit/Package.swift
Packages/HerdrKit/Sources/HerdrKit/
  Model/HerdrModels.swift                     Workspace, Tab, Pane, Agent, AgentStatus (Codable)
  Model/HerdrSnapshot.swift                   Baum Workspace→Tab→Pane, geordnete Agent-Liste
  Protocol/HerdrRequest.swift                 Anfrage-Typen + JSON-Kodierung
  Protocol/HerdrResponse.swift                Antwort-Hülle, HerdrError
  Protocol/SocketCommand.swift                Shell-Befehl bauen (base64 | nc -U), ShellQuote
  Transport/RemoteShell.swift                 Protokoll für Exec + Streaming
  Transport/CitadelShell.swift                Citadel-Implementierung, PTY
  Client/HerdrClient.swift                    Typisierte API-Aufrufe
  Client/EventLines.swift                     Zeilenpuffer + Event-Dekodierung
  Client/LiveSession.swift                    Snapshot halten, Events/Polling, Refresh
  Keys/SSHKeyImport.swift                     Key parsen, Fingerprint, Public Key
  Keys/KeyStore.swift                         Protokoll + InMemoryKeyStore
  Keys/KnownHosts.swift                       TOFU-Speicher + Prüfung
  Servers/ServerProfile.swift                 Server-Profil + JSON-Store
  Security/AppLockPolicy.swift                300-s-Regel
Packages/HerdrKit/Tests/HerdrKitTests/…       Unit-Tests + Fixtures
Packages/HerdrKit/Tests/IntegrationTests/…    gegen Testserver, nur mit HERDR_IT_HOST gesetzt
App/HerdrApp.swift, App/…Views                SwiftUI
App/Security/KeychainKeyStore.swift           Schlüsselbund + LAContext
README.md                                     Installation mit kostenloser Apple-ID, 7-Tage-Erneuerung, SideStore
```

---

### Task 1: Gerüst – Package, App-Projekt, Build

**Files:**
- Create: `Packages/HerdrKit/Package.swift`, `Packages/HerdrKit/Sources/HerdrKit/HerdrKit.swift`, `Packages/HerdrKit/Tests/HerdrKitTests/SmokeTests.swift`
- Create: `project.yml`, `App/HerdrApp.swift`, `App/Info.plist` (via XcodeGen-Properties), `.gitignore`

**Interfaces:**
- Produces: Package-Produkt `HerdrKit`; App-Scheme `HerdrApp`.

- [ ] **Step 1:** `Package.swift` mit Plattformen `.iOS(.v26), .macOS(.v26)`, Abhängigkeiten `https://github.com/orlandos-nl/Citadel` (aktuelle Release-Version) und `https://github.com/migueldeicaza/SwiftTerm` (aktuelle Release-Version); Target `HerdrKit` hängt nur an Citadel; Test-Targets `HerdrKitTests` und `IntegrationTests`.
- [ ] **Step 2:** Test `@Test func packageBuilds() { #expect(HerdrKit.version == "0.1.0") }`.
- [ ] **Step 3:** Run `cd Packages/HerdrKit && swift test` → FAIL (`version` fehlt). Dann `public enum HerdrKit { public static let version = "0.1.0" }` → PASS.
- [ ] **Step 4:** `project.yml`: App-Target `HerdrApp`, iOS 26, `TARGETED_DEVICE_FAMILY=1`, Bundle-ID `de.kozarzewski.herdrapp`, lokales Package `Packages/HerdrKit` + SwiftTerm, `NSFaceIDUsageDescription = "Entsperrt deine SSH-Keys."`, URL-Schema `herdrapp`, `CODE_SIGN_STYLE=Automatic`, `DEVELOPMENT_TEAM` leer (Nutzer wählt Personal Team). `App/HerdrApp.swift` zeigt `Text("herdr")`. `.gitignore` für `*.xcodeproj`, `.build`, `DerivedData`.
- [ ] **Step 5:** Run `xcodegen generate && xcodebuild -scheme HerdrApp -destination 'platform=iOS Simulator,name=iPhone 17' build` (verfügbaren Simulatornamen per `xcrun simctl list devices` wählen) → `BUILD SUCCEEDED`.
- [ ] **Step 6:** Commit `chore: scaffold HerdrKit package and app project`.

### Task 2: Modelle und Dekodierung

**Files:**
- Create: `Sources/HerdrKit/Model/HerdrModels.swift`, `Sources/HerdrKit/Model/HerdrSnapshot.swift`
- Create: `Tests/HerdrKitTests/Fixtures/*.json`, `Tests/HerdrKitTests/ModelTests.swift`

**Interfaces:**
- Produces:
  - `enum AgentStatus: String, Codable, Sendable { case idle, working, blocked, done, unknown }` (unbekannte Werte → `.unknown`)
  - `struct Workspace: Codable, Sendable, Identifiable { workspaceId, number: Int, label: String, focused: Bool, paneCount: Int, tabCount: Int, activeTabId: String?, agentStatus: AgentStatus }` (`id = workspaceId`)
  - `struct Tab { tabId, workspaceId, number: Int, label: String, focused: Bool, paneCount: Int, agentStatus }`
  - `struct Pane { paneId, tabId, workspaceId, terminalId, cwd: String?, foregroundCwd: String?, focused: Bool, agentStatus, terminalTitleStripped: String?, revision: Int }`
  - `struct Agent { paneId, workspaceId, tabId, terminalId, agentStatus, focused: Bool, name: String?, agent: String?, displayAgent: String?, title: String?, cwd: String?, interactiveReady: Bool, revision: Int }`; `var displayName: String` = `name ?? displayAgent ?? agent ?? paneId`
  - `struct HerdrSnapshot: Sendable { workspaces, tabs, panes, agents; func tabs(in: Workspace) -> [Tab]; func panes(in: Tab) -> [Pane]; func agent(onPane: String) -> Agent?; var orderedAgents: [Agent]; var needsAttention: [Agent] }`
- JSON nutzt `snake_case` → `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase` (als `HerdrJSON.decoder` öffentlich).

- [ ] **Step 1:** Fixtures anlegen: `workspace_list.json`, `tab_list.json`, `pane_list.json` exakt mit den auf Testserver gesehenen `result`-Objekten:
  ```json
  {"type":"workspace_list","workspaces":[{"active_tab_id":"w1:t1","agent_status":"unknown","focused":true,"label":"~","number":1,"pane_count":1,"tab_count":1,"workspace_id":"w1"}]}
  ```
  (tab/pane analog aus dem Plan-Abschnitt „Verifizierte Fakten“ bzw. per `ssh Testserver 'bash -lc "herdr tab list"'` holen). `agent_list.json` von Hand nach Schema mit zwei Agents: `w1:p2` name `reviewer`, agent `claude`, status `blocked`; `w2:p1` name nil, display_agent `Codex`, status `working`, plus ein Feld `"agent_status":"sleeping"` in einem dritten Agent zum Test unbekannter Werte.
- [ ] **Step 2:** Tests: `decodesRealWorkspaceList` (`label == "~"`, `paneCount == 1`, `agentStatus == .unknown`), `decodesAgents` (3 Agents, `reviewer.agentStatus == .blocked`, `displayName` des zweiten `"Codex"`), `unknownStatusFallsBack` (`.unknown`), `orderedAgentsSortByWorkspaceThenTabThenPane` (Reihenfolge nach Workspace-`number`, Tab-`number`, dann Reihenfolge in `panes`), `needsAttentionContainsBlockedAndDone`.
- [ ] **Step 3:** `swift test --filter ModelTests` → FAIL; implementieren; → PASS.
- [ ] **Step 4:** Commit `feat(kit): herdr models and snapshot`.

### Task 3: Anfragen, Antworten, Socket-Befehl

**Files:**
- Create: `Protocol/HerdrRequest.swift`, `Protocol/HerdrResponse.swift`, `Protocol/SocketCommand.swift`, `Tests/HerdrKitTests/ProtocolTests.swift`

**Interfaces:**
- Produces:
  - `struct HerdrRequest: Encodable, Sendable { let id: String; let method: String; let params: [String: JSONValue] }` mit `JSONValue` (string, int, bool, array, object, null). `func jsonLine() throws -> Data` (kompakt, endet mit `\n`).
  - `enum HerdrError: Error, Equatable { case server(code: String, message: String), notRunning, herdrNotFound, protocolMismatch(String), transport(String), decoding(String) }` mit `var localizedDescription` auf Deutsch (z. B. `.notRunning` → „Der herdr-Server läuft auf diesem Server nicht.“).
  - `enum HerdrResponse { static func decode<T: Decodable>(_ data: Data, as: T.Type) throws -> T }` – wirft `.server` bei `error`-Objekt, sonst dekodiert `result`.
  - `enum ShellQuote { static func quote(_ s: String) -> String }` (POSIX single-quote, `'` → `'\''`).
  - `enum SocketCommand { static func oneShot(_ req: HerdrRequest, socket: String) throws -> String; static func stream(_ req: HerdrRequest, socket: String, maxSeconds: Int = 1800) throws -> String; static func login(_ inner: String) -> String }`
    - oneShot: `printf %s <b64> | base64 -d | nc -U -q 2 <quoted socket>`
    - stream: `exec timeout <maxSeconds> sh -c '{ printf %s <b64> | base64 -d; sleep <maxSeconds>; } | nc -U <sock>'`
    - login: `bash -lc <quoted inner>`

- [ ] **Step 1:** Tests: `encodesRequestLine` (Ausgabe endet mit `\n`, enthält `"method":"agent.prompt"`), `decodesErrorEnvelope` (Eingabe `{"id":"t2","error":{"code":"invalid_request","message":"x"}}` → `.server(code:"invalid_request",message:"x")`), `quoteHandlesSingleQuote` (`it's` → `'it'\''s'`), `specialCharsSurviveBase64` (Prompt `"a'b\"c $HOME `x`\nä 🚀"` → base64 aus dem Befehl extrahieren, dekodieren, JSON parsen, `params.text` identisch), `oneShotUsesSocketPath`.
- [ ] **Step 2:** `swift test --filter ProtocolTests` → FAIL; implementieren; → PASS.
- [ ] **Step 3 (Prüfung gegen echten Server):** `ssh Testserver "$(swift run … )"` ist umständlich – stattdessen einmal manuell: den von `oneShot` für `workspace.list` erzeugten String ausgeben (kleiner Test, der ihn druckt) und per `ssh Testserver 'bash -lc "<string>"'` ausführen → Antwort beginnt mit `{"id":`.
- [ ] **Step 4:** Commit `feat(kit): request encoding and socket command`.

### Task 4: RemoteShell-Protokoll und HerdrClient

**Files:**
- Create: `Transport/RemoteShell.swift`, `Client/HerdrClient.swift`, `Tests/HerdrKitTests/FakeShell.swift`, `Tests/HerdrKitTests/ClientTests.swift`

**Interfaces:**
- Produces:
  - `struct ExecResult: Sendable { stdout: Data; stderr: Data; exitCode: Int32 }`
  - `protocol RemoteShell: Sendable { func exec(_ command: String) async throws -> ExecResult; func stream(_ command: String) -> AsyncThrowingStream<Data, Error> }`
  - `actor HerdrClient { init(shell: RemoteShell, herdrPath: String = "herdr"); func connect() async throws -> ServerStatus; func workspaces() async throws -> [Workspace]; func tabs() async throws -> [Tab]; func panes() async throws -> [Pane]; func agents() async throws -> [Agent]; func snapshot() async throws -> HerdrSnapshot; func readAgent(_ target: String, lines: Int = 400) async throws -> AgentRead; func prompt(_ target: String, text: String) async throws; func sendKeys(_ target: String, keys: [String]) async throws; func focusAgent(_ target: String) async throws; func runInPane(_ paneId: String, command: String) async throws; func readPane(_ paneId: String, lines: Int = 200) async throws -> AgentRead }`
  - `struct ServerStatus { version: String; protocolVersion: Int; socket: String }`
  - `struct AgentRead: Decodable, Sendable { text: String; truncated: Bool; revision: Int }`
- Methoden: `workspace.list`, `tab.list`, `pane.list`, `agent.list`, `agent.read` (`source: "recent_unwrapped"`, `strip_ansi: true`), `agent.prompt` (ohne `wait`), `agent.send_keys`, `agent.focus`, `pane.run`, `pane.read`. Exakte `params`-Namen aus `herdr api schema --json` (lokal) nehmen. IDs der Anfragen: `"app-<laufende Nummer>"`.
- `connect()`: führt `login("<herdrPath> status")` aus, parst `version:` (unter `server:`), `private_protocol:` und `socket:`; `command not found`/Exit 127 → `.herdrNotFound`; `status: stopped`/fehlender Server-Block → `.notRunning`; Protokoll ≠ 22 → `.protocolMismatch(version)`.
- Fehler beim Senden werden nie automatisch wiederholt (gilt für `prompt`, `sendKeys`, `runInPane`).

- [ ] **Step 1:** `FakeShell` speichert ausgeführte Befehle und gibt vorkonfigurierte Antworten pro Methodenname zurück (aus dem Base64 dekodiert).
- [ ] **Step 2:** Tests: `statusParsingRunning` (Fixture = echte `herdr status`-Ausgabe vom Mac aus dem Plan-Abschnitt → `socket` korrekt, `protocolVersion == 22`), `statusParsingNotFound` (Exit 127 → `.herdrNotFound`), `statusParsingStopped` (→ `.notRunning`), `snapshotCombinesLists`, `readAgentUsesLineLimit` (params `lines == 400`, `source == "recent_unwrapped"`), `promptSendsExactText`, `promptIsNotRetried` (FakeShell wirft einmal `.transport` → Aufruf wirft, nur 1 Befehl ausgeführt), `serverErrorIsSurfaced`.
- [ ] **Step 3:** `swift test --filter ClientTests` → FAIL; implementieren; → PASS.
- [ ] **Step 4:** Commit `feat(kit): herdr client over remote shell`.

### Task 5: Event-Stream und LiveSession

**Files:**
- Create: `Client/EventLines.swift`, `Client/LiveSession.swift`, `Tests/HerdrKitTests/LiveSessionTests.swift`

**Interfaces:**
- Consumes: `HerdrClient`, `RemoteShell.stream`.
- Produces:
  - `extension HerdrClient { nonisolated func eventStream(types: [String]) -> AsyncThrowingStream<HerdrEvent, Error> }` (baut `SocketCommand.stream` mit `events.subscribe`, Zeilen über `LineSplitter`)
  - `struct HerdrEvent: Sendable { type: String; paneId: String?; workspaceId: String?; agentStatus: AgentStatus?; raw: Data }`
  - `struct LineSplitter { mutating func feed(_ data: Data) -> [Data] }` (teilt an `\n`, puffert Reste)
  - `@MainActor @Observable final class LiveSession { init(client: HerdrClient, pollInterval: Duration = .seconds(3), debounce: Duration = .milliseconds(300)); private(set) var snapshot: HerdrSnapshot?; private(set) var state: ConnectionState; func start() async; func stop(); func refresh() async }`
  - `enum ConnectionState: Equatable { case idle, connecting, live, polling, failed(String) }`
- Ablauf `start()`: `connect()` → `snapshot()` → Event-Stream mit Typen `["pane.created","pane.closed","pane.updated","pane.exited","pane.agent_detected","workspace.created","workspace.closed","workspace.updated","tab.created","tab.closed","layout.updated"]`. Erste Zeile `subscription_started` → `.live`. Jedes weitere Event → entprellter `refresh()`. Stream bricht ab oder startet nicht innerhalb 5 s → `.polling` mit `pollInterval`. Format eines Events beim Spike prüfen (eine Zeile mitschneiden mit `ssh Testserver` + eigenem Pane in Session `herdrapp-test`) und als Fixture `event_pane_updated.json` ablegen.
- `stop()` beendet Stream und Polling (wird beim Wechsel in den Hintergrund aufgerufen).

- [ ] **Step 1:** Tests: `splitterHandlesPartialLines`, `subscriptionStartedGoesLive`, `eventsTriggerDebouncedRefresh` (5 Events in 100 ms → genau 1 zusätzlicher `snapshot`-Aufruf), `streamFailureFallsBackToPolling`, `stopCancelsEverything`.
- [ ] **Step 2:** FAIL → implementieren → PASS (`swift test --filter LiveSessionTests`).
- [ ] **Step 3:** Commit `feat(kit): live session with events and polling fallback`.

### Task 6: SSH-Keys, Server-Profile, Known Hosts, App-Sperre

**Files:**
- Create: `Keys/SSHKeyImport.swift`, `Keys/KeyStore.swift`, `Keys/KnownHosts.swift`, `Servers/ServerProfile.swift`, `Security/AppLockPolicy.swift`, `Tests/HerdrKitTests/KeysTests.swift`, Fixtures `test_ed25519`, `test_ed25519_pass` (Passphrase `geheim`), `test_rsa` – frisch mit `ssh-keygen` erzeugt, nur Test-Keys.

**Interfaces:**
- Produces:
  - `enum SSHKeyKind: String, Codable { case ed25519, rsa }`
  - `struct ParsedKey: Sendable { kind: SSHKeyKind; publicKeyOpenSSH: String; fingerprintSHA256: String }` (Format wie `ssh-keygen -lf`: `SHA256:…`)
  - `enum SSHKeyImport { static func parse(_ pem: String, passphrase: String?) throws -> ParsedKey }`; Fehler `KeyImportError.needsPassphrase | .wrongPassphrase | .unsupported(String) | .invalid` (deutsche Meldungen). Nutzt Citadels OpenSSH-Parser (`Curve25519.Signing.PrivateKey(sshEd25519:decryptionKey:)`, `Insecure.RSA.PrivateKey(sshRsa:decryptionKey:)`).
  - `struct StoredKeyRef: Codable, Identifiable { id: UUID; label: String; kind: SSHKeyKind; publicKeyOpenSSH: String; fingerprintSHA256: String; hasPassphrase: Bool }`
  - `protocol KeyStore: Sendable { func save(pem: String, passphrase: String?, for id: UUID) throws; func load(_ id: UUID) throws -> (pem: String, passphrase: String?); func delete(_ id: UUID) throws }` + `final class InMemoryKeyStore: KeyStore`
  - `struct ServerProfile: Codable, Identifiable, Equatable { id: UUID; name: String; host: String; port: Int = 22; user: String; keyId: UUID; herdrPath: String = "herdr"; session: String?; requiresVPN: Bool = false; vpnApp: String?; lastKnownCounts: [AgentStatus: Int] }`
  - `final class JSONFileStore<T: Codable> { init(url: URL); func load() -> T?; func save(_ value: T) throws }` (für `[ServerProfile]`, `[StoredKeyRef]`, Known Hosts)
  - `struct KnownHosts: Codable { mutating func check(host: String, port: Int, fingerprint: String) -> HostKeyVerdict }`; `enum HostKeyVerdict { case trusted, unknown, changed(previous: String) }`; `mutating func trust(host:port:fingerprint:)`
  - `struct AppLockPolicy { static let backgroundLimit: TimeInterval = 300; static func shouldLock(backgroundedAt: Date?, now: Date) -> Bool }` (nil → true)
- [ ] **Step 1:** Tests: `parsesEd25519` (Fingerprint == Ausgabe `ssh-keygen -lf`, im Test als Konstante), `parsesRSA`, `encryptedNeedsPassphrase`, `encryptedWithPassphrase`, `wrongPassphraseFails`, `unknownHostIsUnknown`, `trustedHostIsTrusted`, `changedHostKeyIsRejected` (`.changed(previous:)`), `profilesRoundTrip`, `lockAfter301Seconds` (`true`), `noLockAfter299Seconds` (`false`).
- [ ] **Step 2:** FAIL → implementieren → PASS (`swift test --filter KeysTests`).
- [ ] **Step 3:** Commit `feat(kit): key import, profiles, known hosts, lock policy`.

### Task 7: Citadel-Transport + Integrationstest gegen Testserver

**Files:**
- Create: `Transport/CitadelShell.swift`, `Tests/IntegrationTests/VPSIntegrationTests.swift`

**Interfaces:**
- Consumes: `RemoteShell`, `KnownHosts`, `SSHKeyImport`.
- Produces:
  - `final class CitadelShell: RemoteShell { static func connect(profile: ServerProfile, pem: String, passphrase: String?, hostKeyCheck: @Sendable (String) async -> Bool) async throws -> CitadelShell; func openPTY(command: String, cols: Int, rows: Int) async throws -> PTYSession; func close() async }`
  - `protocol PTYSession: AnyObject { var output: AsyncThrowingStream<Data, Error> { get }; func write(_ data: Data) async throws; func resize(cols: Int, rows: Int) async throws; func close() async }`
  - `hostKeyCheck` bekommt den SHA256-Fingerprint; `false` → Verbindung abbrechen mit `HerdrError.transport("Host-Key nicht vertraut")`. Verbindungs-Timeout 10 s.
- [ ] **Step 1:** Integrationstest (nur wenn `HERDR_IT_HOST` gesetzt; liest `HERDR_IT_USER`, `HERDR_IT_KEY` = Pfad zum privaten Key): `connectsAndReadsStatus` (`protocolVersion == 22`), `listsWorkspaces` (≥ 1), `eventStreamStarts` (erste Zeile `subscription_started` innerhalb 5 s). Schreibende Prüfung `promptRoundTrip` nur in einer eigenen Session: `herdr --session herdrapp-test` per Exec starten ist interaktiv – daher nur `pane.send_text` an ein Pane, das der Test selbst per `workspace.create` in der Session `herdrapp-test` anlegt, und dieses danach (nur dieses) schließen.
- [ ] **Step 2:** Run `HERDR_IT_HOST=203.0.113.10 HERDR_IT_USER=ubuntu HERDR_IT_KEY=~/.ssh/<key für Testserver> swift test --filter IntegrationTests` → zuerst FAIL, nach Implementierung PASS. (Welcher Key gilt: `ssh -G Testserver | grep identityfile` und der, mit dem `ssh -v` sich anmeldet.)
- [ ] **Step 3:** Commit `feat(kit): citadel ssh transport with integration tests`.

### Task 8: App – Sperre, Keys, Serverliste

**Files:**
- Create: `App/Security/KeychainKeyStore.swift`, `App/Security/AppLock.swift`, `App/Stores/AppModel.swift`, `App/Views/LockView.swift`, `App/Views/ServerListView.swift`, `App/Views/ServerEditView.swift`, `App/Views/KeyListView.swift`, `App/Views/KeyImportView.swift`, `App/Views/HostKeyPromptView.swift`

**Interfaces:**
- Consumes: `KeyStore`, `SSHKeyImport`, `ServerProfile`, `JSONFileStore`, `KnownHosts`, `AppLockPolicy`.
- Produces: `@MainActor @Observable final class AppModel { servers: [ServerProfile]; keys: [StoredKeyRef]; isLocked: Bool; func unlock() async; func session(for: ServerProfile) async throws -> LiveSession; func shell(for: ServerProfile) -> CitadelShell? }` – hält pro Server höchstens eine Verbindung; `scenePhase == .background` → `stop()` aller Sessions und Zeitstempel merken; `.active` → `AppLockPolicy` prüfen, ggf. sperren, sonst aktive Session neu starten.
- `KeychainKeyStore`: `kSecClassGenericPassword`, Service `de.kozarzewski.herdrapp.keys`, Account = UUID, Zugriff mit `SecAccessControlCreateWithFlags(…, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence)`; Lesen mit dem gemeinsamen, beim Entsperren authentifizierten `LAContext` (`kSecUseAuthenticationContext`), damit nur einmal Face ID kommt.
- KeyImportView: Einfügen-Knopf (Zwischenablage), Datei-Import (`.fileImporter`, alle Dateitypen), Passphrase-Feld `.textContentType(.password)`, „Passphrase merken“, nach Import „Zwischenablage leeren?“; zeigt Fingerprint + öffentlichen Key mit Kopieren-Knopf.
- ServerListView: Zeilen mit Name, `user@host`, zuletzt bekannte Zähler (blocked/working/done) – verbindet **nicht** automatisch.
- [ ] **Step 1:** Implementieren; Previews mit `InMemoryKeyStore`.
- [ ] **Step 2:** Build für Simulator → `BUILD SUCCEEDED`; im Simulator: Test-Key einfügen, Server Testserver anlegen, Fingerprint-Dialog erscheint beim ersten Verbinden. Screenshot per `xcrun simctl io booted screenshot` prüfen.
- [ ] **Step 3:** Commit `feat(app): lock, key import, server list`.

### Task 9: App – Server-Übersicht und Agent-Detail

**Files:**
- Create: `App/Views/ServerOverviewView.swift`, `App/Views/AgentRow.swift`, `App/Views/StatusBadge.swift`, `App/Views/AgentDetailView.swift`, `App/Views/ApprovalBar.swift`, `App/Navigation/DeepLink.swift`

**Interfaces:**
- Consumes: `LiveSession`, `HerdrClient`, `HerdrSnapshot`.
- Produces: `enum DeepLink: Equatable { case server(UUID), agent(server: UUID, target: String); init?(url: URL) }` für `herdrapp://server/<uuid>` und `herdrapp://server/<uuid>/agent/<name-oder-pane-id>` (in Teil 2 von ntfy genutzt). Test `deepLinkParsing` in `HerdrKitTests` (DeepLink in `HerdrKit/Model/DeepLink.swift` ablegen, damit testbar).
- Übersicht: Abschnitt „Braucht dich“ (`needsAttention`), dann Workspaces → Tabs → Panes; Agents mit `StatusBadge` (Farben: blocked rot, done grün, working blau, idle grau, unknown grau). Verbindungsstatus oben (live/polling/Fehler mit deutscher Meldung + „Erneut versuchen“).
- Agent-Detail: monospaced Text aus `readAgent` (auf letzten Stand scrollen), Hinweis „gekürzt“ wenn `truncated`, Aktualisierung bei Snapshot-Änderung des Agents (`revision`) und Pull-to-refresh; Eingabefeld → `prompt`; bei `.blocked` `ApprovalBar` mit Tasten `Enter`, `Esc`, `1`, `2`, `3`, `y`, `n`, `Ctrl+C` → `sendKeys` mit herdr-Key-Namen (`enter`, `esc`, `1`, …, `ctrl+c`; Namen per `herdr agent send-keys --help` bestätigen). Knopf „Terminal“.
- [ ] **Step 1:** `deepLinkParsing`-Test schreiben → FAIL → implementieren → PASS.
- [ ] **Step 2:** Views implementieren; Build → `BUILD SUCCEEDED`.
- [ ] **Step 3:** Manuell im Simulator gegen Testserver: In Session `herdrapp-test` (nicht in der Haupt-Session!) einen Agent starten, in der App sehen, Prompt senden, Status wechselt live. Screenshot prüfen.
- [ ] **Step 4:** Commit `feat(app): server overview and agent detail`.

### Task 10: App – Terminal

**Files:**
- Create: `App/Views/TerminalScreen.swift`, `App/Views/TerminalKeyBar.swift`

**Interfaces:**
- Consumes: `CitadelShell.openPTY`, SwiftTerm `TerminalView` (UIKit, via `UIViewRepresentable`).
- Befehl: Agent → `login("<herdrPath> agent attach <quoted target>")`; Pane ohne Agent und „ganze Oberfläche“ → `login("<herdrPath>" + (session.map { " --session \($0)" } ?? ""))`. Kein `--takeover` ohne ausdrückliche Nutzeraktion (eigener Menüpunkt „Übernehmen“).
- Größe: bei Layout-Änderung `resize(cols:rows:)`. Tastenleiste über der Tastatur: Esc, Tab, Ctrl (einrastend), ←↑↓→, `|`, `~`.
- [ ] **Step 1:** Implementieren; Build → `BUILD SUCCEEDED`.
- [ ] **Step 2:** Manuell im Simulator: Terminal zu Agent in `herdrapp-test` öffnen, tippen, Ctrl+C, Rotation → Größe passt. Screenshot prüfen.
- [ ] **Step 3:** Commit `feat(app): interactive terminal`.

### Task 11: Installation aufs iPhone + README

**Files:**
- Create: `README.md`

- [ ] **Step 1:** README (Deutsch): Voraussetzungen; `brew install xcodegen`; `xcodegen generate`; in Xcode Personal Team wählen; iPhone verbinden, Entwicklermodus aktivieren, Profil vertrauen; **Ablauf nach 7 Tagen** und Erneuerung (erneut „Run“ in Xcode oder SideStore-Einrichtung mit Link); Key aus Bitwarden übernehmen (kopieren → „Einfügen“ in der App → Zwischenablage leeren).
- [ ] **Step 2:** `swift test` im Package → alle Tests PASS; App-Build → `BUILD SUCCEEDED`.
- [ ] **Step 3:** Commit `docs: install guide`.
