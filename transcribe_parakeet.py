#!/usr/bin/env python3
# transcribe_parakeet.py — Transkription mit NVIDIA Parakeet TDT v3 (25 EU-Sprachen)
# via sherpa-onnx (gleiche Runtime wie die Diarisierung — keine neue Abhaengigkeit).
# Nutzung: transcribe_parakeet.py audio-16k-mono.wav out.json
# Ausgabe: whisper-cli-kompatibles JSON {"transcription":[{"offsets":{"from","to"},"text"}]}
# Modell:  CALLNOTES_PARAKEET_DIR oder <models>/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8
#
# WICHTIG: nie die ganze Aufnahme in EINEN Stream geben. Der Encoder-Speicher waechst
# mit der Laenge ueberproportional — ab ~10 Min. Audio wurde der Prozess auf 8-GB-Macs
# vom System gekillt (Killed: 9), erst nach 10-25 Min. Volllast. Stattdessen: Sprach-
# abschnitte per VAD finden (silero_vad.onnx; ohne Modell: Energie-Schaetzung), zu
# Stuecken <= MAX_CHUNK s buendeln, Stille ueberspringen, stueckweise dekodieren.
# Der Speicher bleibt damit unabhaengig von der Anruflaenge.
import glob
import json
import os
import sys
import time

import sherpa_onnx

from callnotes_audio import SILERO, Wav, vad_segments

MODELS = os.environ.get(
    "CALLNOTES_DIARIZE_MODELS",
    os.path.expanduser("~/.local/share/callnotes/models"),
)
PARAKEET = os.environ.get(
    "CALLNOTES_PARAKEET_DIR",
    os.path.join(MODELS, "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"),
)
THREADS = int(os.environ.get("CALLNOTES_THREADS", "2"))  # 2 = fast so schnell wie 4, halbe Last

MAX_CHUNK = 20.0   # s pro Dekodier-Stueck (Kontext fuer gute Erkennung, Speicher klein)
JOIN_GAP = 1.5     # Sprachabschnitte mit kuerzerer Pause in dasselbe Stueck
PAD = 0.15         # s Rand um jedes Stueck (keine abgeschnittenen Wortanfaenge)
BATCH = int(os.environ.get("CALLNOTES_PARAKEET_BATCH", "1"))  # Stuecke pro decode_streams-Aufruf


def find_one(pattern):
    hits = sorted(glob.glob(os.path.join(PARAKEET, pattern)))
    return hits[0] if hits else None


def chunks(segs, rate, n):
    """Benachbarte Sprachabschnitte zu Stuecken <= MAX_CHUNK s buendeln (Stille dazwischen
    nur bei kurzen Pausen mitnehmen). Ueberlange Abschnitte hart teilen."""
    maxlen, gap, pad = int(MAX_CHUNK * rate), int(JOIN_GAP * rate), int(PAD * rate)
    pieces = []
    for s, e in segs:
        while e - s > maxlen:
            pieces.append((s, s + maxlen))
            s += maxlen
        if e > s:
            pieces.append((s, e))
    out = []
    for s, e in pieces:
        if out and s - out[-1][1] <= gap and e - out[-1][0] <= maxlen:
            out[-1] = (out[-1][0], e)
        else:
            out.append((s, e))
    return [(max(0, s - pad), min(n, e + pad)) for s, e in out]


def main():
    if len(sys.argv) < 3:
        sys.exit("Nutzung: transcribe_parakeet.py audio-16k-mono.wav out.json")
    wav_path, out_path = sys.argv[1], sys.argv[2]

    encoder = find_one("encoder*.onnx")
    decoder = find_one("decoder*.onnx")
    joiner = find_one("joiner*.onnx")
    tokens = find_one("tokens.txt")
    if not all([encoder, decoder, joiner, tokens]):
        sys.exit(f"Parakeet-Modell unvollstaendig/fehlt in {PARAKEET} "
                 f"(encoder/decoder/joiner/tokens noetig)")

    t0 = time.time()
    wav = Wav(wav_path)
    rate = wav.rate
    segs = vad_segments(wav)
    parts = chunks(segs, rate, wav.n)
    t_vad = time.time() - t0

    rec = sherpa_onnx.OfflineRecognizer.from_transducer(
        encoder=encoder, decoder=decoder, joiner=joiner, tokens=tokens,
        model_type="nemo_transducer", num_threads=THREADS,
    )

    # Tokens (BPE, "▁"/Leerzeichen markiert Wortanfang) + Timestamps -> Woerter mit Zeit
    words = []  # [start_s, text]
    for b in range(0, len(parts), BATCH):
        batch = parts[b:b + BATCH]
        streams = []
        for s, e in batch:
            st = rec.create_stream()
            st.accept_waveform(rate, wav.read(s, e))
            streams.append(st)
        rec.decode_streams(streams)
        for (s, _), st in zip(batch, streams):
            r = st.result
            off = s / rate
            new_word = True  # jedes Stueck beginnt mit einem neuen Wort
            for tok, ts in zip(r.tokens, r.timestamps):
                if new_word or tok.startswith(" ") or tok.startswith("▁"):
                    words.append([off + ts, tok.lstrip(" ▁")])
                    new_word = False
                else:
                    words[-1][1] += tok
    words = [(s, t.strip()) for s, t in words if t.strip()]

    # Woerter zu Segmenten gruppieren: Sprechpause > 1.0s oder Segment > 12s
    segments = []
    cur_words, cur_start, prev_ts = [], None, None
    total_dur = wav.n / rate

    def flush(end_ts):
        if cur_words:
            segments.append({
                "offsets": {"from": int(cur_start * 1000), "to": int(end_ts * 1000)},
                "text": " " + " ".join(w for _, w in cur_words),
            })

    for ts, w in words:
        if cur_start is None:
            cur_start = ts
        elif (prev_ts is not None and ts - prev_ts > 1.0) or (ts - cur_start > 12.0):
            flush(min(prev_ts + 0.6, ts))
            cur_words, cur_start = [], ts
        cur_words.append((ts, w))
        prev_ts = ts
    if cur_words:
        flush(min((prev_ts or 0) + 0.6, total_dur))

    with open(out_path, "w") as f:
        json.dump({"transcription": segments}, f, ensure_ascii=False)
    speech = sum(e - s for s, e in parts) / rate
    took = time.time() - t0
    print(f"{len(segments)} Segmente, {len(words)} Woerter | {len(parts)} Stuecke, "
          f"{speech / 60:.1f} von {total_dur / 60:.1f} Min. Sprache "
          f"({'silero' if os.path.exists(SILERO) else 'energie'}-VAD {t_vad:.0f}s) | "
          f"{took:.0f}s gesamt, x{total_dur / max(took, 1):.0f} Echtzeit", file=sys.stderr)


if __name__ == "__main__":
    main()
