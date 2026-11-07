# herdr iOS App – Teil 3: Sprachsteuerung Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per Sprache steuern: Navigation („gehe zu Agent 3“), Freigaben („ja, freigeben“), Prompts an Agents, Shell-Befehle in natürlicher Sprache („zeige mir die Ordner“ → Befehl, bestätigt) und Zusammenfassungen (Agent oder Datei) als Text oder vorgelesen.

**Architecture:** Spracherkennung auf dem Gerät mit Apples `SpeechAnalyzer`/`SpeechTranscriber` (iOS 26). Deutung zweistufig: lokale Regeln (sofort, ohne Netz) und sonst `claude -p` auf dem VPS mit `--json-schema` (Abo des Nutzers, schnelles Modell). Reine Logik in HerdrKit (testbar), Audio/Oberfläche in der App.

**Tech Stack:** Swift 6.4, Speech (`SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory`), AVFoundation (`AVAudioEngine`, `AVSpeechSynthesizer`), Claude Code CLI 2.1.x auf dem VPS.

**Spec:** `docs/superpowers/specs/2026-11-05-herdr-ios-app-design.md` (Abschnitt 5.4)

## Abweichung von der Spec (Ruling)

Spec 5.4 nennt **WhisperKit**. Ersetzt durch **Apple `SpeechAnalyzer`** (iOS 26, im SDK vorhanden): ebenfalls auf dem Gerät, deutsche Sprache, eigenes Vokabular über `AnalysisContext.contextualStrings` (herdr, Claude, git, Agent-Namen), Modell verwaltet iOS selbst (kein mehrere-hundert-MB-Download in der App, keine Abhängigkeit – wichtig bei der langsamen GitHub-Verbindung des Nutzers). Kosten falls falsch: Erkennung von Fachbegriffen schlechter als Whisper; dann WhisperKit als zweiten Erkenner nachrüsten.

## Verifizierte Fakten (Testserver, Claude Code 2.1.318)

```
claude -p --model haiku --tools "" --no-session-persistence --setting-sources "" --strict-mcp-config \
  --json-schema '<schema>' --output-format json "<prompt>"
```
liefert in ~4 s JSON mit `"is_error": false`, `"structured_output": {…}` (schema-konform) und `"result"` (Text). Läuft über das Abo, keine API-Keys.

## Global Constraints

- Shell-Befehle aus Sprache werden **immer** angezeigt und erst nach Tippen auf „Ausführen“ gestartet; gefährliche (Regeln in Task 2) brauchen **zweites** Bestätigen (rote Warnung).
- Prompt an Agent: Text sichtbar, sendet nach **3 s** automatisch, außer „Abbrechen“ oder Bearbeiten.
- Freigaben: nur wenn Agent `blocked`; klar erkannte Freigabe wird direkt gesendet, Ausschnitt des Dialogs bleibt sichtbar; Unklares → Nachfrage, nie raten.
- Navigation: sofort.
- `claude -p` immer mit `--tools ""` (Deutung, Agent-Zusammenfassung) bzw. `--tools Read` (Datei-Zusammenfassung), `--no-session-persistence`, `--setting-sources ""`, `--strict-mcp-config`, Arbeitsverzeichnis `/tmp` bzw. Ordner der Datei; Timeout 90 s; Modell Deutung `haiku`, Zusammenfassung `sonnet`.
- Prompt-Texte an `claude -p` gehen per Base64 in den Befehl (wie Socket-Anfragen), nie roh in die Shell.
- Antwortart Text/Audio: App fragt, „Nicht mehr fragen“ speichert den Standard.
- Oberfläche Deutsch; Sprache der Erkennung `de-DE` (Einstellung erlaubt `en-US`).
- Info.plist: `NSMicrophoneUsageDescription` = „Für Sprachbefehle an deine Agents.“, `NSSpeechRecognitionUsageDescription` = „Wandelt deine Sprachbefehle auf dem iPhone in Text um.“

## Review Focus

