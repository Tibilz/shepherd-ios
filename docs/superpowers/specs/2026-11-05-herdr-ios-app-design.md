# herdr iOS App – Design

Stand: 2026-11-05

## 1. Absicht und Warum

Der Nutzer arbeitet mit **herdr** (v0.9.5, „terminal workspace manager for AI coding agents“, https://herdr.dev) auf einem oder mehreren VPS. Auf denen laufen Coding-Agents (u. a. Claude Code, mit seinem Claude-Abo angemeldet) in herdr-Workspaces/Tabs/Panes.

Er will vom iPhone aus:

1. die App öffnen und seine **VPS-Verbindungen** (SSH, je eigener SSH-Key) sehen,
2. eine auswählen und eine **ähnliche Sicht wie in der Desktop-Version** bekommen: Workspace/Space bzw. Agent wählen, die **Konversation** sehen, ins **Terminal** gehen,
3. per **Sprache** steuern – besser als das iOS-Diktat, und mit Verständnis für Absichten:
   - „Zeige mir die Ordner an“ → `ls`
   - „Gehe zu Agent 3“ → Navigation in der App
   - „Gib mir eine Zusammenfassung der Datei / von dem, was der Agent gemacht hat“ → App fragt: Antwort als **Text oder Audio**?
4. **Benachrichtigungen** aufs Handy bekommen (global und pro Agent ein-/ausschaltbar),
5. Server erreichen, die **hinter einem VPN** liegen (WireGuard, Cisco, OpenVPN).

Erfolg: Er kann unterwegs einen Agenten-Zustand prüfen, eine Freigabe geben, einen Prompt einsprechen und eine Zusammenfassung hören, ohne Laptop.

## 2. Ziele, Nicht-Ziele, Anti-Ziele

**Ziele**
- Mehrere Server verwalten, je mit eigenem SSH-Key.
- Übersicht: Workspaces → Tabs → Panes/Agents mit Live-Status (`idle`, `working`, `blocked`, `done`, `unknown`).
- Agent-Detailansicht: Konversation (lesbare Ausgabe) + Prompt senden + Freigabe-Dialoge beantworten (Tasten senden).
- Volles interaktives Terminal (Attach an Agent/Pane).
- Sprachsteuerung mit Absichtserkennung, Bestätigung vor Shell-Ausführung, Antwort als Text oder vorgelesen.
- Push-Benachrichtigungen bei Statuswechseln, global und pro Agent schaltbar.
- VPN-Anforderung pro Server, mit klarem Hinweis wenn nicht erreichbar.

**Nicht-Ziele (v1)**
- iPad-/Mac-Layout, Widgets, Apple Watch.
- Eingebauter VPN-Client.
- Workspaces/Worktrees anlegen oder schließen (nur lesen, fokussieren, prompten, Tasten senden, Befehle ausführen). Kann später kommen.
- App Store-Veröffentlichung.

**Anti-Ziele (wäre ein Fehlschlag, selbst wenn es technisch funktioniert)**
- Ein per Sprache missverstandener Befehl wird **ohne Bestätigung** ausgeführt.
- Der private SSH-Key liegt unverschlüsselt herum oder verlässt das Gerät.
- Claude-Abo-Zugangsdaten werden in die App geholt oder ein inoffizieller Abo-Login nachgebaut.
- Die App schließt Panes/Workspaces, die der Nutzer nicht ausdrücklich schließen wollte.

## 3. Rahmenbedingungen

- **Kein bezahltes Apple-Developer-Konto**, und der Nutzer will keins anlegen. Folgen:
  - Installation per Xcode mit kostenloser Apple-ID (Personal Team). Signatur läuft nach **7 Tagen** ab → neu installieren per Xcode oder **SideStore** (Auto-Refresh auf dem Gerät). Kurze Anleitung gehört zum Lieferumfang.
  - **Kein APNs** (keine eigenen Push-Nachrichten), **kein Network Extension** (kein eingebautes VPN).
  - Bundle-ID muss eindeutig sein (z. B. `de.<name>.herdrapp`); keine Entitlements nutzen, die das Personal Team nicht erlaubt (Push, Network Extension, iCloud-Container usw.). Keychain-Zugriff und Face ID gehen.
- Mac mit **Xcode 27.1** und iOS-26.5-Simulator ist vorhanden. Mindest-iOS: **iOS 26**.
- **herdr läuft auf dem VPS** als Server mit Socket-API (protocol 22). Claude Code ist dort installiert und mit dem Abo des Nutzers angemeldet.
- **Bitwarden** ist der Ort, an dem der Nutzer seine SSH-Keys verwaltet. iOS gibt Drittanbieter-Apps keinen Zugriff auf Bitwarden-SSH-Keys.
- **Claude nur über das Abo**, kein API-Key. Drittanbieter-Apps dürfen sich nicht mit einem Abo anmelden → Claude wird ausschließlich über `claude -p` **auf dem VPS** genutzt.

## 4. Vom Nutzer entschieden

- Native iPhone-App.
- SSH-Key pro Verbindung angebbar.
- Bitwarden als Key-Quelle (umgesetzt als einmaliger Import, siehe 5.2).
- Claude über das bestehende Abo (umgesetzt über Claude Code auf dem VPS).
- Benachrichtigungen global + pro Agent schaltbar.
- VPN-Unterstützung für WireGuard/Cisco/OpenVPN-Szenarien, soweit möglich.
- Alle technischen Entscheidungen hat er an den Builder/Claude übergeben („Mach alles was möglich ist“).

## 5. Lösung

### 5.1 Architektur

```
iPhone-App ──SSH (Citadel)──► VPS
   │                           ├─ herdr server (Unix-Socket ~/.config/herdr/herdr.sock)
   │                           ├─ herdr CLI (JSON-Ausgabe)
   │                           ├─ claude -p (Abo, für Deutung/Zusammenfassung)
   │                           └─ herdr-notify (Begleitdienst, systemd --user)
   │                                   └──HTTPS──► ntfy (ntfy.sh oder selbst gehostet)
   └──◄── Push über ntfy-iOS-App, Tap öffnet herdrapp://…-Deeplink
```

**Zugriff auf herdr:** Die App führt über SSH-Exec-Kanäle die `herdr`-CLI aus (`herdr workspace list`, `herdr agent list`, `herdr agent read …`, `herdr agent prompt …`, `herdr pane run …` usw.) und parst das JSON. Das ist der garantierte Weg.
Für Live-Status nutzt die App, solange sie im Vordergrund ist, einen dauerhaften Exec-Kanal mit dem Event-Abo (`events.subscribe`), sofern über CLI erreichbar; sonst einen Socket-Bridge-Befehl (`socat`/`nc -U` falls vorhanden, oder ein kleiner Helper im Begleitdienst, siehe 5.6). Rückfall: Polling von `agent list` alle 3 s. **Der Builder klärt zu Beginn per Spike**, welche Variante mit dem Server funktioniert (siehe 6).
Referenz: `herdr --skill`, `herdr api schema --json` (lokal vorhanden), https://herdr.dev/llms.txt.

Server-Versionsprüfung bei jedem Verbinden über `herdr status`; bei inkompatiblem Protokoll klare Meldung, **nie** den Server stoppen/aktualisieren.

### 5.2 SSH-Keys und Bitwarden

- Import eines privaten Keys (OpenSSH-Format, Ed25519 und RSA; ECDSA wenn die Bibliothek es kann) über:
  1. **Einfügen aus der Zwischenablage** (Nutzer kopiert in Bitwarden den Key),
  2. **Teilen-Menü / Dateien-App** (`.pem`, `id_ed25519` usw.).
- Gespeichert im **iOS-Schlüsselbund** mit `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` und Zugriffsschutz per **Face ID/Code** (`SecAccessControl` mit `.userPresence`). Nicht in iCloud synchronisiert.
- **Face ID einmal beim Öffnen der App** (vom Nutzer entschieden): ein gemeinsamer `LAContext` entsperrt alle Keys für die App-Sitzung. *Claudes Entscheidung:* nach mehr als 5 Minuten im Hintergrund wird wieder gesperrt; entsperrte Keys liegen nur im Speicher. Die Serverliste verbindet nicht automatisch mit allen Servern, sondern zeigt den zuletzt bekannten Stand und aktualisiert nur den gewählten Server.
- Passphrase-geschützte Keys: Passphrase-Feld mit `textContentType = .password`, damit Bitwarden per AutoFill einträgt. Option „Passphrase merken“ (ebenfalls im Schlüsselbund).
- Nach dem Import Zwischenablage leeren anbieten.
- Ein Key kann mehreren Servern zugeordnet sein; Key-Verwaltung separat von Serverliste.
- Öffentlichen Key anzeigen/kopieren (für `authorized_keys`).
- Host-Key-Prüfung: Fingerprint beim ersten Verbinden anzeigen und bestätigen (TOFU), danach speichern; bei Änderung harte Warnung.

### 5.3 Screens

1. **Serverliste**: Name, Host, Status-Punkt (erreichbar/VPN fehlt/Fehler), Anzahl Agents nach Status. Hinzufügen/Bearbeiten: Name, Host, Port, Benutzer, Key, „braucht VPN“ + optional Name der VPN-App, herdr-Session (Standard: default).
2. **Server-Übersicht** (ähnlich Desktop-Sidebar): Workspaces → Tabs → Panes. Agents hervorgehoben mit Name, Typ (claude, codex …) und Status-Badge. Oben eine kompakte Liste „Braucht dich“ (blocked/done).
3. **Agent-Detail**:
   - Konversation: `agent read --source recent-unwrapped`, ANSI-Codes entfernt, monospaced, scrollbar, Pull-to-refresh + Live-Aktualisierung im Vordergrund.
   - Eingabefeld + Mikrofon-Knopf → `agent prompt`.
   - Bei `blocked`: sichtbare Leiste mit Tasten-Shortcuts (Enter, Esc, 1/2/3, y/n, Ctrl+C) → `agent send-keys`.
   - Glocke: Benachrichtigungen für diesen Agent an/aus.
   - Knopf „Terminal“.
4. **Terminal**: SwiftTerm-Ansicht über SSH-PTY, das `herdr agent attach <name>` bzw. für normale Panes das passende Attach ausführt (Builder prüft das genaue Kommando; Fallback `herdr --session <s>` für die volle TUI). Zusatzleiste mit Esc, Tab, Ctrl, Pfeilen.
5. **Einstellungen**: Keys, ntfy (Server-URL, Topic), Benachrichtigungen global, Sprache (Whisper-Modellgröße, Stimme, Standard-Antwortart), Hilfe zur 7-Tage-Neuinstallation.

Sprache der Oberfläche: **Deutsch**.

### 5.4 Sprachsteuerung

**Erkennung:** **WhisperKit** auf dem Gerät (Modell beim ersten Start laden; Standard „small“ oder was auf dem Gerät flüssig läuft, wählbar). Push-to-talk (gedrückt halten) und Tippen zum Starten/Stoppen. Transkript wird immer angezeigt und ist editierbar, bevor etwas passiert.

**Deutung in zwei Stufen:**
1. **Lokal, sofort** (Regeln/Muster, Deutsch + Englisch): Navigation – „gehe zu Agent 3“, „öffne Agent reviewer“, „zurück“, „zeige Terminal“, „Server X“. „Agent 3“ = dritter Agent in der sichtbaren Reihenfolge des aktuellen Servers; Namen werden unscharf abgeglichen.
2. **Sonst über Claude auf dem VPS**: `claude -p --output-format json` mit einem Systemprompt, der den Kontext (aktueller Server, Workspace, cwd des Panes, Agent-Liste) enthält und eine **strukturierte Absicht** zurückverlangt, z. B.:
   - `{"type":"shell","command":"ls -la","target_pane":"w1:p2","explanation":"Zeigt die Ordner"}`
   - `{"type":"prompt_agent","agent":"reviewer","text":"…"}`
   - `{"type":"summarize","source":"agent"|"file","target":"…"}`
   - `{"type":"navigate",…}`, `{"type":"unknown","question":"…"}`
   Modell: schnelles Modell (z. B. `--model haiku`) für Deutung, Standardmodell für Zusammenfassungen. `claude -p` wird in einem neutralen Arbeitsverzeichnis mit eingeschränkten Tools (`--allowedTools` leer bzw. nur Lesen für Datei-Zusammenfassungen) aufgerufen, damit es selbst nichts ausführt.

**Bestätigungsregeln (vom Nutzer abgestimmt):**
- **Navigation** („gehe zu Agent 3“): sofort.
- **Prompt an einen Agent** (gesprochener Text, der als Nachricht an den Agent geht): wird als Text angezeigt und nach 3 s automatisch gesendet, außer der Nutzer tippt „Abbrechen“ oder bearbeitet ihn.
- **Freigaben** bei `blocked`-Agents: per **Sprache oder Button**, beides gleichwertig. Die App zeigt dabei immer sichtbar an, *was* freigegeben wird (Ausschnitt des Freigabe-Dialogs aus `agent read`). Sprachfreigaben („ja“, „freigeben“, „ablehnen“, „Option 2“) werden nur erkannt, während ein Agent wirklich `blocked` ist, und auf die passenden Tasten abgebildet; bei Unklarheit wird nachgefragt statt geraten. *Claudes Entscheidung:* eine klar erkannte Sprachfreigabe wird direkt gesendet, ohne zusätzlichen Tipp.
- **Mikrofon im Agent-Detail**: Gesprochenes geht standardmäßig als Prompt an diesen Agent; nur eindeutige App-Befehle (Navigation, „Terminal“, „Zusammenfassung“) und Freigaben werden abgefangen. Shell-Befehle per Sprache gibt es über das Mikrofon in der Server-Übersicht bzw. ein Präfix wie „Befehl: …“.

**Ausführung:**
- **Shell-Befehle werden immer zur Bestätigung angezeigt** (Befehl + Erklärung + Ziel-Pane). Destruktive Muster (`rm`, `mv` über Bestehendes, `git push --force`, `sudo`, `>` auf Dateien, `kill` …) bekommen eine rote Warnung und einen zweiten Bestätigungsschritt.
- Ausgeführt wird in einem **Shell-Pane** des aktuellen Workspaces (`herdr pane run`), Ausgabe per `pane wait-output`/`pane read` gezeigt. Gibt es keinen freien Shell-Pane, wird über einen separaten SSH-Exec-Kanal im cwd des gewählten Panes ausgeführt (Builder-Entscheidung, welcher Weg Standard ist; keine neuen Panes/Splits ohne Nachfrage).
- **Zusammenfassungen:** App fragt „Als Text oder vorlesen?“ (Standard in Einstellungen speicherbar, „nicht mehr fragen“). Agent-Zusammenfassung: `agent read --lines ~400` → `claude -p`. Datei-Zusammenfassung: `claude -p` liest die Datei auf dem VPS.
- **Vorlesen:** `AVSpeechSynthesizer` mit deutscher Premium-/Enhanced-Stimme falls installiert; Pause/Stopp.

### 5.5 Benachrichtigungen

- Begleitdienst **herdr-notify** auf dem VPS (kleines Skript/Binary, läuft als `systemd --user`-Dienst, Neustart bei Absturz) abonniert herdr-Events und sendet bei Statuswechsel nach `blocked`, `done` (und optional `idle` nach `working`) eine Nachricht an **ntfy**.
- ntfy: Standard `https://ntfy.sh` mit zufälligem, langem Topic (geheim); optional eigener ntfy-Server. Nachricht: Titel „<agent> wartet auf Freigabe“ / „<agent> ist fertig“, Server-Name, Klick-URL `herdrapp://server/<id>/agent/<name>`.
- Nutzer installiert die **ntfy-iOS-App** und abonniert das Topic (App zeigt QR/Link zum Abonnieren).
- **Schalter**: global und pro Agent in der App; gespeichert in einer Konfigdatei auf dem VPS (z. B. `~/.config/herdr-notify/config.json`), die die App per SSH liest/schreibt; der Dienst liest sie bei Änderung neu. Pro-Agent-Schalter hängen am Agent-Namen; neue Agents erben die globale Voreinstellung.
- Entprellung: pro Agent höchstens eine Nachricht pro Statuswechsel, `working`↔`idle`-Flattern ignorieren.
- **Dauerbetrieb** (*Claudes Entscheidung*): Der Dienst muss laufen, wenn keine SSH-Sitzung offen ist. Mit systemd: User-Unit + Linger. Ist Linger aus, zeigt die App den Befehl `sudo loginctl enable-linger <user>` zum selbst Ausführen; die App führt nie sudo aus. Ohne systemd: `nohup`-Hintergrundprozess + `crontab`-Eintrag (`@reboot` und minütlicher Wächter).
- **Installation aus der App heraus**: „Benachrichtigungen einrichten“ kopiert den Dienst per SSH auf den VPS, legt die systemd-Unit an und startet sie – mit Anzeige, was passiert, und Bestätigung. Deinstallieren ebenso.
- Ist die App im Vordergrund, zeigt sie Statuswechsel zusätzlich als In-App-Banner.

### 5.6 VPN

- Pro Server Schalter „braucht VPN“ + optional Auswahl der VPN-App (WireGuard, Cisco Secure Client, OpenVPN Connect).
- Vor dem Verbinden: Erkennung, ob ein VPN-Interface aktiv ist (`NWPathMonitor`/Interface-Namen `utun`/`ipsec`) und ob der Host mit kurzem Timeout erreichbar ist.
- Nicht erreichbar + VPN nötig → klare Meldung „VPN ist nicht verbunden“ mit Knopf zum Öffnen der VPN-App (URL-Schema, falls vorhanden, sonst Hinweis) und automatischem Neuversuch, sobald sich der Netzpfad ändert.
- Hilfeseite: WireGuard „On-Demand“ für das Server-Netz einrichten, damit der Tunnel automatisch hochkommt.

### 5.7 Verbindung und Lebenszyklus

- SSH: **Citadel** (auf SwiftNIO SSH). Eine Verbindung pro Server, mehrere Kanäle (Exec für CLI, PTY fürs Terminal, Dauer-Kanal für Events).
- Beim Wechsel in den Hintergrund: Verbindung sauber trennen, beim Zurückkehren automatisch neu verbinden und Ansicht aktualisieren. Kein Versprechen von Hintergrund-Verbindung (iOS erlaubt es nicht).
- Timeouts und verständliche Fehlermeldungen (Auth fehlgeschlagen, Host-Key geändert, herdr nicht gefunden, herdr-Server läuft nicht, Protokoll inkompatibel, claude nicht gefunden/nicht angemeldet).
- herdr- und claude-Pfad: Login-Shell verwenden (`$SHELL -lc`), damit `PATH` stimmt; überschreibbar pro Server.

### 5.8 Technik

- Swift 6, SwiftUI, iOS 26+, nur iPhone.
- Pakete (SPM): Citadel, SwiftTerm, WhisperKit. Weitere nur bei echtem Bedarf.
- Persistenz: Serverliste/Einstellungen mit SwiftData oder JSON-Datei; Geheimnisse ausschließlich im Schlüsselbund.
- Begleitdienst: Sprache nach Builder-Wahl, Voraussetzung nur was auf einem üblichen Linux-VPS vorhanden ist (z. B. Shell + `curl`, oder ein statisches Binary). Er darf auf dem VPS nichts außerhalb von `~/.config/herdr-notify` und der systemd-User-Unit anlegen.
- Tests: Unit-Tests für JSON-Parsing der herdr-Antworten (mit echten Beispielantworten aus `herdr … ` lokal), lokale Absichtserkennung, Gefahren-Erkennung bei Shell-Befehlen, Benachrichtigungs-Entprellung. Integrationstest gegen einen lokalen herdr-Server über SSH auf `localhost`, wenn möglich.
- Projekt ist ein neues Git-Repo (noch ohne Commits); Projekt mit XcodeGen oder direkt als Xcode-Projekt anlegen (Builder-Wahl).

## 6. Testumgebung

Der Nutzer erlaubt Tests auf seinem echten VPS: SSH-Alias **`Testserver`** (ubuntu@203.0.113.10, Ubuntu aarch64, herdr 0.9.5 läuft, Socket `/home/ubuntu/.config/herdr/herdr.sock`, `claude` in `~/.local/bin`, `nc` und `systemctl` vorhanden). Bedingung: **nichts Bestehendes löschen oder schließen**. Für Experimente eine eigene herdr-Session (`herdr --session herdrapp-test`) bzw. eigene Panes nutzen und danach nur diese aufräumen.

## 7. Offen für den Builder

- **Spike zuerst**: Live-Events über SSH (CLI-Abo vs. Socket-Bridge vs. Polling), genaues Attach-Kommando für Panes ohne Agent, Format der `agent read`-Ausgabe für eine saubere Konversationsdarstellung.
- Genaue Gestaltung der Screens, Icons, Farben.
- WhisperKit-Modellgröße als Standard.
- Sprache und Form des Begleitdienstes.
- Reihenfolge der Umsetzung (sinnvoll: SSH + Keys → Übersicht → Agent-Detail → Terminal → Benachrichtigungen → Sprache → VPN-Hinweise).
