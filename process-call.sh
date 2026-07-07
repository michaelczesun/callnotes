#!/bin/bash
# process-call.sh v2.0.0 — verarbeitet eine calltap-Anrufaufnahme vollautomatisch:
#   2 Spuren (mic.caf/system.caf) -> whisper.cpp -> Dialog-Transkript mit Sprechern
#   -> Claude-Zusammenfassung (optional) -> Notiz -> m4a-Archiv -> Spiegel-Kopie -> Push.
# Wird vom calltap-watch-Daemon aufgerufen; manuell: process-call.sh <rec-dir>
# Konfiguration: ~/.config/callnotes/config.json (Override: CALLNOTES_CONFIG)
set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"

REC="${1:?Nutzung: process-call.sh <aufnahme-verzeichnis>}"
REC="${REC%/}"
CFG="${CALLNOTES_CONFIG:-$HOME/.config/callnotes/config.json}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[ -f "$CFG" ] || { echo "FEHLER: Config fehlt: $CFG (install.sh ausfuehren)"; exit 1; }

# --- Config laden -------------------------------------------------------------
eval "$(python3 - "$CFG" <<'PY'
import json, os, shlex, sys
d = json.load(open(sys.argv[1]))
def p(k, v): print(f"{k}={shlex.quote(v)}")
def path(key, dflt=""): return os.path.expanduser(d.get(key) or dflt)
p("BASE", path("outDir", "~/CallNotes"))
p("NOTES_DIR", path("notesDir", "~/CallNotes/notes"))
p("AUDIO_DIR", path("audioDir", "~/CallNotes/audio"))
p("MIRROR_DIR", path("mirrorDir"))
p("MODEL_CFG", path("whisperModel"))
p("CLAUDE_CFG", path("claudeBin"))
p("NTFY_URL", d.get("ntfyUrl") or "")
p("LANG_CFG", d.get("language") or "de")
p("SELF_LABEL", d.get("speakerSelf") or "")
p("PEER_LABEL", d.get("speakerPeer") or "")
p("CONTEXT", d.get("context") or "")
p("MOC_ON", "1" if d.get("notesMoc", True) else "0")
p("DIARIZE", "1" if d.get("diarize", True) else "0")
p("DIA_THRESHOLD", str(d.get("diarizeThreshold") or 0.6))
p("VENV_PY", path("venvPython", "~/.local/share/callnotes/venv/bin/python3"))
p("TRANSCRIBER", d.get("transcriber") or "local")
p("GROQ_KEY_CFG", d.get("groqApiKey") or "")
p("SUMMARIZER", d.get("summarizer") or "claude")
p("SUM_URL", (d.get("summarizerUrl") or "").rstrip("/"))
p("SUM_MODEL", d.get("summarizerModel") or "")
p("SUM_KEY", d.get("summarizerApiKey") or "")
p("SECTIONS", ",".join(d.get("noteSections") or ["kurzfassung", "besprochen", "todos"]))
dest = d.get("destinations") or {}
p("DEST_NOTES", "1" if dest.get("appleNotes") else "0")
p("DEST_NC", "1" if dest.get("nextcloud") else "0")
p("DEST_NOTION", "1" if dest.get("notion") else "0")
p("NC_URL_CFG", d.get("nextcloudUrl") or "")
p("NC_USER_CFG", d.get("nextcloudUser") or "")
p("NC_PASS_CFG", d.get("nextcloudAppPass") or "")
p("NOTION_TOKEN", d.get("notionToken") or "")
p("NOTION_PARENT", d.get("notionParent") or "")
PY
)"

MODEL="${WHISPER_MODEL:-$MODEL_CFG}"
CLAUDE_BIN="${CLAUDE_BIN:-${CLAUDE_CFG:-$HOME/.local/bin/claude}}"
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || CLAUDE_BIN="$(command -v claude || true)"
MERGE="$SCRIPT_DIR/merge-transcript.py"
MOC="$NOTES_DIR/anrufe-moc.md"
SECRETS="$HOME/.config/callnotes/secrets.env"
[ -f "$SECRETS" ] || SECRETS="$HOME/.config/dasgeht/secrets.env"

# Sprach-Weiche: Notiz-Skelett, Sprecher-Labels und Status-Phasen folgen der
# Transkriptions-Sprache (language) — de = Deutsch, alles andere = Englisch.
if [ "$LANG_CFG" = "de" ]; then
  [ -n "$SELF_LABEL" ] || SELF_LABEL="Ich"
  [ -n "$PEER_LABEL" ] || PEER_LABEL="Gesprächspartner"
  SPEAKER_PREFIX="Sprecher"
  T_PH_TRANS="Transkription läuft…"; T_PH_DIA="Sprecher-Erkennung…"; T_PH_AI="KI-Zusammenfassung…"; T_PH_STORE="Archiv & Ablage…"
  T_TRANSCRIPT="Transkript"; T_CALL="Telefonat"
  T_AUDIO_NOTE="Audio-Archiv"; T_LEFT="links"; T_RIGHT="rechts"
