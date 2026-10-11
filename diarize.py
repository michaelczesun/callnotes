#!/usr/bin/env python3
# diarize.py — Sprecher-Erkennung der Gegenseiten-Spur (lokal/offline, sherpa-onnx).
# Nutzung: diarize.py audio-16k-mono.wav [schwelle] > diarization.json
# Ausgabe: {"speakers": N, "segments": [{"start": s, "end": s, "speaker": 0..N-1}]}
#          Sprecher 0 = wer am meisten redet.
#
# Ablauf: Sprachabschnitte per VAD (callnotes_audio) -> je Abschnitt ein Stimm-
# Fingerabdruck (Speaker-Embedding) -> aehnliche Abschnitte zusammenfassen
# (agglomerativ, mittlere Kosinus-Aehnlichkeit) -> Cluster mit zu wenig Redezeit
# dem naechsten echten Sprecher zuschlagen.
#
# Warum nicht mehr pyannote-Vollanalyse (bis 1.4.0): sie zerlegte EINE Stimme in
# Dutzende Pseudo-Sprecher (bis 173 bei einem 1:1-Call) und brauchte 5-27 Min.
# Kalibriert 11.10.2026 an echten Calls: Michaels Mikro-Spur (garantiert 1 Sprecher)
# ergibt bei Schwelle 0.30-0.45 immer 1, Mikro+Gegenseite gemischt immer 2 (99 %
# richtig zugeordnet), auch wenn Michaels Stimme vorher durch den Discord-Codec
# (Opus) geht. Default 0.40 = Mitte des sicheren Bereichs. Hoeher = mehr Sprecher.
import json
import os
import sys

import numpy as np
import sherpa_onnx

from callnotes_audio import MODELS, Wav, vad_segments

EMB_MODEL = os.path.join(MODELS, "3dspeaker_speech_eres2net_sv_en_voxceleb_16k.onnx")
THREADS = int(os.environ.get("CALLNOTES_THREADS", "2"))
MIN_EMB = 1.0      # s — kuerzere Abschnitte haben keinen verlaesslichen Fingerabdruck
MAX_EMB = 10.0     # s — von langen Abschnitten reicht die Mitte
# Echter Sprecher: >= 15 s UND >= 2 % der Redezeit. Gemessen 11.10.: in 1:1-Calls sind alle
# Neben-Cluster Kruemel (<= 5 s, <= 1,5 %), im Team-Call hat der stillste Teilnehmer 56 s (3,3 %).
MIN_DUR, MIN_SHARE = 15.0, 0.02


def cluster(E, threshold):
    """Agglomeratives Clustering (average linkage, Kosinus); stoppt unter threshold."""
    n = len(E)
    C = (E @ E.T).astype(np.float64)
    np.fill_diagonal(C, -np.inf)
    size = np.ones(n)
    members = [[i] for i in range(n)]
    for _ in range(n - 1):
        k = int(np.argmax(C))
        i, j = divmod(k, n)
        if C[i, j] < threshold:
            break
        row = (size[i] * C[i] + size[j] * C[j]) / (size[i] + size[j])
        C[i], C[:, i] = row, row
        C[i, i] = -np.inf
        C[j], C[:, j] = -np.inf, -np.inf
        size[i] += size[j]
        members[i] += members[j]
        members[j] = []
    lab = np.empty(n, int)
    for c, m in enumerate(m for m in members if m):
        lab[m] = c
    return lab


def main():
    if len(sys.argv) < 2:
        sys.exit("Nutzung: diarize.py audio-16k-mono.wav [schwelle]")
    wav_path = sys.argv[1]
    threshold = float(sys.argv[2]) if len(sys.argv) > 2 else 0.40
    if not os.path.exists(EMB_MODEL):
        sys.exit(f"Modell fehlt: {EMB_MODEL} (install.sh laedt die Diarisierungs-Modelle)")

    wav = Wav(wav_path)
    rate = wav.rate
    segs = vad_segments(wav)
    if not segs:
        json.dump({"speakers": 0, "segments": []}, sys.stdout)
        print()
        return

    ex = sherpa_onnx.SpeakerEmbeddingExtractor(
        sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=EMB_MODEL, num_threads=THREADS))
    long_idx, emb = [], []
    for i, (s, e) in enumerate(segs):
        if (e - s) / rate < MIN_EMB:
            continue
        if (e - s) / rate > MAX_EMB:
            mid, half = (s + e) // 2, int(MAX_EMB * rate / 2)
            s, e = mid - half, mid + half
        st = ex.create_stream()
        st.accept_waveform(rate, wav.read(s, e))
        st.input_finished()
        v = np.array(ex.compute(st))
        emb.append(v / (np.linalg.norm(v) + 1e-9))
        long_idx.append(i)

    dur = np.array([(e - s) / rate for s, e in segs])
    labels = np.zeros(len(segs), int)
    if len(emb) >= 2:
        E = np.array(emb)
        lab = cluster(E, threshold)
        d = dur[long_idx]
        keep = [c for c in set(lab) if d[lab == c].sum() >= max(MIN_DUR, MIN_SHARE * d.sum())]
        if not keep:
            keep = [max(set(lab), key=lambda c: d[lab == c].sum())]
        cent = np.array([E[lab == c].mean(0) for c in keep])
        cent /= np.linalg.norm(cent, axis=1, keepdims=True)
        lab = np.array(keep)[np.argmax(E @ cent.T, axis=1)]  # Kleinst-Cluster umverteilen
        labels[long_idx] = lab
        # kurze Abschnitte (< MIN_EMB): Sprecher des zeitlich naechsten langen Abschnitts
        mids = np.array([(segs[i][0] + segs[i][1]) / 2 for i in long_idx])
        long_set = set(long_idx)
        for i, (s, e) in enumerate(segs):
            if i not in long_set:
                labels[i] = lab[int(np.argmin(np.abs(mids - (s + e) / 2)))]
        # Sprecher nach Redezeit nummerieren (0 = Hauptsprecher)
        order = sorted(set(labels), key=lambda c: -dur[labels == c].sum())
        labels = np.array([order.index(c) for c in labels])

    out = [{"start": round(s / rate, 2), "end": round(e / rate, 2), "speaker": int(c)}
           for (s, e), c in zip(segs, labels)]
    n = len(set(labels))
    json.dump({"speakers": n, "segments": out}, sys.stdout)
    print()
    print(f"{n} Sprecher | {len(segs)} Abschnitte, {len(emb)} mit Fingerabdruck, "
          f"Schwelle {threshold}", file=sys.stderr)


if __name__ == "__main__":
    main()
