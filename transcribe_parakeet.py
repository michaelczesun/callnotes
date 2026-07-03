#!/usr/bin/env python3
# transcribe_parakeet.py — Transkription mit NVIDIA Parakeet TDT v3 (25 EU-Sprachen)
# via sherpa-onnx (gleiche Runtime wie die Diarisierung — keine neue Abhaengigkeit).
# Sehr schnell auf CPU, keine Whisper-Halluzinations-Loops.
# Nutzung: transcribe_parakeet.py audio-16k-mono.wav out.json
# Ausgabe: whisper-cli-kompatibles JSON {"transcription":[{"offsets":{"from","to"},"text"}]}
# Modell:  CALLNOTES_PARAKEET_DIR oder <models>/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8
import glob
import json
import os
import sys
import wave

import numpy as np
import sherpa_onnx

MODELS = os.environ.get(
    "CALLNOTES_DIARIZE_MODELS",
    os.path.expanduser("~/.local/share/callnotes/models"),
)
PARAKEET = os.environ.get(
    "CALLNOTES_PARAKEET_DIR",
    os.path.join(MODELS, "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"),
)


def find_one(pattern):
    hits = sorted(glob.glob(os.path.join(PARAKEET, pattern)))
    return hits[0] if hits else None


def read_wav_mono16k(path):
    with wave.open(path, "rb") as w:
        assert w.getsampwidth() == 2, "erwartet 16-bit PCM"
        rate = w.getframerate()
        frames = w.readframes(w.getnframes())
        channels = w.getnchannels()
    samples = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)
    return samples, rate


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

    rec = sherpa_onnx.OfflineRecognizer.from_transducer(
        encoder=encoder, decoder=decoder, joiner=joiner, tokens=tokens,
        model_type="nemo_transducer", num_threads=4,
    )
    samples, rate = read_wav_mono16k(wav_path)
    stream = rec.create_stream()
    stream.accept_waveform(rate, samples)
    rec.decode_stream(stream)
    r = stream.result

    # Tokens (BPE, "▁" markiert Wortanfang) + Timestamps -> Woerter mit Zeit
    words = []  # (start, text)
    for tok, ts in zip(r.tokens, r.timestamps):
        # NeMo-BPE markiert Wortanfaenge mit Leerzeichen- oder ▁-Praefix
        if tok.startswith(" ") or tok.startswith("▁") or not words:
            words.append([ts, tok.lstrip(" ▁")])
        else:
            words[-1][1] += tok
    words = [(s, t.strip()) for s, t in words if t.strip()]

    # Woerter zu Segmenten gruppieren: Sprechpause > 1.0s oder Segment > 12s
    segments = []
    cur_words, cur_start = [], None
    prev_ts = None
    total_dur = len(samples) / rate

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

    json.dump({"transcription": segments}, open(out_path, "w"), ensure_ascii=False)
    print(f"{len(segments)} Segmente, {len(words)} Woerter", file=sys.stderr)


if __name__ == "__main__":
    main()