else
  [ -n "$SELF_LABEL" ] || SELF_LABEL="Me"
  [ -n "$PEER_LABEL" ] || PEER_LABEL="Caller"
  SPEAKER_PREFIX="Speaker"
  T_PH_TRANS="Transcribing…"; T_PH_DIA="Detecting speakers…"; T_PH_AI="AI summary…"; T_PH_STORE="Archiving & delivery…"
  T_TRANSCRIPT="Transcript"; T_CALL="Call"
  T_AUDIO_NOTE="Audio archive"; T_LEFT="left"; T_RIGHT="right"
fi

# Groq-Key: Config zuerst, sonst Tresor (secrets.env)
GROQ_KEY="$GROQ_KEY_CFG"
if [ -z "$GROQ_KEY" ] && [ -f "$SECRETS" ]; then
  GROQ_KEY=$(grep -m1 -E '^(GROQ_API_KEY|FABLE_GROQ_KEY)=' "$SECRETS" | cut -d= -f2- || true)
fi

say() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
ntfy() { [ -n "$NTFY_URL" ] && curl -s -m 10 -d "$1" -H "Title: ${2:-Anruf-Notiz}" "$NTFY_URL" >/dev/null 2>&1 || true; }

# Verarbeitungs-Status fuer die Menueleisten-App
STATE_DIR="$BASE/state"
phase() {
  mkdir -p "$STATE_DIR"
  printf '{"stamp": "%s", "phase": "%s"}\n' "${STAMP:-}" "$1" > "$STATE_DIR/processing.json" 2>/dev/null || true
}
phase_done() { rm -f "$STATE_DIR/processing.json"; }

fail() {
  say "FEHLER: $1"
  phase_done
  mkdir -p "$BASE/failed"
  # Grund mit der Aufnahme mitwandern lassen, damit die App ihn zeigen kann
  [ -d "$REC" ] && printf '%s\n' "$1" > "$REC/fail-reason.txt" 2>/dev/null
  case "$REC" in "$BASE/failed/"*) : ;; *) [ -d "$REC" ] && mv "$REC" "$BASE/failed/" 2>/dev/null ;; esac
  ntfy "Anruf-Verarbeitung fehlgeschlagen: $1 — Audio liegt in $BASE/failed/$(basename "$REC")" "Anruf-Notiz FEHLER"
  rm -rf "${LOCK:-}" 2>/dev/null
  exit 1
}

[ -d "$REC" ] || { say "FEHLER: Verzeichnis fehlt: $REC"; exit 1; }
if [ "$TRANSCRIBER" = "local" ]; then
  [ -n "$MODEL" ] && [ -f "$MODEL" ] || fail "Whisper-Modell fehlt (config 'whisperModel'): ${MODEL:-nicht gesetzt}"
fi

# Lock: nur eine Verarbeitung gleichzeitig (whisper + claude sind RAM-/CPU-hungrig).
# PID-basiert: lebt der Halter noch, wird beliebig lange gewartet (lange Calls!);
# nur ein toter Halter (Absturz/Kill) wird uebernommen.
LOCK="$BASE/.process.lock"
until mkdir "$LOCK" 2>/dev/null; do
  HOLDER=$(cat "$LOCK/pid" 2>/dev/null || echo "")
  if [ -z "$HOLDER" ] || ! kill -0 "$HOLDER" 2>/dev/null; then
    say "Lock-Halter (${HOLDER:-unbekannt}) lebt nicht mehr — uebernehme"
    rm -rf "$LOCK"
  fi
  sleep 10
done
echo $$ > "$LOCK/pid"
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT

say "Verarbeite $REC"

# --- Meta lesen ---------------------------------------------------------------
META="$REC/meta.json"
APP="unbekannt"; DUR=0
if [ -f "$META" ]; then
  APP=$(python3 -c "import json;print(json.load(open('$META')).get('appName','unbekannt'))" 2>/dev/null || echo unbekannt)
  DUR=$(python3 -c "import json;print(json.load(open('$META')).get('durationSec',0))" 2>/dev/null || echo 0)
