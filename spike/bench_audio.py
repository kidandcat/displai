"""Benchmark local STT and TTS candidates (sherpa-onnx) for Spanish on this Mac.

STT: for each test wav, simulate the live path: Silero VAD over 30 ms frames
detects end of speech, then the offline recognizer decodes the segment. We
report decode time after VAD end (what adds to latency) and the transcript.
Streaming (Kroko) decodes while audio arrives; we report time to final result
after the last frame.

TTS: time to first audio chunk and real-time factor for a short Spanish
sentence, and write samples to out/ so a human can judge quality.

Usage: python bench_audio.py [stt|tts|all]
"""

import os
import sys
import time

import numpy as np
import sherpa_onnx as so
import soundfile as sf

M = os.path.join(os.path.dirname(os.path.abspath(__file__)), "models")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
AUDIO = os.path.join(os.path.dirname(os.path.abspath(__file__)), "audio")
THREADS = 4

SENTENCES = [
    "Aquí tienes el tiempo de mañana en Madrid: máxima de dieciocho grados y algo de lluvia por la tarde.",
    "Vale, te lo enseño en pantalla.",
]


def load_wav(path):
    data, sr = sf.read(path, dtype="float32")
    assert sr == 16000, sr
    return data


def vad_end_times(samples, sr=16000):
    """Run Silero VAD and return (segment_samples, wall time spent on VAD per 30ms frame)."""
    cfg = so.VadModelConfig()
    cfg.silero_vad.model = os.path.join(M, "silero_vad_v5.onnx")
    cfg.silero_vad.min_silence_duration = 0.3
    cfg.silero_vad.threshold = 0.5
    cfg.sample_rate = sr
    vad = so.VoiceActivityDetector(cfg, buffer_size_in_seconds=30)
    win = cfg.silero_vad.window_size
    # pad with 1 s of silence so the VAD can close the segment
    padded = np.concatenate([samples, np.zeros(sr, dtype=np.float32)])
    t = time.perf_counter()
    n = 0
    segs = []
    for i in range(0, len(padded) - win, win):
        vad.accept_waveform(padded[i:i + win])
        n += 1
        while not vad.empty():
            segs.append(np.array(vad.front.samples, dtype=np.float32))
            vad.pop()
    per_frame = (time.perf_counter() - t) / n
    return segs, per_frame


def offline_recognizers():
    p3 = os.path.join(M, "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8")
    es = os.path.join(M, "sherpa-onnx-nemo-fast-conformer-transducer-es-1424-int8")
    out = {}
    t = time.perf_counter()
    out["parakeet-tdt-0.6b-v3-int8"] = so.OfflineRecognizer.from_transducer(
        encoder=f"{p3}/encoder.int8.onnx", decoder=f"{p3}/decoder.int8.onnx", joiner=f"{p3}/joiner.int8.onnx",
        tokens=f"{p3}/tokens.txt", num_threads=THREADS, model_type="nemo_transducer")
    print(f"  load parakeet: {time.perf_counter()-t:.2f}s")
    t = time.perf_counter()
    out["fastconformer-es-int8"] = so.OfflineRecognizer.from_transducer(
        encoder=f"{es}/encoder.int8.onnx", decoder=f"{es}/decoder.int8.onnx", joiner=f"{es}/joiner.int8.onnx",
        tokens=f"{es}/tokens.txt", num_threads=THREADS, model_type="nemo_transducer")
    print(f"  load fastconformer-es: {time.perf_counter()-t:.2f}s")
    return out


def bench_stt():
    print("== STT")
    wavs = sorted(f for f in os.listdir(AUDIO) if f.endswith(".wav"))
    recs = offline_recognizers()
    for name, rec in recs.items():
        # warm-up
        s = rec.create_stream(); s.accept_waveform(16000, np.zeros(16000, dtype=np.float32)); rec.decode_stream(s)
        print(f" {name}")
        for w in wavs:
            samples = load_wav(os.path.join(AUDIO, w))
            segs, vad_frame = vad_end_times(samples)
            seg = np.concatenate(segs) if segs else samples
            t = time.perf_counter()
            st = rec.create_stream()
            st.accept_waveform(16000, seg)
            rec.decode_stream(st)
            dt = time.perf_counter() - t
            print(f"   {w} {len(samples)/16000:.1f}s audio, decode {dt*1000:.0f} ms (vad {vad_frame*1000:.2f} ms/frame): {st.result.text}")

    kr = os.path.join(M, "sherpa-onnx-streaming-zipformer-es-kroko-2025-08-06")
    rec = so.OnlineRecognizer.from_transducer(
        tokens=f"{kr}/tokens.txt", encoder=f"{kr}/encoder.onnx", decoder=f"{kr}/decoder.onnx",
        joiner=f"{kr}/joiner.onnx", num_threads=THREADS, enable_endpoint_detection=False)
    print(" kroko-streaming-es")
    for w in wavs:
        samples = load_wav(os.path.join(AUDIO, w))
        st = rec.create_stream()
        chunk = 1600  # 100 ms
        for i in range(0, len(samples), chunk):
            st.accept_waveform(16000, samples[i:i + chunk])
            while rec.is_ready(st):
                rec.decode_stream(st)
        t = time.perf_counter()
        st.accept_waveform(16000, np.zeros(8000, dtype=np.float32))
        st.input_finished()
        while rec.is_ready(st):
            rec.decode_stream(st)
        dt = time.perf_counter() - t
        print(f"   {w} final after last frame {dt*1000:.0f} ms: {rec.get_result(st)}")


