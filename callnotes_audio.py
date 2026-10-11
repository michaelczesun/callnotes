#!/usr/bin/env python3
# callnotes_audio.py — gemeinsame Audio-Bausteine fuer transcribe_parakeet.py und diarize.py:
# WAV stueckweise lesen + Sprachabschnitte finden (silero-VAD, ohne Modell: Energie).
# Liegt neben den Skripten; Python nimmt das Skript-Verzeichnis automatisch in sys.path.
import os
import wave

import numpy as np
import sherpa_onnx

MODELS = os.environ.get(
    "CALLNOTES_DIARIZE_MODELS",
    os.path.expanduser("~/.local/share/callnotes/models"),
)
SILERO = os.path.join(MODELS, "silero_vad.onnx")
MAX_SPEECH = 20.0  # s — laengere Abschnitte teilt der VAD selbst


class Wav:
    """16-bit-WAV stueckweise lesen — eine 2-h-Spur nie komplett als float32 im RAM."""

    def __init__(self, path):
        self.w = wave.open(path, "rb")
        assert self.w.getsampwidth() == 2, "erwartet 16-bit PCM"
        self.rate = self.w.getframerate()
        self.ch = self.w.getnchannels()
        self.n = self.w.getnframes()

    def read(self, start, end):
        start, end = max(0, start), min(self.n, end)
        self.w.setpos(start)
        x = np.frombuffer(self.w.readframes(end - start), dtype=np.int16).astype(np.float32) / 32768.0
        return x.reshape(-1, self.ch).mean(axis=1) if self.ch > 1 else x


def vad_segments(wav):
    """Sprachabschnitte als [(start, end)] in Samples."""
    rate = wav.rate
    if os.path.exists(SILERO):
        cfg = sherpa_onnx.VadModelConfig()
        cfg.silero_vad.model = SILERO
        cfg.silero_vad.threshold = 0.4
        cfg.silero_vad.min_silence_duration = 0.4
        cfg.silero_vad.min_speech_duration = 0.25
        if hasattr(cfg.silero_vad, "max_speech_duration"):
            cfg.silero_vad.max_speech_duration = MAX_SPEECH
        cfg.sample_rate = rate
        cfg.num_threads = 1
        vad = sherpa_onnx.VoiceActivityDetector(cfg, buffer_size_in_seconds=MAX_SPEECH * 3)
        win = cfg.silero_vad.window_size
        segs = []

        def drain():
            while not vad.empty():
                f = vad.front
                segs.append((f.start, f.start + len(f.samples)))
                vad.pop()

        block = win * 200  # ~6 s pro Lesevorgang
        for b in range(0, wav.n, block):
            x = wav.read(b, b + block)
            for i in range(0, len(x) - win + 1, win):
                vad.accept_waveform(x[i:i + win])
            drain()
        vad.flush()
        drain()
        return segs
    # Fallback ohne Modell: Energie je 30-ms-Frame gegen den Grundrausch-Pegel
    frame = int(0.03 * rate)
    db = []
    for b in range(0, wav.n, frame * 2000):
        x = wav.read(b, b + frame * 2000)
        k = len(x) // frame
        if k:
            rms = np.sqrt((x[: k * frame].reshape(k, frame) ** 2).mean(axis=1) + 1e-12)
            db.extend(20 * np.log10(rms))
    db = np.array(db)
    if not len(db):
        return []
    speech = db > max(np.percentile(db, 20) + 10, -55)
    segs, start = [], None
    for i, s in enumerate(speech):
        if s and start is None:
            start = i
        elif not s and start is not None:
            if i - start >= 8:  # >= 240 ms
                segs.append((start * frame, i * frame))
            start = None
    if start is not None:
        segs.append((start * frame, len(speech) * frame))
    return segs