fi
# yyyy-MM-dd_HHmmss (neue Aufnahmen) bzw. yyyy-MM-dd_HHmm (alte) — beides matchen
STAMP="$(basename "$REC" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{4,6}' || basename "$REC" | cut -c1-15)"
DATE_PART="${STAMP:0:10}"
TIME_PART="${STAMP:11:4}"
[ ${#DATE_PART} -eq 10 ] || DATE_PART=$(date +%Y-%m-%d)
[ ${#TIME_PART} -eq 4 ] || TIME_PART=$(date +%H%M)
TIME_NICE="${TIME_PART:0:2}:${TIME_PART:2:2}"
DUR_MIN=$(( (DUR + 59) / 60 ))

# --- Spuren -> 16kHz-WAV -> Whisper-JSON ---------------------------------------
transcribe() { # $1=caf $2=outbase(label) $3=wav behalten (optional "keep")
  local caf="$REC/$1" wav="$REC/$2.16k.wav"
  [ -s "$caf" ] || { say "  Spur $1 fehlt/leer — uebersprungen"; return 1; }
  ffmpeg -hide_banner -loglevel error -y -i "$caf" -ar 16000 -ac 1 -c:a pcm_s16le "$wav" || return 1
  # Praktisch stumme Spur nicht transkribieren (Whisper halluziniert sonst)
  local vol
  vol=$(ffmpeg -i "$wav" -af volumedetect -f null - 2>&1 | grep -o 'max_volume: [-0-9.]*' | grep -o '[-0-9.]*' || echo -99)
  if python3 -c "import sys;sys.exit(0 if float('$vol' or -99) < -50 else 1)" 2>/dev/null; then
    say "  Spur $1 ist stumm (max ${vol}dB) — uebersprungen"
    rm -f "$wav"; return 1
  fi
  # Parakeet TDT v3 (lokal via sherpa-onnx, sehr schnell, 25 EU-Sprachen) — Fallback whisper
  if [ "$TRANSCRIBER" = "parakeet" ] && [ -x "$VENV_PY" ]; then
    "$VENV_PY" "$SCRIPT_DIR/transcribe_parakeet.py" "$wav" "$REC/$2.json" 2>>"$REC/parakeet.log" \
      || say "  Parakeet nicht verfuegbar (Modell fehlt? ./install.sh --with-parakeet) — Fallback whisper"
  fi
  # Groq-Cloud-Whisper (optional, schneller bei langen Calls) — Fallback lokal
  if [ "$TRANSCRIBER" = "groq" ] && [ -n "$GROQ_KEY" ]; then
    if curl -s -m 180 -f "https://api.groq.com/openai/v1/audio/transcriptions" \
        -H "Authorization: Bearer $GROQ_KEY" \
        -F "model=whisper-large-v3-turbo" -F "language=$LANG_CFG" -F "temperature=0" \
        -F "response_format=verbose_json" -F "file=@$wav" -o "$REC/$2.groq.json" 2>>"$REC/groq.log"; then
      python3 - "$REC/$2.groq.json" "$REC/$2.json" <<'PY'
import json, sys
src, dst = sys.argv[1:3]
d = json.load(open(src))
segs = [{"offsets": {"from": int(s["start"] * 1000), "to": int(s["end"] * 1000)},
         "text": s.get("text", "")} for s in d.get("segments", [])]
json.dump({"transcription": segs}, open(dst, "w"), ensure_ascii=False)
PY
      rm -f "$REC/$2.groq.json"
    else
      say "  Groq nicht erreichbar — lokal (whisper.cpp)"
    fi
  fi
  [ -s "$REC/$2.json" ] || whisper-cli -m "$MODEL" -l "$LANG_CFG" -np -oj -of "$REC/$2" -f "$wav" >/dev/null 2>&1
  [ "$3" = "keep" ] || rm -f "$wav"
  [ -s "$REC/$2.json" ]
}

phase "$T_PH_TRANS"
say "Transkribiere ($TRANSCRIBER, $LANG_CFG) …"
transcribe mic.caf mic ""; MIC_OK=$?
transcribe system.caf system keep; SYS_OK=$?
[ $MIC_OK -ne 0 ] && [ $SYS_OK -ne 0 ] && fail "beide Spuren leer/nicht transkribierbar"

# --- Sprecher-Diarisierung der Gegenseite (mehrere Teilnehmer?) ------------------
DIA_JSON="$REC/diarization.json"
N_SPEAKERS=1
if [ "$DIARIZE" = "1" ] && [ $SYS_OK -eq 0 ] && [ -x "$VENV_PY" ] && [ -s "$REC/system.16k.wav" ]; then
  phase "$T_PH_DIA"
  say "Diarisierung (sherpa-onnx) …"
  "$VENV_PY" "$SCRIPT_DIR/diarize.py" "$REC/system.16k.wav" "$DIA_THRESHOLD" > "$DIA_JSON" 2>>"$REC/diarize.log" || rm -f "$DIA_JSON"
  if [ -s "$DIA_JSON" ]; then
    N_SPEAKERS=$(python3 -c "import json;print(json.load(open('$DIA_JSON')).get('speakers',1))" 2>/dev/null || echo 1)
    say "  Gegenseite: $N_SPEAKERS Sprecher erkannt"
  fi
fi
rm -f "$REC/system.16k.wav"

# --- Dialog mergen --------------------------------------------------------------
DIALOG="$REC/dialog.md"
if [ "$N_SPEAKERS" -gt 1 ]; then
  python3 "$MERGE" "$REC/mic.json" "$REC/system.json" "$SELF_LABEL" "$PEER_LABEL" "$DIA_JSON" "$SPEAKER_PREFIX" > "$DIALOG" 2>/dev/null
else
  python3 "$MERGE" "$REC/mic.json" "$REC/system.json" "$SELF_LABEL" "$PEER_LABEL" > "$DIALOG" 2>/dev/null
fi
[ -s "$DIALOG" ] || fail "Dialog-Merge leer"
WORDS=$(wc -w < "$DIALOG" | tr -d ' ')
say "Transkript: $WORDS Woerter"

# Teilnehmer-Namen, die waehrend des Calls im Popup eingetragen wurden
PARTICIPANTS=""
if [ -f "$REC/participants.json" ]; then
  PARTICIPANTS=$(python3 -c "import json;print(', '.join(json.load(open('$REC/participants.json')).get('names',[])))" 2>/dev/null || echo "")
fi

# --- KI-Zusammenfassung (Claude Code, OpenAI-kompatible API oder aus) --------------
SUMMARY="$REC/summary.md"

# Jede OpenAI-kompatible Chat-API: OpenAI, Groq, OpenRouter, Ollama (lokal), …
summarize_openai() {
  python3 - "$REC/prompt.txt" "$SUM_URL" "$SUM_MODEL" "$SUM_KEY" > "$SUMMARY" 2>>"$REC/summarizer.log" <<'PY'
import json, sys, urllib.request
prompt_file, base, model, key = sys.argv[1:5]
prompt = open(prompt_file, encoding="utf-8").read()
payload = {"model": model, "temperature": 0.2,
           "messages": [{"role": "user", "content": prompt}]}
# User-Agent noetig: manche API-Firewalls (z.B. Groq) blocken urllib-Default mit 403
headers = {"Content-Type": "application/json", "User-Agent": "CallNotes"}
if key:
    headers["Authorization"] = f"Bearer {key}"
req = urllib.request.Request(base + "/chat/completions",
                             data=json.dumps(payload).encode(), headers=headers)
resp = json.load(urllib.request.urlopen(req, timeout=180))
text = (resp.get("choices") or [{}])[0].get("message", {}).get("content", "").strip()
if not text:
    sys.exit(1)
# manche Modelle packen die Antwort in einen Codeblock
if text.startswith("```"):
    text = text.strip("`").lstrip("markdown").strip()
print(text)
PY
}

make_summary() {
  [ "$SUMMARIZER" = "off" ] && return 1
  if [ "$SUMMARIZER" = "openai" ]; then
    [ -n "$SUM_URL" ] && [ -n "$SUM_MODEL" ] || { say "  KI-Zusammenfassung: URL/Modell fehlen (Einstellungen)"; return 1; }
  else
    [ -n "$CLAUDE_BIN" ] && command -v "$CLAUDE_BIN" >/dev/null 2>&1 || return 1
  fi
  local extra=""
  local structure=""
  if [ "$LANG_CFG" = "de" ]; then
    if [ "$N_SPEAKERS" -gt 1 ]; then
      extra="Auf der Gegenseite wurden $N_SPEAKERS verschiedene Stimmen erkannt (\"$SPEAKER_PREFIX 1..$N_SPEAKERS\", nummeriert nach erster Wortmeldung)."
      [ -n "$PARTICIPANTS" ] && extra="$extra Laut $SELF_LABEL waren dabei: $PARTICIPANTS."
      extra="$extra Haenge ANS ENDE deiner Antwort eine einzelne Zeile an: ZUORDNUNG: $SPEAKER_PREFIX 1=<Name oder ?>; $SPEAKER_PREFIX 2=<Name oder ?>; ... — nutze Namen NUR wenn sie sich klar aus Anreden/Selbstvorstellungen im Transkript ergeben, sonst ?."
    elif [ -n "$PARTICIPANTS" ]; then
      extra="Gespraechspartner laut $SELF_LABEL: $PARTICIPANTS."
    fi
    case ",$SECTIONS," in *,kurzfassung,*) structure="$structure
## Kurzfassung
2-4 Saetze: mit wem (falls erkennbar), worum ging es, Ergebnis.
";; esac
    case ",$SECTIONS," in *,besprochen,*) structure="$structure
## Besprochen
- die wesentlichen Punkte, kompakt
";; esac
    case ",$SECTIONS," in *,todos,*) structure="$structure
## Zusagen & To-dos
- [ ] (selbst) was $SELF_LABEL zugesagt hat / tun muss
- [ ] (gegenseite) was der andere zugesagt hat
(nur echte Zusagen; wenn keine: \"- keine\")

## Offene Punkte
- was unklar blieb oder Follow-up braucht (wenn nichts: \"- keine\")
";; esac
    case ",$SECTIONS," in *,followup,*) structure="$structure
## Follow-up-Mail (Entwurf)
Kurzer, freundlicher Mail-Entwurf an die Gegenseite: Dank, Vereinbartes, naechste Schritte. Kein Betreff-Gedoens, direkt der Text.
";; esac
    {
      cat <<PROMPT
Du bekommst das Transkript eines Telefonats. "$SELF_LABEL" = die Person, deren Notiz das ist;
"$PEER_LABEL" bzw. "$SPEAKER_PREFIX N" = die Personen am anderen Ende.${CONTEXT:+ Kontext: $CONTEXT}
$extra
Whisper-Fehler (Namen, Zahlen, Fachbegriffe) im Kontext still korrigieren; akustisch
Unklares als [unklar] markieren, NIE raten.

Antworte NUR mit Markdown in exakt dieser Struktur (keine Vorrede, kein Codeblock):

# Telefonat <Name der Gegenseite oder Thema> — <TT.MM.>
$structure
Halte dich strikt ans Transkript, erfinde nichts dazu.

--- TRANSKRIPT ---
PROMPT
      cat "$DIALOG"
    } > "$REC/prompt.txt"
  else
    if [ "$N_SPEAKERS" -gt 1 ]; then
      extra="$N_SPEAKERS distinct voices were detected on the far end (\"$SPEAKER_PREFIX 1..$N_SPEAKERS\", numbered by first utterance)."
      [ -n "$PARTICIPANTS" ] && extra="$extra According to $SELF_LABEL the participants were: $PARTICIPANTS."
      extra="$extra Append ONE single line at the END of your answer: MAPPING: $SPEAKER_PREFIX 1=<name or ?>; $SPEAKER_PREFIX 2=<name or ?>; ... — use a name ONLY when it clearly follows from greetings/self-introductions in the transcript, otherwise ?."
    elif [ -n "$PARTICIPANTS" ]; then
      extra="Participants according to $SELF_LABEL: $PARTICIPANTS."
    fi
    case ",$SECTIONS," in *,kurzfassung,*) structure="$structure
## Summary
2-4 sentences: who (if identifiable), what it was about, outcome.
";; esac
    case ",$SECTIONS," in *,besprochen,*) structure="$structure
## Discussed
- the key points, concise
";; esac
    case ",$SECTIONS," in *,todos,*) structure="$structure