def tts_engines():
    e = {}
    for v in ["es_ES-davefx-medium", "es_ES-sharvard-medium", "es_ES-miro-high"]:
        d = os.path.join(M, f"vits-piper-{v}")
        cfg = so.OfflineTtsConfig(model=so.OfflineTtsModelConfig(
            vits=so.OfflineTtsVitsModelConfig(model=f"{d}/{v}.onnx", tokens=f"{d}/tokens.txt",
                                              data_dir=f"{d}/espeak-ng-data"),
            num_threads=THREADS))
        e[f"piper-{v}"] = (so.OfflineTts(cfg), [0])
    d = os.path.join(M, "kokoro-int8-multi-lang-v1_0")
    cfg = so.OfflineTtsConfig(model=so.OfflineTtsModelConfig(
        kokoro=so.OfflineTtsKokoroModelConfig(model=f"{d}/model.int8.onnx", voices=f"{d}/voices.bin",
                                              tokens=f"{d}/tokens.txt", data_dir=f"{d}/espeak-ng-data",
                                              lang="es"),
        num_threads=THREADS))
    e["kokoro-v1.0-int8"] = (so.OfflineTts(cfg), [28, 29])  # ef_dora, em_alex
    d = os.path.join(M, "sherpa-onnx-supertonic-3-tts-int8-2026-05-11")
    cfg = so.OfflineTtsConfig(model=so.OfflineTtsModelConfig(
        supertonic=so.OfflineTtsSupertonicModelConfig(
            duration_predictor=f"{d}/duration_predictor.int8.onnx", text_encoder=f"{d}/text_encoder.int8.onnx",
            vector_estimator=f"{d}/vector_estimator.int8.onnx", vocoder=f"{d}/vocoder.int8.onnx",
            tts_json=f"{d}/tts.json", unicode_indexer=f"{d}/unicode_indexer.bin", voice_style=f"{d}/voice.bin"),
        num_threads=THREADS))
    e["supertonic-3-int8"] = (so.OfflineTts(cfg), [0, 6])
    return e


def bench_tts():
    print("== TTS")
    os.makedirs(OUT, exist_ok=True)
    for name, (tts, sids) in tts_engines().items():
        for sid in sids:
            gc = so.GenerationConfig()
            gc.sid = sid
            gc.speed = 1.0
            needs_phonemes = not name.startswith("supertonic")
            if not needs_phonemes:
                gc.extra["lang"] = "es"
                gc.num_steps = 5

            def run(text, cb=None):
                # sherpa-onnx >= 2.0 ships no espeak-ng: Piper/Kokoro need external phonemes.
                if needs_phonemes:
                    from piper_phonemize import phonemize_espeak
                    gc.phoneme_codepoints = [[ord(c) for c in s] for s in phonemize_espeak(text, "es")]
                    text = ""
                return tts.generate(text, gc, cb) if cb else tts.generate(text, gc)

            run("Hola.")  # warm-up
            for i, text in enumerate(SENTENCES):
                first = [None]
                t = time.perf_counter()

                def cb(samples, progress, first=first, t=t):
                    if first[0] is None:
                        first[0] = time.perf_counter() - t
                    return 1

                audio = run(text, cb)
                if not audio.sample_rate:
                    print(f"  {name} sid={sid} s{i}: FAILED")
                    continue
                dt = time.perf_counter() - t
                dur = len(audio.samples) / audio.sample_rate
                fa = first[0] if first[0] is not None else dt
                print(f"  {name} sid={sid} s{i}: first_audio={fa*1000:.0f} ms total={dt*1000:.0f} ms "
                      f"audio={dur:.1f}s RTF={dt/dur:.3f}")
                sf.write(os.path.join(OUT, f"{name}-sid{sid}-s{i}.wav"), audio.samples, audio.sample_rate)


if __name__ == "__main__":
    what = sys.argv[1] if len(sys.argv) > 1 else "all"
    if what in ("stt", "all"):
        bench_stt()
    if what in ("tts", "all"):
        bench_tts()
