#!/bin/bash
# install.sh — CallNotes / calltap komplett einrichten:
#   1. Abhaengigkeiten pruefen  2. Apps bauen  3. Config anlegen
#   4. launchd-Daemon installieren + starten  5. TCC-Freigaben ausloesen
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(pwd)"
CFG_DIR="$HOME/.config/callnotes"
CFG="$CFG_DIR/config.json"
PLIST="$HOME/Library/LaunchAgents/at.dasgeht.callwatch.plist"
UID_NUM=$(id -u)

echo "== CallNotes install =="

# 1) Abhaengigkeiten
missing=()
command -v whisper-cli >/dev/null || missing+=("whisper-cpp (brew install whisper-cpp)")
command -v ffmpeg >/dev/null || missing+=("ffmpeg (brew install ffmpeg)")
command -v python3 >/dev/null || missing+=("python3")
command -v swiftc >/dev/null || missing+=("Xcode Command Line Tools (xcode-select --install)")
if [ ${#missing[@]} -gt 0 ]; then
  printf 'FEHLT:\n'; printf '  - %s\n' "${missing[@]}"; exit 1
fi

# 2) Bauen
bash build.sh

# 3) Config anlegen (bestehende bleibt unangetastet), postScript auf dieses Repo zeigen
mkdir -p "$CFG_DIR" "$HOME/CallNotes/rec" "$HOME/CallNotes/log" "$HOME/CallNotes/audio" "$HOME/CallNotes/failed"
if [ ! -f "$CFG" ]; then
  cp config.example.json "$CFG"
  echo "Config angelegt: $CFG (Speicherorte aendern: CallNotes.app oder direkt editieren)"
fi
python3 - "$CFG" "$REPO/process-call.sh" <<'PY'
import json, sys
cfg, post = sys.argv[1:3]
d = json.load(open(cfg))
d["postScript"] = post
d.pop("_hinweis", None)
json.dump(d, open(cfg, "w"), indent=2, ensure_ascii=False, sort_keys=True)
PY

# Whisper-Modell pruefen (nur Hinweis, kein Abbruch)
MODEL=$(python3 -c "import json,os;print(os.path.expanduser(json.load(open('$CFG')).get('whisperModel','')))")
if [ ! -f "$MODEL" ]; then
  echo "HINWEIS: Whisper-Modell fehlt noch: $MODEL"
  echo "  Download (~550 MB): mkdir -p \"$(dirname "$MODEL")\" && curl -L -o \"$MODEL\" \\"
  echo "    https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
fi

# 4) Sprecher-Diarisierung (mehrere Teilnehmer erkennen): venv + Modelle
VENV="$HOME/.local/share/callnotes/venv"
DIAMODELS="$HOME/.local/share/callnotes/models"
if [ ! -x "$VENV/bin/python3" ]; then
  echo "Richte Diarisierungs-Umgebung ein (sherpa-onnx) …"
  /usr/bin/python3 -m venv "$VENV" && "$VENV/bin/pip" install -q --upgrade pip && "$VENV/bin/pip" install -q sherpa-onnx numpy \
    || echo "WARNUNG: venv/sherpa-onnx fehlgeschlagen — Diarisierung deaktiviert (1:1-Anrufe gehen trotzdem)."
fi
mkdir -p "$DIAMODELS"
if [ ! -f "$DIAMODELS/sherpa-onnx-pyannote-segmentation-3-0/model.onnx" ]; then
  echo "Lade Segmentierungs-Modell (~9 MB) …"
  curl -sL --retry 4 -o "$DIAMODELS/seg.tar.bz2" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2" \
    && tar xjf "$DIAMODELS/seg.tar.bz2" -C "$DIAMODELS" && rm -f "$DIAMODELS/seg.tar.bz2" || echo "WARNUNG: Download fehlgeschlagen."
fi
if [ ! -f "$DIAMODELS/3dspeaker_speech_eres2net_sv_en_voxceleb_16k.onnx" ]; then
  echo "Lade Sprecher-Embedding-Modell (~26 MB) …"
  for i in 1 2 3 4 5; do
    curl -sL -C - -f -o "$DIAMODELS/3dspeaker_speech_eres2net_sv_en_voxceleb_16k.onnx" \
      "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_eres2net_sv_en_voxceleb_16k.onnx" && break
    sleep 2
  done
  [ -f "$DIAMODELS/3dspeaker_speech_eres2net_sv_en_voxceleb_16k.onnx" ] || echo "WARNUNG: Embedding-Download fehlgeschlagen."
fi

# 5) launchd: Recorder-Daemon + Menueleisten-App
# bootout braucht einen Moment; bootstrap direkt danach liefert sonst "Input/output error"
sed "s|__HOME__|$HOME|g" launchd.plist.template > "$PLIST"
launchctl bootout "gui/$UID_NUM/at.dasgeht.callwatch" 2>/dev/null || true
sleep 2
launchctl bootstrap "gui/$UID_NUM" "$PLIST" 2>/dev/null \
  || { sleep 3; launchctl bootstrap "gui/$UID_NUM" "$PLIST" || true; }

UI_PLIST="$HOME/Library/LaunchAgents/at.dasgeht.callnotes-ui.plist"
sed "s|__HOME__|$HOME|g" launchd-ui.plist.template > "$UI_PLIST"
launchctl bootout "gui/$UID_NUM/at.dasgeht.callnotes-ui" 2>/dev/null || true
pkill -f "CallNotes.app/Contents/MacOS/CallNotes" 2>/dev/null || true
sleep 2
launchctl bootstrap "gui/$UID_NUM" "$UI_PLIST" 2>/dev/null \
  || { sleep 3; launchctl bootstrap "gui/$UID_NUM" "$UI_PLIST" || true; }

sleep 2
if launchctl print "gui/$UID_NUM/at.dasgeht.callwatch" 2>/dev/null | grep -q 'state = running'; then
  echo "Daemon laeuft (at.dasgeht.callwatch). Log: ~/CallNotes/log/callwatch.log"
else
  echo "WARNUNG: Daemon nicht im Zustand 'running' — Log pruefen: ~/CallNotes/log/callwatch.log"
fi
echo "Menueleisten-App gestartet (Telefon-Symbol oben rechts)."

echo
echo "WICHTIG: Beim ersten Start fragt macOS nach Freigaben fuer 'calltap'"
echo "(Mikrofon + Systemaudio-Aufnahme) — beide erlauben. Falls kein Dialog kam:"
echo "Systemeinstellungen > Datenschutz & Sicherheit > Mikrofon bzw."
echo "'Bildschirm- & Systemaudioaufnahme' > calltap aktivieren."
echo
echo "Einstellungen (Speicherorte, externe Platte): ~/Applications/CallNotes.app"
echo "Fertig."