## Commitments & to-dos
- [ ] (self) what $SELF_LABEL committed to / must do
- [ ] (other side) what the other party committed to
(only real commitments; if none: \"- none\")

## Open items
- anything unclear or needing follow-up (if nothing: \"- none\")
";; esac
    case ",$SECTIONS," in *,followup,*) structure="$structure
## Follow-up email (draft)
Short, friendly draft to the other party: thanks, what was agreed, next steps. No subject line, just the body.
";; esac
    {
      cat <<PROMPT
You are given the transcript of a phone call. "$SELF_LABEL" = the person this note belongs to;
"$PEER_LABEL" / "$SPEAKER_PREFIX N" = the people on the other end.${CONTEXT:+ Context: $CONTEXT}
$extra
Silently correct obvious transcription errors (names, numbers, jargon) from context; mark
acoustically unclear parts as [unclear], NEVER guess.

Reply ONLY with Markdown in exactly this structure (no preamble, no code block):

# Call with <name of the other party or topic> — <MM/DD>
$structure
Stick strictly to the transcript; invent nothing.

--- TRANSCRIPT ---
PROMPT
      cat "$DIALOG"
    } > "$REC/prompt.txt"
  fi

  if [ "$SUMMARIZER" = "openai" ]; then
    summarize_openai || { say "  KI-API nicht erreichbar ($SUM_URL) — Details in summarizer.log"; return 1; }
  else
    ( "$CLAUDE_BIN" -p --model sonnet < "$REC/prompt.txt" > "$SUMMARY" 2>>"$REC/claude.log" ) &
    local pid=$! w=0
    while kill -0 $pid 2>/dev/null && [ $w -lt 300 ]; do sleep 5; w=$((w+5)); done
    if kill -0 $pid 2>/dev/null; then kill -9 $pid 2>/dev/null; say "  Claude-Timeout (300s)"; return 1; fi
    wait $pid || return 1
  fi
  grep -q '^#' "$SUMMARY" || return 1
}