1. **Missverstandener Shell-Befehl** → nie ohne Bestätigung ausgeführt; `rm`, `sudo`, `>`-Umleitung auf Dateien, `git push --force`, `kill`, `mv` über Bestehendes, `chmod -R`, `dd`, `mkfs`, Pipes nach `sh` gelten als gefährlich – Test in Task 2 (`dangerousCommandsAreFlagged`).
2. **„Ja“ zur falschen Zeit** (Agent nicht blocked) → wird nicht als Freigabe gesendet, sondern als Prompt behandelt bzw. nachgefragt – Test in Task 1 (`yesWithoutBlockedAgentIsNotApproval`).
3. **Claude liefert Unsinn / kein JSON / Fehler / Timeout** → verständliche Meldung, nichts wird ausgeführt – Test in Task 2 (`malformedClaudeOutputIsUnknown`).
4. **Sonderzeichen im gesprochenen Text** (Anführungszeichen, `$`, Umlaute) erreichen `claude -p` unverändert – Test in Task 2 (`transcriptTravelsBase64`).
5. **Mikrofon-/Spracherkennungs-Rechte verweigert oder Modell nicht verfügbar** → klare Meldung mit Weg in die Einstellungen, Tippen-Eingabe bleibt möglich – manuell in Task 4.

---

## Dateistruktur

```
Packages/HerdrKit/Sources/HerdrKit/Voice/VoiceIntent.swift        Absicht-Typen
Packages/HerdrKit/Sources/HerdrKit/Voice/LocalIntentParser.swift  Regeln (Navigation, Freigabe, Präfixe), Zahlwörter, unscharfer Namensabgleich
Packages/HerdrKit/Sources/HerdrKit/Voice/ClaudeAssistant.swift    claude -p: Deutung, Zusammenfassungen
Packages/HerdrKit/Sources/HerdrKit/Voice/CommandSafety.swift      Gefahren-Erkennung für Shell-Befehle
Packages/HerdrKit/Tests/HerdrKitTests/VoiceTests.swift
Packages/HerdrSSH/Tests/IntegrationTests/VoiceIntegrationTests.swift
App/Voice/SpeechInput.swift          SpeechAnalyzer + AVAudioEngine, Rechte, Modell-Installation
App/Voice/Speaker.swift              AVSpeechSynthesizer (deutsche Stimme)
App/Voice/VoiceCoordinator.swift     Ablauf: Transkript → Absicht → Bestätigung → Ausführung
App/Views/VoiceSheet.swift           Transkript (editierbar), Bestätigungen, Antwort
App/Views/MicButton.swift            Halten = sprechen, Tippen = Start/Stopp
App/Views/ServerOverviewView.swift, AgentDetailView.swift, ServerEditView/Settings (ändern)
```

---

### Task 1: Absichten + lokale Regeln

**Interfaces:**
- `enum VoiceIntent: Equatable, Sendable { case navigateAgent(target: String); case navigateBack; case openTerminal; case approve(keys: [String]); case prompt(text: String); case shell(command: String, explanation: String, cwd: String?); case summarizeAgent(target: String?); case summarizeFile(path: String); case unknown(question: String) }`
- `struct VoiceContext: Sendable { var agents: [Agent]  /* orderedAgents */; var currentAgent: Agent?; var cwd: String? }`
- `enum LocalIntentParser { static func parse(_ transcript: String, context: VoiceContext) -> VoiceIntent?  /* nil = an Claude weitergeben */ }`
- Regeln (Groß/Klein egal, Satzzeichen ignoriert, deutsch + englisch):
  - „gehe zu / öffne / zeige agent <n|name>“, „go to agent …“ → `.navigateAgent` (Zahl = Position in `agents`, Zahlwörter eins…zwölf, „ersten…zehnten“; Name unscharf: Levenshtein ≤ 2 oder Präfix, eindeutig; sonst nil)
  - „zurück“, „back“ → `.navigateBack`; „terminal (öffnen)“ → `.openTerminal`
  - nur wenn `currentAgent?.agentStatus == .blocked`: „ja / freigeben / erlauben / okay / yes / approve / weiter“ → `.approve(["enter"])`; „nein / ablehnen / abbrechen / no / deny“ → `.approve(["esc"])`; „option <n>“ / „<n>“ (1–9, auch Zahlwort) → `.approve(["<n>"])`
  - „befehl: …“ / „command: …“ → nil mit Flag `forceShell` (siehe Task 2); „zusammenfassung“ / „fasse zusammen“ ohne „datei“ → `.summarizeAgent(target: currentAgent?.target)`
  - im Agent-Kontext alles andere → `.prompt(text: transcript)`; ohne Agent-Kontext → nil
