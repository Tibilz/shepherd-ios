<p align="center"><img src="App/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="120" alt="herdr-App-Icon"></p>

<h1 align="center">herdr für iPhone</h1>

<p align="center">Deine <a href="https://herdr.dev">herdr</a>-Agents unterwegs im Blick: per SSH verbinden, Chats lesen, antworten, freigeben – auch per Sprache.</p>

<p align="center"><em>An unofficial iPhone companion for the herdr agent multiplexer: monitor and steer your Claude Code / Codex agents on remote servers over SSH. UI language: German.</em></p>

---

## Was die App kann

- **Server-Liste** – mehrere VPS/SSH-Verbindungen, jede mit eigenem Key. Keys liegen nur im Schlüsselbund des iPhones, geschützt mit Face ID.
- **Workspaces & Agents wie am Desktop** – Live-Status (arbeitet / wartet auf dich / fertig), „Braucht dich“-Bereich oben.
- **Lesbare Chats** – die Claude-Code-Oberfläche wird zu einem Chat: deine Nachrichten als Blasen, Antworten als Fließtext, Tool-Aufrufe einklappbar, Tabellen seitlich scrollbar. Rohausgabe jederzeit umschaltbar.
- **Antworten & Freigaben** – Prompts senden, Freigabe-Dialoge mit ↑ ↓ Enter, 1/2/3, y/n, Esc beantworten.
- **Chats umbenennen** – freier Text, erscheint auch in herdr am Desktop.
- **Neue Agents starten** – durch die Ordner des Servers navigieren wie in der Dateien-App, dann „Claude Code“ oder „Codex“ tippen.
- **Echtes Terminal** – volle Terminal-Emulation (SwiftTerm) mit Sondertasten-Leiste.
- **Sprachsteuerung** – „Gehe zu Agent 2“, „Zeige mir die Ordner“, „Fasse zusammen, was der Agent gemacht hat“. Antwort als Text oder vorgelesen.
- **Benachrichtigungen** – wenn ein Agent wartet oder fertig ist, global und pro Agent schaltbar, über [ntfy](https://ntfy.sh).
- **Kein bezahltes Apple-Konto nötig** – Installation mit einer kostenlosen Apple-ID.

## Voraussetzungen

| | |
|---|---|
| **Mac** | Xcode 27, `brew install xcodegen` |
| **iPhone** | iOS 26 oder neuer |
| **Apple-ID** | eine kostenlose reicht |
| **Server** | herdr ≥ 0.9.5 (Protokoll 22), `nc` (OpenBSD-netcat, auf Ubuntu Standard), `base64`, `bash` |
| **SSH-Key** | **Ed25519**, öffentlicher Teil in `~/.ssh/authorized_keys` auf dem Server |
| optional | `python3` ≥ 3.8 + `curl` für Benachrichtigungen, Claude Code (`claude`) für Sprachdeutung und Zusammenfassungen |

> **RSA-Keys funktionieren nicht:** Die verwendete SSH-Bibliothek signiert RSA nur mit SHA-1 (`ssh-rsa`), was OpenSSH ab 8.8 ablehnt. Einen passenden Key erzeugst du mit
> `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_herdr` und hängst `~/.ssh/id_ed25519_herdr.pub` auf dem Server an `~/.ssh/authorized_keys` an.

## Installation

```sh
git clone https://github.com/Tibilz/herdr-ios.git
cd herdr-ios
./scripts/generate.sh        # erzeugt HerdrApp.xcodeproj
open HerdrApp.xcodeproj
```

Beim ersten Öffnen fragt Xcode nach dem Build-Plugin von SwiftTerm → **Trust & Enable**.

### Aufs iPhone (kostenlose Apple-ID)

1. Xcode → Settings → Accounts → Apple-ID hinzufügen.
2. Target **HerdrApp** → Signing & Capabilities → Team: *dein Name (Personal Team)*. Die Bundle-ID `de.kozarzewski.herdrapp` auf etwas Eigenes ändern (z. B. `de.deinname.herdrapp`), am besten direkt in `project.yml` und danach `./scripts/generate.sh`.
3. iPhone per Kabel verbinden, auf dem iPhone **Einstellungen → Datenschutz & Sicherheit → Entwicklermodus** aktivieren.
4. In Xcode das iPhone als Ziel wählen → **Run** (⌘R).
5. Beim ersten Start: **Einstellungen → Allgemein → VPN & Geräteverwaltung →** dein Entwicklerprofil → *Vertrauen*.

**Nach 7 Tagen** läuft die Signatur einer kostenlosen Apple-ID ab. Deine Daten bleiben erhalten – einfach erneut aus Xcode starten, oder [SideStore](https://sidestore.io) nutzen, das die Signatur auf dem iPhone selbst erneuert.

## Einrichtung

### 1. SSH-Key hinzufügen

Schlüssel-Symbol → **+**:

- **Aus dem Passwort-Manager:** ins Key-Feld tippen, lange drücken → *Automatisch ausfüllen* → Passwort-Manager wählen → SSH-Key auswählen. Alternativ den privaten Key im Passwort-Manager kopieren und **Aus Zwischenablage einfügen** tippen (danach *Zwischenablage leeren*).
- **Aus Datei** oder von Hand eintippen.

Der Key wird wie ein Passwort verdeckt angezeigt (Auge zum Einblenden). Er bleibt nur auf diesem iPhone (nicht in iCloud). Face ID fragt einmal beim Öffnen der App und erneut nach mehr als 5 Minuten im Hintergrund.

### 2. Server anlegen

Serverliste → **+** → Name, Host, Port, Benutzer, Key. Beim ersten Verbinden zeigt die App den Fingerabdruck des Servers – vergleiche ihn auf dem Server mit

```sh
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Ändert er sich später, verweigert die App die Verbindung (zurücksetzen in den Server-Einstellungen).

**VPN:** Liegt dein Server hinter WireGuard, Cisco AnyConnect oder OpenVPN (Tunnelblick → auf dem iPhone *OpenVPN Connect*), verbinde zuerst die jeweilige VPN-App; herdr nutzt dann einfach die interne Adresse.

### 3. Benachrichtigungen (optional)

Push-Nachrichten laufen über [ntfy](https://ntfy.sh), weil eigene Push-Nachrichten ein bezahltes Apple-Konto bräuchten.

1. Die kostenlose App **ntfy** auf dem iPhone installieren.
2. In herdr: Server öffnen → **⋯ → Benachrichtigungen → Einrichten**. Die App zeigt vorher, was auf dem Server passiert.
3. In ntfy den angezeigten Kanal abonnieren (oder QR-Code scannen) → **Testnachricht senden**.

Ein Tipp auf eine Benachrichtigung öffnet direkt den Agent. Schalter gibt es global, pro Ereignis und pro Agent (Glocke in der Agent-Ansicht).

Auf dem Server entsteht nur `~/.config/herdr-notify/` plus – je nach Server – ein systemd-User-Dienst, zwei crontab-Zeilen oder ein sich selbst überwachender Hintergrundprozess. Kein sudo. **Entfernen** in der App räumt alles wieder ab.

> **Datenschutz:** ntfy.sh ist öffentlich; der Kanalname ist ein zufälliger geheimer Code. Inhalt: Agent-Name, Server-Name, Status. Ein eigener ntfy-Server lässt sich in `config.json` (`ntfyServer`, `ntfyToken`) eintragen.

## Sprachsteuerung

Mikrofon **gedrückt halten und sprechen** (oder kurz tippen zum Starten/Beenden) – unten in der Server-Übersicht und links im Eingabefeld eines Agents.

| Du sagst … | Was passiert |
|---|---|
| „Gehe zu Agent 2“, „öffne den Reviewer“, „zurück“, „Terminal“ | sofort, ohne Netz |
| „Ja“, „freigeben“, „nein“, „Option 2“ (wenn der Agent wartet) | die passende Taste wird gesendet |
| im Agent: „Schreib noch Tests für den Login“ | geht als Nachricht an den Agent – 3 s sichtbar, abbrechbar |
| „Zeige mir die Ordner“, „Befehl: wie viel Platz ist frei“ | Claude schlägt einen Befehl vor, ausgeführt erst nach Tippen; gefährliche Befehle brauchen ein zweites Bestätigen |
| „Fasse zusammen, was der Agent gemacht hat“, „fasse die README zusammen“ | Antwort als Text oder vorgelesen |

Die Spracherkennung läuft auf dem iPhone (Apple SpeechAnalyzer). Deutung und Zusammenfassungen übernimmt **Claude Code auf deinem Server** über dein eigenes Claude-Abo (`claude -p`) – die App braucht keinen API-Key.

## Wie es funktioniert

```
iPhone ──SSH──▶ Server ──Unix-Socket──▶ herdr
                    └── claude -p (Sprache, Zusammenfassungen)
                    └── herdr-notify ──▶ ntfy.sh ──▶ ntfy-App
```

Die App spricht das JSON-Socket-API von herdr direkt über SSH an (`nc -U`), abonniert Live-Ereignisse für den Status und liest die Agent-Ausgabe mit `agent.read`. Es wird nichts dauerhaft auf dem Server installiert, außer du richtest Benachrichtigungen ein.

| Ordner | Inhalt |
|---|---|
| `App/` | SwiftUI-App (iOS 26) |
| `Packages/HerdrKit` | Protokoll, Client, Live-Session, Chat-Parser, Sprachlogik, Notify-Installer – ohne Abhängigkeiten |
| `Packages/HerdrSSH` | SSH-Transport (Citadel), Key-Import, Integrationstests |
| `docs/superpowers/` | Design und Umsetzungspläne |

## Entwicklung

```sh
cd Packages/HerdrKit && swift test                                   # Kernlogik
cd Packages/HerdrSSH && swift test                                   # Key-Import
python3 -m unittest discover -s Packages/HerdrKit/Tests/notify       # herdr-notify
xcodebuild -scheme HerdrApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -skipPackagePluginValidation build
```

Integrationstests gegen einen echten Server nutzen nur eine eigene herdr-Session `herdrapp-test`:

```sh
# auf dem Server
nohup herdr --session herdrapp-test server >/dev/null 2>&1 &
herdr --session herdrapp-test workspace create --label apptest
# lokal
cd Packages/HerdrSSH
HERDR_IT_HOST=<ip> HERDR_IT_USER=<user> HERDR_IT_KEY=~/.ssh/id_ed25519 swift test --filter IntegrationTests
```

Falls Xcode große Abhängigkeiten (`swift-nio`, `swift-crypto`, …) wegen einer langsamen Verbindung nicht laden kann, lassen sich lokale Mirrors hinterlegen (`swift package config set-mirror …` in `Packages/HerdrSSH`); `scripts/generate.sh` übernimmt sie ins Xcode-Projekt.

## Hinweise

- Inoffizielles Projekt, nicht mit herdr verbunden. Das App-Icon basiert auf dem herdr-Logo (Apache-2.0, siehe [NOTICE](NOTICE)).
- Getestet mit herdr 0.9.5 und Claude Code 2.1 auf Ubuntu.

## Lizenz

[MIT](LICENSE)
