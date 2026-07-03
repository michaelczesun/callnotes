#!/usr/bin/env python3
# merge-transcript.py — mischt zwei whisper-cli-JSONs (Mikro + Systemaudio) zu einem
# chronologischen Dialog-Transkript mit Sprecher-Labels.
# Nutzung: merge-transcript.py mic.json system.json [label_selbst] [label_gegenseite] [diarization.json] > dialog.md
# Mit diarization.json (aus diarize.py) und >1 erkanntem Sprecher wird die
# Gegenseite in "Sprecher 1..N" aufgeteilt (Zuordnung per Zeitueberlappung).
import json
import re
import sys

# Bekannte Whisper-Halluzinationen bei Stille/Musik
JUNK = re.compile(
    r"^(\[?\(?(musik|music|applaus|applause|gel(ä|ae)chter|lachen)\)?\]?[.!]?"
    r"|untertitel.*|amara\.org.*|copyright.*|swr\s?\d{4}.*|zdf.*|das erste.*"
    r"|vielen dank f(ü|ue)rs zuschauen[.!]?|bis zum n(ä|ae)chsten mal[.!]?)$",
    re.IGNORECASE,
)


def collapse_repeats(text, min_words=4):
    # Whisper wiederholt bei Stille am Segmentende gern dieselbe Phrase in Schleife
    # ("… per WhatsApp an und ich rufe dann gleich später einen Kollegen per WhatsApp
    # an und ich rufe …") — exakte Wiederholungen ab min_words Wörtern kollabieren.
    words = text.split()
    out = []
    i = 0
    while i < len(words):
        out.append(words[i])
        i += 1
        for n in range(min(14, len(out)), min_words - 1, -1):
            if out[-n:] == words[i:i + n]:
                while out[-n:] == words[i:i + n]:
                    i += n
                break
    return " ".join(out)


def load(path, label):
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, json.JSONDecodeError):
        return []
    segs = []
    for s in d.get("transcription", []):
        text = collapse_repeats((s.get("text") or "").strip())
        if not text or JUNK.match(text):
            continue
        off = s.get("offsets") or {}
        segs.append({
            "start": int(off.get("from", 0)),
            "end": int(off.get("to", 0)),
            "who": label,
            "text": text,
        })
    return segs


def words(t):
    return set(re.findall(r"\w+", t.lower()))


def crosstalk(mic_seg, sys_segs):
    # Uebersprechen: Lautsprecher-Ton der Gegenseite landet im Mikro. Wenn ein
    # Mikro-Segment zeitlich ueberlappend und textlich aehnlich auf der System-
    # Spur existiert, ist es ein Echo -> verwerfen. Bei fast vollstaendiger
    # Zeitueberdeckung reicht schwaechere Text-Aehnlichkeit (Echo ist oft
    # verwaschen und wird von Whisper anders verhoert).
    w = words(mic_seg["text"])
    if not w:
        return True
    dur = max(mic_seg["end"] - mic_seg["start"], 1)
    for s in sys_segs:
        if s["start"] > mic_seg["end"] + 1000 or s["end"] < mic_seg["start"] - 1000:
            continue
        sw = words(s["text"])
        if not sw:
            continue
        sim = len(w & sw) / len(w | sw)
        overlap = (min(mic_seg["end"], s["end"]) - max(mic_seg["start"], s["start"])) / dur
        if sim > 0.6 or (overlap > 0.7 and sim > 0.3):
            return True
    return False


def load_diarization(path):
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, json.JSONDecodeError):
        return None
    if d.get("speakers", 0) < 2:
        return None
    return d.get("segments") or None


def assign_speakers(sys_segs, dia_segs, prefix="Sprecher"):
    # Whisper-Segment -> Diarisierungs-Sprecher mit groesster Zeitueberlappung.
    # Sprecher-Nummern nach erster Wortmeldung sortieren (Sprecher 1 = wer zuerst spricht).
    first_seen = {}
    for ds in dia_segs:
        first_seen.setdefault(ds["speaker"], ds["start"])
    order = {spk: i + 1 for i, (spk, _) in enumerate(sorted(first_seen.items(), key=lambda kv: kv[1]))}
    for seg in sys_segs:
        s0, s1 = seg["start"] / 1000.0, seg["end"] / 1000.0
        best, best_ov = None, 0.0
        for ds in dia_segs:
            ov = min(s1, ds["end"]) - max(s0, ds["start"])
            if ov > best_ov:
                best, best_ov = ds["speaker"], ov
        if best is not None:
            seg["who"] = f"{prefix} {order[best]}"
    return sys_segs


def main():
    if len(sys.argv) < 3:
        sys.exit("Nutzung: merge-transcript.py mic.json system.json [label_selbst] [label_gegenseite] [diarization.json]")
    label_self = sys.argv[3] if len(sys.argv) > 3 else "Ich"
    label_peer = sys.argv[4] if len(sys.argv) > 4 else "Gesprächspartner"
    mic_segs = load(sys.argv[1], label_self)
    sys_segs = load(sys.argv[2], label_peer)
    if len(sys.argv) > 5:
        dia = load_diarization(sys.argv[5])
        if dia:
            prefix = sys.argv[6] if len(sys.argv) > 6 else "Sprecher"
            sys_segs = assign_speakers(sys_segs, dia, prefix)
    mic_segs = [m for m in mic_segs if not crosstalk(m, sys_segs)]
    segs = mic_segs + sys_segs
    segs.sort(key=lambda s: s["start"])

    merged = []
    for s in segs:
        # gleiche Sprecher mit <2,5s Luecke zusammenfassen
        if merged and merged[-1]["who"] == s["who"] and s["start"] - merged[-1]["end"] < 2500:
            merged[-1]["text"] += " " + s["text"]
            merged[-1]["end"] = s["end"]
        else:
            merged.append(dict(s))

    lines = []
    for s in merged:
        m, sec = divmod(s["start"] // 1000, 60)
        lines.append(f"**{s['who']}** [{m:02d}:{sec:02d}]: {s['text']}")
    print("\n\n".join(lines))


if __name__ == "__main__":
    main()
