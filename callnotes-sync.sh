#!/bin/bash
# callnotes-sync.sh — spiegelt Notizen + Audio-Archiv in den Kopie-Ordner
# (z.B. externe Festplatte). rsync holt automatisch alles nach, was beim
# letzten Mal gefehlt hat (Platte nicht angeschlossen o.ae.).
# Achtung /bin/bash 3.2: im $()-Heredoc NUR double quotes verwenden (Parser-Bug).
set -uo pipefail
CFG="${CALLNOTES_CONFIG:-$HOME/.config/callnotes/config.json}"
[ -f "$CFG" ] || { echo "Config fehlt: $CFG"; exit 1; }

eval "$(python3 - "$CFG" <<'PY'
import json, os, shlex, sys
d = json.load(open(sys.argv[1]))
def p(k, key, dflt=""): print(f"{k}={shlex.quote(os.path.expanduser(d.get(key) or dflt))}")
p("NOTES_DIR", "notesDir", "~/CallNotes/notes")
p("AUDIO_DIR", "audioDir", "~/CallNotes/audio")
p("MIRROR_DIR", "mirrorDir")
PY
)"

[ -n "$MIRROR_DIR" ] || { echo "Kein Kopie-Ordner konfiguriert (mirrorDir) — nichts zu tun."; exit 0; }

# Nicht gemountete externe Platte erkennen: das uebergeordnete Volume muss existieren.
PARENT="$(dirname "$MIRROR_DIR")"
if [ ! -d "$PARENT" ] && [ ! -d "$MIRROR_DIR" ]; then
  echo "Kopie-Ziel nicht erreichbar (Platte nicht angeschlossen?): $MIRROR_DIR — uebersprungen."
  exit 0
fi

mkdir -p "$MIRROR_DIR/notizen" "$MIRROR_DIR/audio" || { echo "Kopie-Ziel nicht beschreibbar: $MIRROR_DIR"; exit 1; }
OK=1
[ -d "$NOTES_DIR" ] && { rsync -a --exclude ".*" "$NOTES_DIR/" "$MIRROR_DIR/notizen/" || OK=0; }
[ -d "$AUDIO_DIR" ] && { rsync -a --exclude ".*" "$AUDIO_DIR/" "$MIRROR_DIR/audio/" || OK=0; }
if [ $OK -eq 1 ]; then
  echo "Spiegel aktuell: $MIRROR_DIR (notizen/ + audio/)"
else
  echo "Spiegel unvollstaendig (Zugriff verweigert? Freigabe 'Wechseldatentraeger' pruefen): $MIRROR_DIR"
  exit 1
fi
