# Changelog

All notable changes to CallNotes (macOS). Newest first.
Format follows [Keep a Changelog](https://keepachangelog.com); full notes per
version are on the [Releases page](https://github.com/michaelczesun/callnotes/releases).

## 1.3.2 — 2026-07-07
### Fixed (from an adversarial code audit)
- **Data loss:** `./uninstall.sh --purge` deleted your notes and audio — the default
  notes folder `~/CallNotes/notes` is a subfolder of the `~/CallNotes` it wiped,
  while the script promised your notes were safe. Now removes only transient data
  (rec/log/failed/state); notes and audio are kept.
- UI/worker could deadlock when a subprocess printed >64 KB (pipe not drained before
  waiting) — e.g. an rsync error flood on a bad mirror volume.
- Speaker labels could corrupt with 10+ speakers when only some were named
  ("Sprecher 1" matched inside "Sprecher 10") — word-boundary matching now.
- `install.sh` could treat a half-downloaded model as complete — it now checks the
  download's exit code and removes partials.
- Recordings were silently never processed if `~/CallNotes/log` was missing.
- Data race on the "always record this app" config write.

## 1.3.1 — 2026-07-07
### Fixed
- `install.sh` now **downloads the Whisper model automatically** — the tool recorded
  fine but processing failed silently without it.
- Failed recordings now show **why** in the panel (e.g. "Whisper model missing").

## 1.3.0 — 2026-07-06
### Added
- **Live mic monitor** — the panel shows which app is currently using your microphone.
- **Browser-call capture** (Google Meet, Teams web) via a one-click "Always record
  this app"; the recorder follows the app's base bundle so the caller track isn't
  silent for browser/Electron apps.

## 1.2.5 — 2026-07-04
### Changed
- Wizard/troubleshooting clarity: the green check is the source of truth (the System
  Settings permission list varies by macOS version); MDM/managed-Mac and `tccutil`
  troubleshooting; step-by-step install section.

## 1.2.4 — 2026-07-04
### Fixed
- Permission request now fires through the launchd daemon so macOS attributes it to
  `calltap` (it now shows up in the permission list); `install.sh` removes a stale
  pre-1.2.x `~/Applications/CallNotes.app`.

## 1.2.3 — 2026-07-04
### Added
- Setup wizard **"Request & check permissions now"** button; Intel vs Apple Silicon FAQ.

## 1.2.2 — 2026-07-04
### Added
- `./uninstall.sh` for a clean removal.
### Fixed
- The double-click window could collapse to just its header.

## 1.2.1 — 2026-07-04
### Fixed (first community-tester feedback)
- Double-clicking the app opens the panel as a window (it's a menu bar app).
- The panel explains itself when idle (recording/popup start on an *active* call).
- Setup wizard is forced to the front; classic Teams added to the example apps.

## 1.2.0 — 2026-07-03
### Added
- **Parakeet TDT v3** as a third transcription engine (local, fastest, 25 EU languages).
- Collapsible FAQ; link to the Windows sibling.

## 1.1.1 — 2026-07-03
### Added
- In-app language picker (System / Deutsch / English).

## 1.1.0 — 2026-07-03
### Added
- Full **German + English** UI, notes and assets; hand-drawn banner and how-it-works
  diagram.

## 1.0.0 — 2026-07-03
### Added
- Initial release: driverless two-track call recording (Core Audio process taps),
  on-device Whisper transcription, local speaker diarization, your-choice-of-AI
  summary, and a menu bar app.