phase "$T_PH_AI"
say "Zusammenfassung ($SUMMARIZER) …"
if ! make_summary; then
  [ "$SUMMARIZER" = "off" ] && say "  KI-Zusammenfassung deaktiviert — Notiz mit Transkript" || say "  KI nicht verfuegbar — Notiz ohne Zusammenfassung"
  if [ "$LANG_CFG" = "de" ]; then
    {
      echo "# Telefonat via $APP — $DATE_PART $TIME_NICE"
      echo
      echo "## Kurzfassung"
      echo "_Automatische Zusammenfassung nicht verfuegbar — Transkript unten._"
    } > "$SUMMARY"
  else
    {
      echo "# Call via $APP — $DATE_PART $TIME_NICE"
      echo
      echo "## Summary"
      echo "_Automatic summary unavailable — transcript below._"
    } > "$SUMMARY"
  fi
fi

# KI-Namensvorschlaege ("ZUORDNUNG:/MAPPING: Sprecher 1=Stefan; ...") extrahieren + aus Notiz strippen
SUGGESTIONS=$(grep -oE '(ZUORDNUNG|MAPPING):.*' "$SUMMARY" | head -1 | sed -E 's/^(ZUORDNUNG|MAPPING): *//')
grep -vE '^(ZUORDNUNG|MAPPING):' "$SUMMARY" > "$SUMMARY.tmp" && mv "$SUMMARY.tmp" "$SUMMARY"