- [ ] **Step 1: Tests:** `gotoAgentByNumber` („Gehe zu Agent 3“ → drittes Agent-Target), `gotoAgentByWordNumber` („öffne den zweiten Agent“), `gotoAgentByFuzzyName` („gehe zu reviwer“ → reviewer), `ambiguousNameGoesToClaude` (nil), `back`, `terminal`, `approveWhenBlocked`, `denyWhenBlocked`, `optionTwo`, `yesWithoutBlockedAgentIsNotApproval` (→ `.prompt("ja")`), `summaryOfCurrentAgent`, `freeTextInAgentIsPrompt`, `freeTextInOverviewGoesToClaude` (nil), `commandPrefixIsNotPrompt`.
- [ ] **Step 2:** `swift test --filter VoiceTests` → FAIL → implementieren → PASS. Commit `feat(kit): voice intents and local rules`.

### Task 2: Claude-Deutung + Gefahren-Erkennung

**Interfaces:**
- `struct ClaudeAssistant { init(shell: RemoteShell, claudePath: String = "claude"); func interpret(_ transcript: String, context: VoiceContext, forceShell: Bool) async throws -> VoiceIntent; func summarize(agentOutput: String, agentName: String) async throws -> String; func summarize(file path: String) async throws -> String }`
- Befehl (in `bash -lc`, Arbeitsverzeichnis `/tmp`): `printf %s <b64-prompt> | base64 -d | timeout 90 <claude> -p --model haiku --tools "" --no-session-persistence --setting-sources "" --strict-mcp-config --json-schema <quoted schema> --output-format json` – der Prompt kommt über stdin (Claude Code liest ihn dort, wenn kein Argument folgt), damit kein gesprochener Text die Shell berührt. Vor Task 2 einmal live prüfen, dass stdin-Prompt + `--json-schema` zusammen funktionieren.
- Schema-Felder: `type` (enum `shell|prompt_agent|summarize_agent|summarize_file|navigate|unknown`), `command`, `cwd`, `agent`, `text`, `path`, `explanation`, `question`. System-Anweisung (Deutsch) beschreibt Kontext: Agents (Position, Name, Status, cwd), aktuelles Verzeichnis, Regel „nur lesende Befehle, wenn nicht ausdrücklich verlangt“.
- Ergebnis: `is_error == true` oder fehlendes/ungültiges `structured_output` → `.unknown(question: "Das habe ich nicht verstanden …")`; Prozess-Fehler/Timeout → `ClaudeError.failed(String)` (deutsche Meldung, „claude nicht gefunden / nicht angemeldet“ erkennen: Exit 127, „login“ im stderr).
- `enum CommandSafety { static func isDangerous(_ command: String) -> Bool }` – Muster: `\brm\b`, `\bsudo\b`, `\bdd\b`, `\bmkfs`, `\bkill(all)?\b`, `\bshutdown|reboot\b`, `git\s+push\b.*(--force|-f\b)`, `git\s+reset\s+--hard`, `git\s+clean`, `chmod\s+-R`, `chown\s+-R`, `\bmv\b`, `>\s*[^&|]` (Umleitung in Datei, nicht `2>&1`), `\|\s*(ba|z)?sh\b`, `curl[^|]*\|`, `:\(\)\s*\{`.
- [ ] **Step 1: Tests** (FakeShell): `transcriptTravelsBase64` (Transkript `„lösche $HOME 'x'“` → aus dem Befehl dekodiert identisch, Befehl enthält kein `$HOME` roh), `parsesShellIntent` (Fixture = echte Antwort oben), `parsesPromptIntent`, `malformedClaudeOutputIsUnknown`, `isErrorIsUnknown`, `claudeMissingIsClearError` (Exit 127), `usesHaikuAndNoTools`, `fileSummaryAllowsReadOnly` (`--tools Read`, cwd = Ordner der Datei), `dangerousCommandsAreFlagged` (je ein Beispiel pro Muster true; `ls -la`, `git status`, `cat a 2>&1`, `find . -type d` false).
- [ ] **Step 2:** FAIL → implementieren → PASS. Commit `feat(kit): claude assistant and command safety`.

