"""End-to-end latency spike: recorded Spanish utterance -> Silero VAD -> Parakeet v3
-> warm Claude Code session (stream-json, fake display MCP) -> first sentence ->
local TTS first audio.

All times are relative to the real end of speech in the wav (last voiced sample),
which is what the user perceives as "I stopped talking".

Usage: python e2e.py [--model opus] [--tts piper|supertonic] [--settings none|user]
"""

import argparse
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time

import numpy as np
import sherpa_onnx as so
import soundfile as sf

HERE = os.path.dirname(os.path.abspath(__file__))
M = os.path.join(HERE, "models")
LOG = "/tmp/displai_spike_mcp.log"
THREADS = 4

SYSTEM = """You are DisplAI, a voice-first desktop assistant. The user talks to you; there is no chat window.
Your words are spoken aloud by a TTS engine, and you have a display you control with the displai tools.
Rules:
- Speak little, show a lot. Start with ONE short spoken sentence (max ~12 words) so the user hears you quickly.
- Anything with structure (lists, options, tables, numbers to compare) goes on the display via the show tool.
- Never read aloud what you show. Refer to it ("te lo dejo en pantalla").
- Reply in the user's language. Plain text only: no markdown, no emojis, no lists in speech."""

SENTENCE = re.compile(r"[.!?…](\s|$)")


def wav16k(path):
    d, sr = sf.read(path, dtype="float32")
    assert sr == 16000
    return d


class Claude:
    def __init__(self, model, settings, tools="default"):
        cfg = {"mcpServers": {"displai": {"type": "stdio", "command": sys.executable,
                                          "args": ["-I", os.path.join(HERE, "fake_display_mcp.py")],
                                          "env": {"DISPLAI_SPIKE_LOG": LOG}}}}
        cfg_path = "/tmp/displai_spike_mcp.json"
        with open(cfg_path, "w") as f:
            json.dump(cfg, f)
        cmd = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json",
               "--include-partial-messages", "--verbose", "--append-system-prompt", SYSTEM,
               "--mcp-config", cfg_path, "--strict-mcp-config",
               "--allowedTools", "mcp__displai__show,mcp__displai__get_state",
               "--no-session-persistence", "--model", model]
        if tools == "none":
            cmd += ["--tools", ""]
        if settings == "none":
            cmd += ["--setting-sources", ""]
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
                                  stderr=subprocess.DEVNULL)
        self.q = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            try:
                self.q.put((time.time(), json.loads(line)))
            except json.JSONDecodeError:
                pass

    def ask(self, text, on_sentence):
        """Send a turn; call on_sentence(t, sentence) for the first complete sentence.
        Returns dict of epoch timestamps."""
        self.p.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": [
            {"type": "text", "text": text}]}}) + "\n")
        self.p.stdin.flush()
        ts = {"sent": time.time()}
        buf, spoken = "", False
        while True:
            t, ev = self.q.get(timeout=180)
            if ev.get("type") == "stream_event":
                e = ev["event"]
                if e.get("type") == "content_block_delta" and e["delta"].get("type") == "text_delta":
                    ts.setdefault("first_delta", t)
                    buf += e["delta"]["text"]
                    m = SENTENCE.search(buf)
                    if m and not spoken:
                        spoken = True
                        ts["first_sentence"] = t
                        on_sentence(buf[:m.end()].strip())
                elif e.get("type") == "content_block_start" and e["content_block"].get("type") == "tool_use":
                    ts.setdefault("first_tool_use_start", t)
            elif ev.get("type") == "result":
                ts["result"] = t
                ts["text"] = buf
                return ts


