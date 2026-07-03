# CallNotes (macOS) — guide for AI assistants

You are probably helping someone install, test or debug this repo. Read this
first; it encodes the hard-won platform knowledge.

## What this is

Driverless two-track call recorder + note pipeline for macOS 14.2+.
`calltap` (Swift) records the caller's app audio via Core Audio **process
taps** and the microphone as two separate tracks; `process-call.sh` transcribes
(whisper.cpp / Parakeet via sherpa-onnx / Groq), separates speakers, summarizes
with the user's AI and writes a Markdown note. `CallNotes.app` is the menu bar
UI. Windows sibling: https://github.com/michaelczesun/callnotes-windows.

## Everything runs LOCALLY — required on the machine

`./install.sh` sets all of this up (add `--with-parakeet` for the fast local
transcriber, ~700 MB):

- Xcode Command Line Tools (`swiftc`), Homebrew `whisper-cpp` + `ffmpeg`
- A ggml Whisper model (path in config `whisperModel`; install.sh prints the
  download command; `large-v3-turbo-q5_0` needs a beefy machine — `small` is
  fine on 8 GB)
- Python 3 venv with `sherpa-onnx numpy` (speaker separation, Parakeet)
- **No cloud is required.** Groq is an optional transcriber; the summary uses
  whatever the user configures (Claude CLI, any OpenAI-compatible URL, Ollama,
  or `off`).

## Platform facts and traps (learned the hard way)

- **TCC fails SILENTLY:** without the "System Audio Recording" permission the
  process tap records pure silence (-91 dB), no error. Mic + system audio
  permissions attach to `calltap.app`'s bundle identity — that's why calltap
  MUST run as an app bundle via launchd, never as a bare CLI binary from a
  shell (bare binaries have no promptable TCC identity and empty bundle IDs).
- The tap's aggregate device MUST include the default output device as clock
  sub-device, or it delivers silence.
- Don't create/destroy aggregate+IOProc rapidly — coreaudiod can deadlock;
  the code sleeps 150 ms between stop and destroy on purpose.
- `calltap.app` lives in `~/Applications` (TCC grants stick to it);
  `CallNotes.app` (menu bar) lives in `/Applications`. Don't "clean up" this
  split — moving calltap invalidates the user's recording permissions.
- Whisper repetition loops are handled in `merge-transcript.py`
  (`collapse_repeats`); Parakeet (NeMo BPE) marks word starts with a SPACE
  prefix, not `▁`.
- Groq/HF endpoints reject Python-urllib's default User-Agent — always send a
  custom UA.
- bash 3.2 (macOS default): single quotes inside `$(python3 - <<'PY' ...)`
  heredocs break the parser — use double quotes only inside those.
- launchd: `bootout` needs ~2 s before `bootstrap` or you get
  "Bootstrap failed: 5" / "Input/output error" — install.sh already retries.

## Build & test

```
bash build.sh            # builds calltap.app (~/Applications) + CallNotes.app (/Applications)
./install.sh             # full setup incl. launchd daemon + menu bar app
calltap procs --watch    # live audio-process view (MIC = mic in use)
bash process-call.sh <rec-dir>   # re-run pipeline on a recording/failed dir
```

Config: `~/.config/callnotes/config.json` (chmod 600, never commit). File
formats (`state/current-call.json`, `levels.json`, `state/pending/*.json`) are
identical to the Windows sibling by contract.

## House rules

- License is PolyForm Noncommercial — no commercial use/selling.
- Never commit user data, API keys or recordings; keep the repo free of
  personal paths and secrets (screenshots/assets are generated with neutralized
  demo data via `CALLNOTES_SHOT`).
- Keep file formats in lockstep with callnotes-windows — one product, two OSes.