# --- Notiz bauen ------------------------------------------------------------------
mkdir -p "$NOTES_DIR"
TITLE=$(head -1 "$SUMMARY" | sed 's/^# *//')
SLUG=$(echo "$TITLE" | sed -E 's/—.*$//; s/ä/ae/g; s/ö/oe/g; s/ü/ue/g; s/Ä/ae/g; s/Ö/oe/g; s/Ü/ue/g; s/ß/ss/g' \
  | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/telefonat//; s/call with//; s/\bcall\b//; s/unbekannt//; s/unknown//; s/[^a-z0-9]+/-/g; s/^-+|-+$//g; s/-+/-/g' | cut -c1-40 | sed 's/-$//')
[ -n "$SLUG" ] || SLUG="$APP"
NOTE="$NOTES_DIR/${DATE_PART}-${TIME_PART}-anruf-${SLUG}.md"
# nie eine bestehende Notiz ueberschreiben (zweiter Anruf in derselben Minute)
n=2
while [ -e "$NOTE" ]; do
  NOTE="$NOTES_DIR/${DATE_PART}-${TIME_PART}-anruf-${SLUG}-$n.md"
  n=$((n+1))
done
M4A_NAME="${STAMP}_${APP}.m4a"

{
  echo "---"
  echo "type: Note"
  echo "tags: [call, telefonat, log]"
  echo "app: $APP"
  echo "dauer: ${DUR_MIN}min"
  echo "updated: $DATE_PART"
  echo "---"
  echo
  cat "$SUMMARY"
  echo
  echo "## $T_TRANSCRIPT"
  echo
  cat "$DIALOG"
  echo
  echo "---"
  echo "$T_AUDIO_NOTE: \`$AUDIO_DIR/$M4A_NAME\` ($T_LEFT = $SELF_LABEL, $T_RIGHT = $PEER_LABEL)"
  if [ "$MOC_ON" = "1" ]; then
    echo
    echo "[[anrufe-moc]]"
  fi
} > "$NOTE"

# MOC pflegen (anlegen falls fehlt, neuen Eintrag oben in die Liste)
if [ "$MOC_ON" = "1" ]; then
  if [ "$LANG_CFG" = "de" ]; then
    MOC_TITLE="Anrufe MOC"; MOC_DESC="Automatische Telefonat-Notizen (CallNotes)."; MOC_LIST="Anrufe"
  else
    MOC_TITLE="Calls MOC"; MOC_DESC="Automatic call notes (CallNotes)."; MOC_LIST="Calls"
  fi
  if [ ! -f "$MOC" ]; then
    {
      echo "---"
      echo "type: MOC"
      echo "tags: [moc, call]"
      echo "updated: $DATE_PART"
      echo "---"
      echo
      echo "# $MOC_TITLE"
      echo
      echo "$MOC_DESC"
      echo
      echo "## $MOC_LIST"
    } > "$MOC"
  fi
  NOTE_BASE=$(basename "$NOTE" .md)
  python3 - "$MOC" "$NOTE_BASE" "$TITLE" "$DATE_PART" "$MOC_LIST" <<'PY'
import sys
moc, base, title, date, list_header = sys.argv[1:6]
with open(moc, encoding="utf-8") as f:
    lines = f.read().splitlines()
entry = f"- [[{base}]] — {title}"
if not any(base in l for l in lines):
    try:
        i = next(i for i, l in enumerate(lines)
                 if l.strip() in (f"## {list_header}", "## Anrufe", "## Calls")) + 1
    except StopIteration:
        lines.append(f"## {list_header}"); i = len(lines)
    lines.insert(i, entry)
lines = [f"updated: {date}" if l.startswith("updated:") else l for l in lines]
with open(moc, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
PY
fi
say "Notiz: $NOTE"

phase "$T_PH_STORE"
# --- Audio-Archiv (Stereo-m4a: L=selbst, R=Gegenseite), Rohdaten weg ---------------
mkdir -p "$AUDIO_DIR"
M4A="$AUDIO_DIR/$M4A_NAME"
if [ -s "$REC/mic.caf" ] && [ -s "$REC/system.caf" ]; then
  ffmpeg -hide_banner -loglevel error -y -i "$REC/mic.caf" -i "$REC/system.caf" \
    -filter_complex "[0:a]aresample=48000,pan=mono|c0=c0[l];[1:a]aresample=48000,pan=mono|c0=c0[r];[l][r]join=inputs=2:channel_layout=stereo[a]" \
    -map "[a]" -c:a aac -b:a 96k "$M4A" 2>/dev/null
else
  SRC="$REC/mic.caf"; [ -s "$REC/system.caf" ] && SRC="$REC/system.caf"
  ffmpeg -hide_banner -loglevel error -y -i "$SRC" -ar 48000 -c:a aac -b:a 96k "$M4A" 2>/dev/null
fi

# --- Mehrere Sprecher: Hoer-Schnipsel je Stimme + Zuordnungs-Auftrag fuer die UI ---
if [ "$N_SPEAKERS" -gt 1 ] && [ -s "$DIA_JSON" ] && [ -s "$REC/system.caf" ]; then
  REVIEW="$BASE/review/$STAMP"
  PENDING_DIR="$BASE/state/pending"
  mkdir -p "$REVIEW" "$PENDING_DIR"
  python3 - "$DIA_JSON" "$REC/system.caf" "$REVIEW" "$PENDING_DIR/$STAMP.json" "$NOTE" "$APP" "$STAMP" "$SUGGESTIONS" "$PARTICIPANTS" "$SPEAKER_PREFIX" <<'PY'
import json, subprocess, sys, os
dia_p, caf, review, pending_p, note, app, stamp, suggestions, participants, prefix = sys.argv[1:11]
dia = json.load(open(dia_p))
segs = dia.get("segments", [])
# Sprecher-Nummerierung wie im Transkript: nach erster Wortmeldung
first = {}
for s in segs:
    first.setdefault(s["speaker"], s["start"])
order = {spk: i + 1 for i, (spk, _) in enumerate(sorted(first.items(), key=lambda kv: kv[1]))}
# Claude-Vorschlaege parsen: "Sprecher 1=Stefan; Sprecher 2=?"
sugg = {}
for part in (suggestions or "").split(";"):
    if "=" in part:
        k, v = part.split("=", 1)
        v = v.strip()
        if v and v != "?":
            sugg[k.strip()] = v
speakers = []
for spk, num in sorted(order.items(), key=lambda kv: kv[1]):
    mine = [s for s in segs if s["speaker"] == spk]
    longest = max(mine, key=lambda s: s["end"] - s["start"])
    start = longest["start"]
    dur = min(longest["end"] - start, 8.0)
    clip = os.path.join(review, f"speaker_{num}.m4a")
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                    "-ss", str(start), "-t", str(max(dur, 1.5)), "-i", caf,
                    "-ar", "44100", "-ac", "1", "-c:a", "aac", "-b:a", "80k", clip], check=False)
    label = f"{prefix} {num}"
    speakers.append({"label": label, "clip": clip,
                     "suggestion": sugg.get(label, ""),
                     "totalSec": round(sum(s["end"] - s["start"] for s in mine), 1)})
