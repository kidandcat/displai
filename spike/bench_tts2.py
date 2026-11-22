"""Second TTS pass: tune speed/steps, include digits, and check intelligibility
by transcribing each output with Parakeet v3 (round-trip word match).

Usage: python bench_tts2.py
"""

import os
import re
import time

import numpy as np
import sherpa_onnx as so
import soundfile as sf
from piper_phonemize import phonemize_espeak

HERE = os.path.dirname(os.path.abspath(__file__))
M = os.path.join(HERE, "models")
OUT = os.path.join(HERE, "out2")
THREADS = 4

TEXTS = [
    "Vale, te lo enseño en pantalla.",
    "Mañana en Madrid, máxima de 18 grados y lluvia a partir de las 17:30.",
    "He encontrado tres recetas; la segunda es la más rápida, unos 25 minutos.",
]


def norm(s):
    return re.sub(r"[^a-záéíóúñü0-9 ]", "", s.lower()).split()


def stt():
    p = os.path.join(M, "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8")
    return so.OfflineRecognizer.from_transducer(
        encoder=f"{p}/encoder.int8.onnx", decoder=f"{p}/decoder.int8.onnx", joiner=f"{p}/joiner.int8.onnx",
        tokens=f"{p}/tokens.txt", num_threads=THREADS, model_type="nemo_transducer")


def transcribe(rec, samples, sr):
    if sr != 16000:
        import math
        n = int(len(samples) * 16000 / sr)
        samples = np.interp(np.linspace(0, len(samples) - 1, n), np.arange(len(samples)), samples).astype(np.float32)
    s = rec.create_stream()
    s.accept_waveform(16000, samples)
    rec.decode_stream(s)
    return s.result.text


def piper(v):
    d = os.path.join(M, f"vits-piper-{v}")
    return so.OfflineTts(so.OfflineTtsConfig(model=so.OfflineTtsModelConfig(
        vits=so.OfflineTtsVitsModelConfig(model=f"{d}/{v}.onnx", tokens=f"{d}/tokens.txt"), num_threads=THREADS)))


def kokoro(dirname, model):
    d = os.path.join(M, dirname)
    return so.OfflineTts(so.OfflineTtsConfig(model=so.OfflineTtsModelConfig(
        kokoro=so.OfflineTtsKokoroModelConfig(model=f"{d}/{model}", voices=f"{d}/voices.bin",
                                              tokens=f"{d}/tokens.txt", lang="es"),
        num_threads=THREADS)))


def supertonic():
    d = os.path.join(M, "sherpa-onnx-supertonic-3-tts-int8-2026-05-11")
    return so.OfflineTts(so.OfflineTtsConfig(model=so.OfflineTtsModelConfig(
        supertonic=so.OfflineTtsSupertonicModelConfig(
            duration_predictor=f"{d}/duration_predictor.int8.onnx", text_encoder=f"{d}/text_encoder.int8.onnx",
            vector_estimator=f"{d}/vector_estimator.int8.onnx", vocoder=f"{d}/vocoder.int8.onnx",
            tts_json=f"{d}/tts.json", unicode_indexer=f"{d}/unicode_indexer.bin", voice_style=f"{d}/voice.bin"),
        num_threads=THREADS)))


def main():
    os.makedirs(OUT, exist_ok=True)
    rec = stt()
    piper_davefx = piper("es_ES-davefx-medium")
    piper_miro = piper("es_ES-miro-high")
    kok32 = kokoro("kokoro-multi-lang-v1_0", "model.onnx")
    sup = supertonic()
    # (label, engine, sid, speed, steps, phonemes?)
    configs = [
        ("piper-davefx", piper_davefx, 0, 1.0, None, True),
        ("piper-miro-high", piper_miro, 0, 1.0, None, True),
        ("kokoro-fp32-dora", kok32, 28, 1.0, None, True),
        ("kokoro-fp32-alex", kok32, 29, 1.0, None, True),
        ("supertonic3-s0-steps5", sup, 0, 1.2, 5, False),
        ("supertonic3-s6-steps3", sup, 6, 1.2, 3, False),
        ("supertonic3-s6-steps5", sup, 6, 1.2, 5, False),
    ]
    for label, tts, sid, speed, steps, ph in configs:
        gc = so.GenerationConfig()
        gc.sid = sid
        gc.speed = speed
        if steps:
            gc.num_steps = steps
            gc.extra["lang"] = "es"

        def gen(text):
            if ph:
                gc.phoneme_codepoints = [[ord(c) for c in s] for s in phonemize_espeak(text, "es")]
                return tts.generate("", gc)
            return tts.generate(text, gc)

        gen("Hola.")
        times, hits, words = [], 0, 0
        for i, text in enumerate(TEXTS):
            t = time.perf_counter()
            a = gen(text)
            dt = time.perf_counter() - t
            times.append(f"{dt*1000:.0f}ms/{len(a.samples)/a.sample_rate:.1f}s")
            sf.write(os.path.join(OUT, f"{label}-{i}.wav"), a.samples, a.sample_rate)
            heard = transcribe(rec, np.array(a.samples, dtype=np.float32), a.sample_rate)
            ref = norm(text)
            got = set(norm(heard))
            hits += sum(1 for w in ref if w in got)
            words += len(ref)
            if i == 1:
                last_heard = heard
        print(f"{label:24s} synth/audio: {' '.join(times)}  roundtrip-words {hits}/{words}  e.g. '{last_heard}'")


if __name__ == "__main__":
    main()