def tts_engine(kind):
    if kind == "piper":
        d = os.path.join(M, "vits-piper-es_ES-miro-high")
        tts = so.OfflineTts(so.OfflineTtsConfig(model=so.OfflineTtsModelConfig(
            vits=so.OfflineTtsVitsModelConfig(model=f"{d}/es_ES-miro-high.onnx", tokens=f"{d}/tokens.txt"),
            num_threads=THREADS)))
        from piper_phonemize import phonemize_espeak

        def speak(text):
            gc = so.GenerationConfig()
            gc.phoneme_codepoints = [[ord(c) for c in s] for s in phonemize_espeak(text, "es")]
            return tts.generate("", gc)
    else:
        d = os.path.join(M, "sherpa-onnx-supertonic-3-tts-int8-2026-05-11")
        tts = so.OfflineTts(so.OfflineTtsConfig(model=so.OfflineTtsModelConfig(
            supertonic=so.OfflineTtsSupertonicModelConfig(
                duration_predictor=f"{d}/duration_predictor.int8.onnx", text_encoder=f"{d}/text_encoder.int8.onnx",
                vector_estimator=f"{d}/vector_estimator.int8.onnx", vocoder=f"{d}/vocoder.int8.onnx",
                tts_json=f"{d}/tts.json", unicode_indexer=f"{d}/unicode_indexer.bin",
                voice_style=f"{d}/voice.bin"),
            num_threads=THREADS)))

        def speak(text):
            gc = so.GenerationConfig()
            gc.sid, gc.speed, gc.num_steps = 6, 1.2, 5
            gc.extra["lang"] = "es"
            return tts.generate(text, gc)
    speak("Hola.")
    return speak


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="opus")
    ap.add_argument("--tts", default="piper")
    ap.add_argument("--settings", default="none")
    ap.add_argument("--tools", default="default")
    a = ap.parse_args()

    p = os.path.join(M, "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8")
    asr = so.OfflineRecognizer.from_transducer(
        encoder=f"{p}/encoder.int8.onnx", decoder=f"{p}/decoder.int8.onnx", joiner=f"{p}/joiner.int8.onnx",
        tokens=f"{p}/tokens.txt", num_threads=THREADS, model_type="nemo_transducer")
    speak = tts_engine(a.tts)
    claude = Claude(a.model, a.settings, a.tools)
    # warm the session (first turn pays process + prompt cache creation)
    claude.ask("Hola, esto es una prueba de calentamiento. Responde solo: listo.", lambda s: None)

    vcfg = so.VadModelConfig()
    vcfg.silero_vad.model = os.path.join(M, "silero_vad_v5.onnx")
    vcfg.silero_vad.min_silence_duration = 0.3
    vcfg.sample_rate = 16000
    win = vcfg.silero_vad.window_size

    print(f"model={a.model} tts={a.tts} settings={a.settings} tools={a.tools}")
    rows = []
    for w in sorted(f for f in os.listdir(os.path.join(HERE, "audio")) if f.startswith("e2e")):
        samples = wav16k(os.path.join(HERE, "audio", w))
        voiced = np.nonzero(np.abs(samples) > 0.01)[0]
        speech_end_idx = voiced[-1] if len(voiced) else len(samples)
        vad = so.VoiceActivityDetector(vcfg, buffer_size_in_seconds=30)
        padded = np.concatenate([samples, np.zeros(16000, dtype=np.float32)])
        # Feed audio in real time (as a mic would) so the VAD close time is realistic.
        t_start = time.time()
        seg = None
        for i in range(0, len(padded) - win, win):
            target = t_start + (i + win) / 16000
            delay = target - time.time()
            if delay > 0:
                time.sleep(delay)
            vad.accept_waveform(padded[i:i + win])
            if not vad.empty():
                seg = np.array(vad.front.samples, dtype=np.float32)
                vad.pop()
                break
        t_speech_end = t_start + speech_end_idx / 16000
        t_vad = time.time()
        st = asr.create_stream()
        st.accept_waveform(16000, seg)
        asr.decode_stream(st)
        text = st.result.text
        t_stt = time.time()

        audio_ready = {}

        def on_sentence(sentence):
            r = speak(sentence)
            audio_ready["t"] = time.time()
            audio_ready["s"] = sentence

        open(LOG, "w").close()
        ts = claude.ask(text, on_sentence)
        show_t = None
        with open(LOG) as f:
            for line in f:
                ev = json.loads(line)
                if ev["tool"] == "show":
                    show_t = ev["t"]
                    break
        # first_sentence timestamp excludes the TTS time spent inside on_sentence
        rel = lambda t: (t - t_speech_end) * 1000 if t else float("nan")
        row = dict(vad=rel(t_vad), stt=rel(t_stt), delta=rel(ts.get("first_delta")),
                   sentence=rel(ts.get("first_sentence")), voice=rel(audio_ready.get("t")),
                   tool_start=rel(ts.get("first_tool_use_start")), show=rel(show_t), done=rel(ts["result"]))
        rows.append(row)
        print(f" {w}: heard={text!r}")
        print(f"   said={audio_ready.get('s')!r}")
        print("   " + "  ".join(f"{k}={v:.0f}ms" for k, v in row.items()))
    keys = rows[0].keys()
    med = {k: float(np.nanmedian([r[k] for r in rows])) for k in keys}
    print(" MEDIAN " + "  ".join(f"{k}={v:.0f}ms" for k, v in med.items()))
    claude.p.stdin.close()


if __name__ == "__main__":
    main()
