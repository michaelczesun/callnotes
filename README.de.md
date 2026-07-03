<p align="center">
  <img src="assets/banner.de.png" alt="CallNotes — aus Anrufen werden Notizen. Automatisch." width="100%">
</p>

<p align="center">
  <a href="README.md">🇬🇧 English</a>&nbsp;&nbsp;·&nbsp;&nbsp;<b>🇩🇪 Deutsch</b>
</p>

<h1 align="center">CallNotes</h1>

<p align="center">
  Du telefonierst am Mac — CallNotes nimmt <b>beide Seiten als getrennte Spuren</b> auf,
  transkribiert lokal mit Whisper, trennt die Sprecher und legt dir eine fertige,
  KI-zusammengefasste Notiz ab, wo du willst. Vollautomatisch, aus der Menüleiste.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-14.2%2B-black?logo=apple" alt="macOS 14.2+">
  <img src="https://img.shields.io/badge/Transkription-on--device-6D5CFF" alt="on-device">
  <img src="https://img.shields.io/badge/Lizenz-PolyForm%20Noncommercial-BF5AF2" alt="Lizenz">
</p>

---

## Warum es das gibt

Jedes Call-Recording-Tool braucht entweder einen virtuellen Audio-Treiber
(BlackHole/Loopback), einen sichtbaren Meeting-Bot oder ein Cloud-Abo. CallNotes nicht:

- **Core-Audio Process Taps** (macOS 14.2+) greifen das Systemaudio **nur der
  Call-App** ab — die Gegenseite landet auf ihrer eigenen Spur, Hintergrundmusik nicht.
- Dein Mikrofon läuft parallel — **zwei getrennte Spuren bedeuten perfekte
  Sprecher-Zuordnung bei 1:1-Anrufen**, ganz ohne KI-Raterei.
- Bei Konferenzen trennt eine lokale **Sprecher-Diarisierung** (sherpa-onnx) den
  Mix der Gegenseite in „Sprecher 1..N" — Namen ordnest du per Hör-Schnipsel und
  Dropdown zu.
- Transkription läuft **on-device** (whisper.cpp, Metal) — oder über die Groq-API,
  wenn dir Tempo wichtiger ist als Offline. Ein Schalter.
- **KI deiner Wahl** für die Zusammenfassung: Claude Code (Standard), jede
  OpenAI-kompatible API (OpenAI, Groq, OpenRouter) oder komplett lokal via **Ollama** —
  oder ganz ohne.

## Was du nach dem Auflegen bekommst

Eine fertige Markdown-Notiz, etwa eine Minute später:

- **Kurzfassung, besprochene Punkte, Zusagen & To-dos, offene Fragen** (Claude,
  optional — Sektionen frei wählbar, inklusive **Follow-up-Mail-Entwurf**)
- **Dialog-Transkript mit Sprechern** („Ich: … / Gesprächspartner: …") mit Zeitstempeln
- **Stereo-Audio-Archiv** (links = du, rechts = Gegenseite)
- Abgelegt im **Notizen-Ordner** (Obsidian-tauglich), optional zusätzlich in
  **Apple Notes, Nextcloud, Notion**, gespiegelt auf eine **externe Festplatte**,
  plus **ntfy-Push** aufs Handy

## So funktioniert es

<p align="center">
  <img src="assets/how-it-works.de.png" alt="So funktioniert CallNotes — vom erkannten Anruf zur Markdown-Notiz" width="640">
</p>

## Die Menüleisten-App

Alles sitzt in der Menüleiste (Telefon-Symbol):

- **Live-Ansicht im Anruf** — zwei animierte Pegel-Spuren (du + Gegenseite),
  Anruf-Timer, und ein Popup zum Eintragen der Teilnehmer-Namen, solange du sie
  noch im Kopf hast
- **Verarbeitungs-Status** nach dem Auflegen (Transkription → Sprecher-Erkennung → KI)
- **Sprecher-Zuordnung** bei Konferenzen: Hör-Schnipsel je erkannter Stimme abspielen,
  Name im Dropdown wählen (die KI schlägt Namen vor, die im Gespräch fielen)
- **Letzte Anrufe**, Speicherorte (inkl. externer Platte), API-Keys, Integrationen
- **Ersteinrichtungs-Assistent**, eingebauter **Hilfebereich** und ein ⓘ neben
  jedem Feld — du musst nie raten, was eine Einstellung tut
- **Deutsch & Englisch** — die App folgt automatisch deiner Systemsprache

<p align="center">
  <img src="assets/screenshots.de.png" alt="CallNotes Menüleisten-App — Live-Pegel, Sprecher-Zuordnung, Einstellungen" width="100%">
</p>

## Installation

```bash
brew install whisper-cpp ffmpeg
git clone https://github.com/michaelczesun/callnotes && cd callnotes
./install.sh
```

`install.sh` baut zwei Apps nach `~/Applications`, richtet die Diarisierungs-Modelle
(~35 MB) ein, legt `~/.config/callnotes/config.json` an und startet die launchd-Agents.

Whisper-Modell einmalig laden (~550 MB):

```bash
mkdir -p ~/models && curl -L -o ~/models/ggml-large-v3-turbo-q5_0.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin
```

**Beim ersten Start** fragt macOS nach zwei Freigaben für „calltap" (Mikrofon +
Systemaudio-Aufnahme) — beide erlauben. Falls kein Dialog erscheint:
Systemeinstellungen → Datenschutz & Sicherheit → *Mikrofon* bzw.
*Bildschirm- & Systemaudioaufnahme* → calltap.