names = [n.strip() for n in (participants or "").split(",") if n.strip()]
json.dump({"stamp": stamp, "app": app, "note": note, "speakers": speakers,
           "participants": names}, open(pending_p, "w"), ensure_ascii=False, indent=2)
print(f"Zuordnung vorbereitet: {len(speakers)} Sprecher -> {pending_p}")
PY
  say "Sprecher-Schnipsel + Zuordnungs-Auftrag erstellt (CallNotes-Menueleiste)"
fi

# --- Ablage-Ziele (waehlbar in CallNotes-Einstellungen) -----------------------------
# Apple Notes: Notiz zusaetzlich in Notes-Ordner "CallNotes" (Automation-Freigabe beim 1. Mal)
if [ "$DEST_NOTES" = "1" ]; then
  HTML_BODY=$(python3 - "$NOTE" <<'PY'
import html, sys
text = open(sys.argv[1], encoding="utf-8").read()
body = text.split("---", 2)[-1].strip()  # ohne Frontmatter
print(html.escape(body).replace("\n", "<br>"))
PY
)
  osascript - "$TITLE" "$HTML_BODY" >/dev/null 2>&1 <<'OSA' && say "Apple Notes: abgelegt" || say "Apple Notes fehlgeschlagen (Automation-Freigabe fuer calltap pruefen)"
