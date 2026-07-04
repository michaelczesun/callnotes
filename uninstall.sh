#!/bin/bash
# uninstall.sh — CallNotes sauber entfernen.
#   ./uninstall.sh          Programm entfernen (Daemons, Apps, launchd-Plists).
#                           Notizen, Audio, Config und Modelle BLEIBEN.
#   ./uninstall.sh --purge  zusaetzlich Arbeitsdaten, Config, venv und Modelle
#                           loeschen. Deine Notizen im notesDir bleiben IMMER.
set -uo pipefail
UID_NUM=$(id -u)

echo "== CallNotes uninstall =="

# 1) Hintergrund-Dienste stoppen und austragen
for label in at.dasgeht.callwatch at.dasgeht.callnotes-ui; do
  launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null && echo "Dienst gestoppt: $label"
  rm -f "$HOME/Library/LaunchAgents/$label.plist" && echo "launchd-Plist entfernt: $label"
done
pkill -f "calltap.app/Contents/MacOS/calltap" 2>/dev/null
pkill -f "CallNotes.app/Contents/MacOS/CallNotes" 2>/dev/null

# 2) Apps entfernen
for app in "$HOME/Applications/calltap.app" "/Applications/CallNotes.app" "$HOME/Applications/CallNotes.app"; do
  [ -d "$app" ] && rm -rf "$app" && echo "App entfernt: $app"
done

# 3) Optional: Daten und Modelle
if [ "${1:-}" = "--purge" ]; then
  NOTES=$(python3 -c "import json,os;print(os.path.expanduser(json.load(open(os.path.expanduser('~/.config/callnotes/config.json'))).get('notesDir','')))" 2>/dev/null || true)
  rm -rf "$HOME/CallNotes" && echo "Arbeitsordner entfernt: ~/CallNotes (Aufnahmen, Logs)"
  rm -rf "$HOME/.config/callnotes" && echo "Config entfernt: ~/.config/callnotes"
  rm -rf "$HOME/.local/share/callnotes" && echo "venv + Modelle entfernt: ~/.local/share/callnotes"
  [ -n "$NOTES" ] && echo "Deine Notizen bleiben unangetastet: $NOTES"
else
  echo
  echo "Behalten (fuer eine spaetere Neuinstallation):"
  echo "  ~/CallNotes (Aufnahmen, Logs)  ~/.config/callnotes (Config)"
  echo "  ~/.local/share/callnotes (Modelle)  — alles loeschen: ./uninstall.sh --purge"
fi

echo
echo "Uebrig bleiben nur die macOS-Freigabe-Eintraege (Mikrofon/Systemaudio) —"
echo "verschwinden von selbst oder manuell: Systemeinstellungen > Datenschutz & Sicherheit."
echo "Fertig. Schade — Feedback, warum du gehst, gern als GitHub-Issue!"