Danach: **Testanruf machen** (länger als 20 Sekunden). Fortschritt bei Bedarf in
`~/CallNotes/log/process.log`.

## Unterstützte Call-Apps

FaceTime, iPhone-Anrufe via Continuity, WhatsApp, Zoom, Teams, Signal, Telegram,
Discord — alles, was das Mikrofon nutzt. Die Allowlist steht in der Config;
die Bundle-ID jeder App findest du mit `calltap procs --watch` während eines
Anrufs (unbekannte Apps landen automatisch im Log).

## Konfiguration

Alles liegt in `~/.config/callnotes/config.json` — oder du nutzt einfach die
Einstellungen in der Menüleiste. Die wichtigsten Felder:

| Feld | Bedeutung |
|---|---|
| `apps` | Bundle-IDs, deren Mikrofon-Nutzung eine Aufnahme startet |
| `tapScope` | `app` = nur die Call-App-Familie aufnehmen (Default), `global` = gesamtes Systemaudio |
| `transcriber` / `groqApiKey` | `local` (whisper.cpp) oder `groq` (Cloud, schneller) |
| `summarizer` (+ `summarizerUrl/Model/ApiKey`) | `claude` (Claude Code CLI), `openai` (jede OpenAI-kompatible API inkl. Ollama/Groq/OpenRouter) oder `off` |
| `noteSections` | welche Abschnitte die KI schreibt: Kurzfassung, Besprochen, To-dos, Follow-up-Mail |
| `destinations` | zusätzliche Ablage: Apple Notes, Nextcloud (WebDAV), Notion |
| `notesDir` / `audioDir` / `mirrorDir` | wohin Notizen, Audio und der Externe-Platte-Spiegel gehen |
| `diarize` / `diarizeThreshold` | Mehrsprecher-Erkennung an/aus, Cluster-Schwelle (höher = weniger Sprecher) |
| `speakerSelf` / `context` | dein Name im Transkript + ein Satz Kontext für bessere Zusammenfassungen |

## CLI

```bash
calltap procs [--watch]     # welche App nutzt gerade das Mikrofon?
calltap record --out DIR    # manuelle Zwei-Spuren-Aufnahme (Ctrl-C stoppt)
bash process-call.sh DIR    # eine Aufnahme (nach)verarbeiten
bash callnotes-sync.sh      # Notizen + Audio auf die externe Platte spiegeln
```

## Wenn etwas hakt

- **System-Spur ist stumm (-91 dB):** Die Tap-API liefert bei fehlender
  Systemaudio-Freigabe *Stille statt eines Fehlers*. Prüfen: Systemeinstellungen →
  Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme → calltap.
- **Nie ein Freigabe-Dialog erschienen:** calltap muss als App-Bundle über launchd
  laufen (ein nacktes CLI-Binary hat keine Prompt-Identität). `./install.sh` macht
  das richtig.
- **Aufnahme startet nicht:** `tail -f ~/CallNotes/log/callwatch.log` — steht dort
  „Mikro aktiv bei nicht gelisteter App", die genannte Bundle-ID in `apps` ergänzen.
- **Gegenseite fehlt bei Electron-Apps** (WhatsApp/Discord/Teams): Der Ton läuft
  oft in einem Helper-Prozess; `tapScope: "app"` erfasst die ganze App-Familie.
  Wenn trotzdem etwas fehlt: `"global"` setzen.
- **Ausgabegerät mitten im Anruf gewechselt** (AirPods verbunden): Die laufende
  Aufnahme kann still werden — vor dem Anruf wechseln.
- Fehlgeschlagene Verarbeitungen liegen mit Roh-Audio in `~/CallNotes/failed/` und
  lassen sich mit `bash process-call.sh <ordner>` erneut anstoßen.

## Datenschutz & Recht

Standardmäßig läuft alles lokal (Whisper on-device); nur die Zusammenfassung geht —
falls aktiviert — an die Claude-API, Transkription an Groq nur per Opt-in.
**Informiere deine Gesprächspartner über die Aufnahme.** Die Rechtslage ist je Land
unterschiedlich (in Österreich ist z. B. die *Weitergabe* heimlicher Aufnahmen
strafbar, § 120 StGB; in Deutschland schon die heimliche *Aufnahme*, § 201 StGB).
Für die rechtmäßige Nutzung bist du selbst verantwortlich.

## Lizenz

[PolyForm Noncommercial 1.0.0](LICENSE) — frei für private und nichtkommerzielle
Nutzung. **Verkauf und kommerzielle Nutzung sind nicht erlaubt.**

---

<p align="center"><sub><a href="README.md">🇬🇧 This page in English</a></sub></p>
