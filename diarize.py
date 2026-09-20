#!/usr/bin/env python3
# diarize.py — Sprecher-Diarisierung der Gegenseiten-Spur (sherpa-onnx, lokal/offline).
# Nutzung: diarize.py audio-16k-mono.wav [threshold] > diarization.json
# Ausgabe: {"speakers": N, "segments": [{"start": s, "end": s, "speaker": 0..N-1}]}
# Läuft im callnotes-venv (~/.local/share/callnotes/venv), Modelle in
# ~/.local/share/callnotes/models (Override: CALLNOTES_DIARIZE_MODELS).
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
SEG_MODEL = os.path.join(MODELS, "sherpa-onnx-pyannote-segmentation-3-0", "model.onnx")
EMB_MODEL = os.path.join(MODELS, "3dspeaker_speech_eres2net_sv_en_voxceleb_16k.onnx")


def read_wav_mono16k(path):
    with wave.open(path, "rb") as w:
        assert w.getsampwidth() == 2, "erwartet 16-bit PCM"
        rate = w.getframerate()
        frames = w.readframes(w.getnframes())
    samples = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
    if w.getnchannels() > 1:
        samples = samples.reshape(-1, w.getnchannels()).mean(axis=1)
    return samples, rate


def main():
    if len(sys.argv) < 2:
        sys.exit("Nutzung: diarize.py audio-16k-mono.wav [threshold]")
    wav_path = sys.argv[1]
    threshold = float(sys.argv[2]) if len(sys.argv) > 2 else 0.6

    for m in (SEG_MODEL, EMB_MODEL):
        if not os.path.exists(m):
            sys.exit(f"Modell fehlt: {m} (install.sh laedt die Diarisierungs-Modelle)")

    samples, rate = read_wav_mono16k(wav_path)

    config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
                model=SEG_MODEL
            ),
        ),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=EMB_MODEL),
        clustering=sherpa_onnx.FastClusteringConfig(num_clusters=-1, threshold=threshold),
        min_duration_on=0.3,
        min_duration_off=0.5,
    )
    sd = sherpa_onnx.OfflineSpeakerDiarization(config)
    if sd.sample_rate != rate:
        sys.exit(f"Samplerate {rate} passt nicht (Modell erwartet {sd.sample_rate})")

    result = sd.process(samples).sort_by_start_time()
    segments = [
        {"start": round(s.start, 2), "end": round(s.end, 2), "speaker": s.speaker}
        for s in result
    ]

    # Sprecher nach GESAMT-Redezeit gewichten. Winzige Cluster (Echo der eigenen
    # Stimme im getappten Ton, Rauschen, Whisper-Artefakte) sind KEINE echten
    # Teilnehmer — sonst "hoert" die Diarisierung bei einem 1:1-Anruf Dutzende Sprecher.
    dur = {}
    for s in segments:
        dur[s["speaker"]] = dur.get(s["speaker"], 0.0) + (s["end"] - s["start"])
    total = sum(dur.values()) or 1.0
    MIN_DUR, MIN_SHARE = 4.0, 0.03  # echte Stimme: >=4s UND >=3% der Redezeit
    significant = sorted(
        (spk for spk, d in dur.items() if d >= MIN_DUR and d / total >= MIN_SHARE),
        key=lambda spk: -dur[spk],
    )

    if len(significant) <= 1:
        # ein realer Gegenueber -> keine Aufsplittung, alle Segmente auf Sprecher 0
        for s in segments:
            s["speaker"] = 0
        speakers = 1
    else:
        remap = {spk: i for i, spk in enumerate(significant)}
        sig_set = set(significant)
        # (start, end, original_speaker) VOR dem Umnummerieren einfrieren
        sig_segs = [(s["start"], s["end"], s["speaker"]) for s in segments if s["speaker"] in sig_set]
        for s in segments:
            if s["speaker"] in remap:
                s["speaker"] = remap[s["speaker"]]
            else:
                # unbedeutendes Segment dem zeitlich naechsten echten Sprecher zuschlagen
                mid = (s["start"] + s["end"]) / 2
                st, en, best = min(
                    sig_segs,
                    key=lambda t: 0 if t[0] <= mid <= t[1] else min(abs(mid - t[0]), abs(mid - t[1])),
                )
                s["speaker"] = remap[best]
        speakers = len(significant)

    json.dump({"speakers": speakers, "segments": segments}, sys.stdout)
    print()


if __name__ == "__main__":
    main()
