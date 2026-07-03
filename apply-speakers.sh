#!/bin/bash
# apply-speakers.sh — uebernimmt die Sprecher-Zuordnung in die fertige Notiz.
# Nutzung: apply-speakers.sh <pending.json> "Sprecher 1=Stefan;Sprecher 2=Anna"
# Leere Zuordnung oder "?" laesst das Label unveraendert. Danach: pending +
# Schnipsel aufraeumen und Spiegel-Sync anstossen.
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

PENDING="${1:?Nutzung: apply-speakers.sh <pending.json> \"Sprecher 1=Name;...\"}"
MAPPING="${2:-}"
[ -f "$PENDING" ] || { echo "pending.json fehlt: $PENDING"; exit 1; }

python3 - "$PENDING" "$MAPPING" <<'PY'
import json, os, re, shutil, sys
pending_p, mapping = sys.argv[1:3]
d = json.load(open(pending_p, encoding="utf-8"))
note = d.get("note", "")
if not os.path.exists(note):
    sys.exit(f"Notiz fehlt: {note}")

import re as _re
# robust gegen Semikolons in Namen: Segmente laufen bis zum naechsten "Sprecher/Speaker N="
pairs = []
for m in _re.finditer(r"((?:Sprecher|Speaker) \d+)\s*=\s*([^;]*(?:;(?!\s*(?:Sprecher|Speaker) \d+\s*=)[^;]*)*)", mapping or ""):
    k, v = m.group(1).strip(), m.group(2).strip().rstrip(";").strip()
    if k and v and v != "?" and v != k:
        pairs.append((k, v))

if pairs:
    text = open(note, encoding="utf-8").read()
    # laengere Labels zuerst ersetzen (Sprecher 10 vor Sprecher 1)
    for k, v in sorted(pairs, key=lambda kv: -len(kv[0])):
        text = text.replace(k, v)
    open(note, "w", encoding="utf-8").write(text)
    print(f"Notiz aktualisiert: {os.path.basename(note)} ({'; '.join(f'{k} -> {v}' for k, v in pairs)})")
else:
    print("Keine Zuordnung uebernommen (Labels bleiben).")

# Schnipsel + Auftrag aufraeumen
for s in d.get("speakers", []):
    clip = s.get("clip", "")
    if clip and os.path.exists(clip):
        shutil.rmtree(os.path.dirname(clip), ignore_errors=True)
        break
os.remove(pending_p)
PY
STATUS=$?
[ $STATUS -eq 0 ] || exit $STATUS

bash "$SCRIPT_DIR/callnotes-sync.sh" || true