### Task 3: Live-Test Claude-Deutung (Testserver)

- [ ] Integrationstest: `interpret("zeige mir die Ordner an", context mit cwd "/home/ubuntu")` → `.shell` mit nicht-gefährlichem Befehl; `interpret("schreib dem reviewer, er soll die Tests laufen lassen", context mit Agent reviewer)` → `.prompt`/`prompt_agent` an reviewer; `summarize(agentOutput: "<kurzer Text>", agentName:)` → nicht leer. Höchstens 3 Aufrufe (Abo). Commit `test(voice): live interpretation`.

### Task 4: Spracheingabe + Vorlesen (App)

**Interfaces:**
- `@MainActor @Observable final class SpeechInput { var state: State /* idle, preparing, listening, failed(String) */; var transcript: String; var locale: Locale; func start(contextualStrings: [String]) async; func stop() async -> String }` – Rechte (`AVAudioApplication.requestRecordPermission`, `SFSpeechRecognizer.requestAuthorization` bzw. Speech-Rechte für SpeechAnalyzer), `AssetInventory` installiert das Sprachmodell bei Bedarf (Fortschritt anzeigen), `SpeechTranscriber(locale:, preset: .progressiveTranscription)` bzw. passendes Preset für Live-Teilergebnisse, `AnalysisContext.contextualStrings[.general] = ["herdr", "Claude", "Codex", "git", …Agent-Namen]`, Audio über `AVAudioEngine`-Tap → `AsyncStream<AnalyzerInput>`.
- `@MainActor final class Speaker { func say(_ text: String); func stop() }` – beste installierte deutsche Stimme (Premium > Enhanced > Default).
- Info.plist-Schlüssel (Global Constraints) in `project.yml`.
- [ ] **Step 1:** Implementieren; Build `BUILD SUCCEEDED`. Manuell im Simulator: Rechte-Dialog erscheint, Verweigern zeigt Hinweis mit Link zu Einstellungen. Commit `feat(app): on-device speech input and speaker`.

### Task 5: Sprach-Ablauf + Bestätigungen (App)

**Interfaces:**
- `@MainActor @Observable final class VoiceCoordinator { init(model: AppModel, serverId: UUID, agentTarget: String?); var phase: Phase; func handle(transcript: String) async; func confirmShell(); func cancel() }` – `Phase`: `.thinking`, `.confirmShell(cmd, explanation, dangerous, cwd)`, `.confirmShellAgain`, `.running`, `.output(String)`, `.promptCountdown(text, remaining)`, `.askAnswerMode(summary-pending)`, `.answer(String)`, `.unknown(String)`, `.error(String)`.
- Ausführung Shell: **eigener SSH-Exec-Kanal** im `cwd` (Agent-cwd oder Home), Ausgabe max. 200 KB anzeigen; keine Panes/Splits (Ruling: sicherer als Tippen in fremde Panes; Spec ließ die Wahl offen).
- Prompt: `HerdrClient.prompt` nach 3-s-Countdown; Freigabe: `sendKeys`; Navigation: `AppModel.pendingPath`.
- Antwortart: `@AppStorage("voiceAnswerMode")` = `ask|text|audio`.
- `VoiceSheet` zeigt je Phase: Transkript-Feld (bearbeitbar + „Erneut deuten“), Befehl in Monospace mit Erklärung, rote Warnung + zweiter Knopf bei Gefahr, Countdown-Balken, Ausgabe/Antwort mit Kopieren und „Vorlesen“.
- [ ] **Step 1:** Implementieren; Build → `BUILD SUCCEEDED`. Commit `feat(app): voice flow with confirmations`.

### Task 6: Einbinden + Einstellungen + README

- [ ] `MicButton` in ServerOverview (Toolbar unten) und AgentDetail (neben dem Eingabefeld). Gedrückt halten = aufnehmen, loslassen = deuten; Tippen = Start/Stopp. Einstellungen-Abschnitt „Sprache“ (Erkennungssprache, Antwortart, Stimme testen) in einer neuen `SettingsView` (Zahnrad in der Serverliste). README-Abschnitt „Sprachsteuerung“. Alle Suiten grün, Build grün. Commit `feat(app): voice everywhere, settings, docs`.