on run argv
  set t to item 1 of argv
  set b to item 2 of argv
  tell application "Notes"
    if not (exists folder "CallNotes") then make new folder with properties {name:"CallNotes"}
    tell folder "CallNotes" to make new note with properties {body:("<h1>" & t & "</h1>" & b)}
  end tell
end run
OSA
fi

# Nextcloud (WebDAV): Creds aus den Einstellungen, Fallback secrets.env
if [ "$DEST_NC" = "1" ]; then
  NCU="$NC_URL_CFG"; NCN="$NC_USER_CFG"; NCP="$NC_PASS_CFG"
  if [ -z "$NCU" ] && [ -f "$SECRETS" ]; then
    # shellcheck disable=SC1090
    source "$SECRETS" 2>/dev/null || true
    NCU="${NEXTCLOUD_URL:-}"; NCN="${NEXTCLOUD_USER:-}"; NCP="${NEXTCLOUD_APPPASS:-}"
  fi
  if [ -n "$NCU" ] && [ -n "$NCN" ] && [ -n "$NCP" ]; then
    NC_BASE="${NCU%/}"
    case "$NC_BASE" in */remote.php/dav*) : ;; *) NC_BASE="$NC_BASE/remote.php/dav/files/$NCN" ;; esac
    curl -s -m 30 -u "$NCN:$NCP" -X MKCOL "$NC_BASE/CallNotes" >/dev/null 2>&1
    curl -s -m 60 -u "$NCN:$NCP" -T "$NOTE" "$NC_BASE/CallNotes/$(basename "$NOTE")" >/dev/null 2>&1 \
      && say "Nextcloud: abgelegt" || say "Nextcloud fehlgeschlagen (URL/Login pruefen, nicht kritisch)"
  else
    say "Nextcloud aktiviert, aber URL/Login fehlen (Einstellungen)"
  fi
fi

# Notion: neue Unterseite unter der konfigurierten Seite
if [ "$DEST_NOTION" = "1" ] && [ -n "$NOTION_TOKEN" ] && [ -n "$NOTION_PARENT" ]; then
  python3 - "$NOTE" "$TITLE" "$NOTION_TOKEN" "$NOTION_PARENT" <<'PY' && say "Notion: abgelegt" || say "Notion fehlgeschlagen (Token/Seiten-ID + Freigabe der Seite fuer die Integration pruefen)"
import json, re, sys, urllib.request
note, title, token, parent = sys.argv[1:5]
raw = re.sub(r"[^0-9a-fA-F]", "", parent)
if len(raw) != 32:
    sys.exit(1)
pid = f"{raw[0:8]}-{raw[8:12]}-{raw[12:16]}-{raw[16:20]}-{raw[20:32]}"
body = open(note, encoding="utf-8").read().split("---", 2)[-1].strip()
blocks = []
for para in body.split("\n"):
    if not para.strip():
        continue
    blocks.append({"object": "block", "type": "paragraph", "paragraph":
                   {"rich_text": [{"type": "text", "text": {"content": para[:1900]}}]}})
    if len(blocks) >= 95:
        blocks.append({"object": "block", "type": "paragraph", "paragraph":
                       {"rich_text": [{"type": "text", "text": {"content": "… (gekuerzt, Volltext in CallNotes)"}}]}})
        break
payload = {"parent": {"page_id": pid},
           "properties": {"title": {"title": [{"type": "text", "text": {"content": title}}]}},
           "children": blocks}
req = urllib.request.Request("https://api.notion.com/v1/pages",
                             data=json.dumps(payload).encode(),
                             headers={"Authorization": f"Bearer {token}",
                                      "Notion-Version": "2022-06-28",
                                      "Content-Type": "application/json",
                                      "User-Agent": "CallNotes"})
urllib.request.urlopen(req, timeout=30).read()
PY
fi

# --- Spiegel-Kopie (z.B. externe Festplatte), holt auch Verpasstes nach ------------
bash "$SCRIPT_DIR/callnotes-sync.sh" 2>&1 | while read -r l; do say "  $l"; done

# --- Aufraeumen + Push ---------------------------------------------------------------
if [ -s "$M4A" ]; then
  rm -rf "$REC"
else
  say "m4a fehlgeschlagen — Rohaufnahme bleibt in $REC"
fi

EXTRA_PUSH=""
[ "$N_SPEAKERS" -gt 1 ] && EXTRA_PUSH=" — $N_SPEAKERS Sprecher, Zuordnung in der CallNotes-Menueleiste"
ntfy "📞 ${TITLE} (${DUR_MIN}min via $APP) → $(basename "$NOTE")$EXTRA_PUSH"
phase_done
say "FERTIG: $TITLE"
