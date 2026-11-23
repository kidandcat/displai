"""Live voice loop on the real Mac: mic -> Silero VAD -> Parakeet v3 -> warm Claude Code
(stream-json) -> Supertonic 3 sentence-by-sentence -> speakers.

Full duplex with barge-in: audio goes through the `audioio` helper, which uses macOS
voice processing (echo cancellation), so the mic stays open while the assistant speaks.
If the user talks over it, playback stops and the Claude turn is interrupted
(stream-json control_request "interrupt"); the new utterance becomes the next turn.

Usage: python live.py [--model opus] [--minutes 15]
       python live.py --echo-test   (speak a sample and report what the mic hears)
"""

import argparse
import json
import os
import queue
import re
import struct
import subprocess
import tempfile
import threading
import time

import numpy as np
import sherpa_onnx as so

HERE = os.path.dirname(os.path.abspath(__file__))
M = os.path.join(HERE, "models")
SR = 16000
AUDIOIO = os.path.join(HERE, "audioio", "audioio")
BARGE_IN_SECONDS = 0.3  # continuous speech needed to interrupt the assistant
# If the user resumes talking this soon after the assistant started answering, the previous
# utterance was a mid-sentence pause, not the end of the turn: merge both into one turn.
CONTINUATION_SECONDS = 2.0

SYSTEM = """You are DisplAI, a voice-first assistant running on the user's Mac. The user talks to you; there is no chat window.
Everything you write is spoken aloud by a TTS engine, sentence by sentence.
Rules:
- Start with ONE short sentence (max ~12 words) so the user hears you quickly.
- Keep answers short: one to three sentences unless asked for more.
- Reply in Spanish unless the user clearly speaks another language. Plain text only: no markdown, no emojis, no lists, no URLs.
- Write numbers and times the way they should be read aloud.
- The user can interrupt you at any time by talking; if a message looks cut or odd, it is a speech-to-text error: ask briefly.
- This is an early voice test: you have no tools and no display yet. Do not talk about files, code or this program."""

SENTENCE = re.compile(r"[.!?…:;](\s|$)")


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, flush=True)


class AudioIO:
    """Echo-cancelled mic in + speaker out through the native helper."""

    def __init__(self, play_rate):
        self.p = subprocess.Popen([AUDIOIO, str(play_rate)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE)
        self.mic_q = queue.Queue()
        self.playing = False
        self.ready = threading.Event()
        self.wlock = threading.Lock()
        threading.Thread(target=self._read_mic, daemon=True).start()
        threading.Thread(target=self._read_events, daemon=True).start()
        if not self.ready.wait(10):
            raise RuntimeError("audioio did not start")

    def _read_mic(self):
        while True:
            data = self.p.stdout.read(512 * 4)
            if not data:
                return
            self.mic_q.put((time.time(), np.frombuffer(data, dtype=np.float32)))

    def _read_events(self):
        for line in self.p.stderr:
            line = line.decode(errors="replace").strip()
            if not line.startswith("EV "):
                continue
            ev = line[3:]
            if ev.startswith("ready"):
                log("audio:", ev)
                self.ready.set()
            elif ev == "idle":
                self.playing = False
            elif ev.startswith("error"):
                log("audio", ev)

    def play(self, samples):
        samples = np.ascontiguousarray(samples, dtype=np.float32)
        with self.wlock:
            self.playing = True
            self.p.stdin.write(struct.pack("<II", 1, len(samples)) + samples.tobytes())
            self.p.stdin.flush()

    def stop(self):
        with self.wlock:
            self.p.stdin.write(struct.pack("<II", 2, 0))
            self.p.stdin.flush()
        self.playing = False


class Speaker:
    """Synthesizes sentences in order and queues them for playback; can be cut off."""

    def __init__(self):
        d = os.path.join(M, "sherpa-onnx-supertonic-3-tts-int8-2026-05-11")
        self.tts = so.OfflineTts(so.OfflineTtsConfig(model=so.OfflineTtsModelConfig(
            supertonic=so.OfflineTtsSupertonicModelConfig(
                duration_predictor=f"{d}/duration_predictor.int8.onnx", text_encoder=f"{d}/text_encoder.int8.onnx",
                vector_estimator=f"{d}/vector_estimator.int8.onnx", vocoder=f"{d}/vocoder.int8.onnx",
                tts_json=f"{d}/tts.json", unicode_indexer=f"{d}/unicode_indexer.bin",
                voice_style=f"{d}/voice.bin"),
            num_threads=4)))
        self.gc = so.GenerationConfig()
        self.gc.sid, self.gc.speed, self.gc.num_steps = 6, 1.2, 5
        self.gc.extra["lang"] = "es"
        self.tts.generate(".", self.gc)  # warm-up
        self.audio = AudioIO(self.tts.sample_rate)
        self.text_q = queue.Queue()
        self.gen = 0
        self.synthesizing = 0
        self.first_audio_at = None
        threading.Thread(target=self._synth_loop, daemon=True).start()

    @property
    def active(self):
        return self.synthesizing > 0 or self.audio.playing

    def say(self, text):
        self.synthesizing += 1
        self.text_q.put((self.gen, text))

    def stop(self):
        self.gen += 1
        self.audio.stop()

    def _synth_loop(self):
        while True:
            gen, text = self.text_q.get()
            try:
                if gen != self.gen:
                    continue
                a = self.tts.generate(text, self.gc)
                if gen != self.gen:
                    continue
                if self.first_audio_at is None:
                    self.first_audio_at = time.time()
                log(f"  🔊 {text}")
                self.audio.play(np.array(a.samples, dtype=np.float32))
            finally:
                self.synthesizing -= 1

    def tick(self):
        sr = self.tts.sample_rate
        t = np.arange(int(0.06 * sr)) / sr
        self.audio.play((0.08 * np.sin(2 * np.pi * 880 * t) * np.exp(-t * 60)).astype(np.float32))


class Claude:
    def __init__(self, model, on_sentence):
        self.cwd = tempfile.mkdtemp(prefix="displai-")
        cmd = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json",
               "--include-partial-messages", "--verbose", "--append-system-prompt", SYSTEM,
               "--no-session-persistence", "--setting-sources", "", "--strict-mcp-config", "--tools", "",
               "--model", model]
        self.p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
                                  stderr=subprocess.DEVNULL, cwd=self.cwd)
        self.on_sentence = on_sentence
        self.busy = False
        self.discard = False
        self.first_delta_at = None
        self.done = threading.Event()
        self.buf = ""
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if ev.get("type") == "stream_event":
                e = ev["event"]
                if e.get("type") == "content_block_delta" and e["delta"].get("type") == "text_delta":
                    if self.discard:
                        continue
                    if self.first_delta_at is None:
                        self.first_delta_at = time.time()
                    self.buf += e["delta"]["text"]
                    while (m := SENTENCE.search(self.buf)):
                        s, self.buf = self.buf[:m.end()].strip(), self.buf[m.end():]
                        if s:
                            self.on_sentence(s)
            elif ev.get("type") == "result":
                if self.buf.strip() and not self.discard:
                    self.on_sentence(self.buf.strip())
                self.buf = ""
                self.busy = False
                self.discard = False
                self.done.set()

    def ask(self, text):
        # an interrupted turn closes within a few ms; wait for it before the next one
        for _ in range(100):
            if not self.busy:
                break
            time.sleep(0.01)
        self.busy = True
        self.first_delta_at = None
        self.done.clear()
        self.p.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": [
            {"type": "text", "text": text}]}}) + "\n")
        self.p.stdin.flush()

    def interrupt(self):
        if not self.busy:
            return
        self.discard = True
        self.buf = ""
        self.p.stdin.write(json.dumps({"type": "control_request", "request_id": f"i{time.time()}",
                                       "request": {"subtype": "interrupt"}}) + "\n")
        self.p.stdin.flush()


def make_vad():
    vcfg = so.VadModelConfig()
    vcfg.silero_vad.model = os.path.join(M, "silero_vad_v5.onnx")
    vcfg.silero_vad.min_silence_duration = 0.4
    vcfg.silero_vad.min_speech_duration = 0.25
    vcfg.silero_vad.threshold = 0.5
    vcfg.sample_rate = SR
    return vcfg, so.VoiceActivityDetector(vcfg, buffer_size_in_seconds=60)


def echo_test():
    """Play a long sentence and report whether the VAD hears it through the mic."""
    speaker = Speaker()
    vcfg, vad = make_vad()
    win = vcfg.silero_vad.window_size
    time.sleep(1.0)
    while not speaker.audio.mic_q.empty():
        speaker.audio.mic_q.get()
    speaker.say("Esto es una prueba de cancelación de eco. Si todo va bien, el micrófono no debería oír esta voz, "
                "aunque suene por los altavoces del Mac.")
    t0 = time.time()
    buf, windows, speech_windows, peak_rms, longest, run = np.zeros(0, np.float32), 0, 0, 0.0, 0, 0
    while time.time() - t0 < 1.0 or speaker.active:
        _, chunk = speaker.audio.mic_q.get()
        peak_rms = max(peak_rms, float(np.sqrt(np.mean(chunk ** 2))))
        buf = np.concatenate([buf, chunk])
        while len(buf) >= win:
            vad.accept_waveform(buf[:win])
            buf = buf[win:]
            windows += 1
            sp = vad.is_speech_detected()
            speech_windows += int(sp)
            run = run + 1 if sp else 0
            longest = max(longest, run)
    log(f"echo test: {speech_windows}/{windows} VAD windows flagged speech while playing; "
        f"longest run {longest * win / SR:.2f}s (barge-in needs {BARGE_IN_SECONDS}s); max chunk rms {peak_rms:.4f}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="opus")
    ap.add_argument("--minutes", type=float, default=15)
    ap.add_argument("--echo-test", action="store_true")
    a = ap.parse_args()
    if a.echo_test:
        return echo_test()

    p = os.path.join(M, "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8")
    asr = so.OfflineRecognizer.from_transducer(
        encoder=f"{p}/encoder.int8.onnx", decoder=f"{p}/decoder.int8.onnx", joiner=f"{p}/joiner.int8.onnx",
        tokens=f"{p}/tokens.txt", num_threads=4, model_type="nemo_transducer")
    speaker = Speaker()
    claude = Claude(a.model, lambda s: None)
    claude.ask("Hola. Responde solo: listo.")
    claude.done.wait(60)
    claude.on_sentence = speaker.say

    vcfg, vad = make_vad()
    win = vcfg.silero_vad.window_size
    mic_q = speaker.audio.mic_q
    while not mic_q.empty():
        mic_q.get()

    deadline = time.time() + a.minutes * 60
    log(f"READY (model={a.model}). Habla cuando quieras; puedes interrumpirle. Di 'adiós' para terminar.")
    buf = np.zeros(0, dtype=np.float32)
    speech_run = 0  # consecutive VAD windows with speech
    barged = False
    pending_turn = None  # (t_end, t_stt) of the turn being answered, for timing
    last_text, carry = "", ""
    while time.time() < deadline:
        _, chunk = mic_q.get()
        buf = np.concatenate([buf, chunk])
        while len(buf) >= win:
            vad.accept_waveform(buf[:win])
            buf = buf[win:]
            speech_run = speech_run + 1 if vad.is_speech_detected() else 0
            busy = claude.busy or speaker.active
            if busy and not barged and speech_run * win / SR >= BARGE_IN_SECONDS:
                barged = True
                fa = speaker.first_audio_at
                continuation = fa is None or time.time() - fa < CONTINUATION_SECONDS
                speaker.stop()
                claude.interrupt()
                pending_turn = None
                carry = last_text if continuation else ""
                log("  ✋ interrumpido" + (" (sigues hablando: junto las frases)" if continuation else ""))

        if pending_turn and speaker.first_audio_at:
            t_end, t_stt = pending_turn
            fd = claude.first_delta_at or speaker.first_audio_at
            log(f"  ⏱  stt={1000*(t_stt-t_end):.0f}ms  claude_1st_token={1000*(fd-t_end):.0f}ms  "
                f"primera_voz={1000*(speaker.first_audio_at-t_end):.0f}ms (desde fin de habla)")
            pending_turn = None

        if vad.empty():
            continue
        t_vad = time.time()
        seg = np.array(vad.front.samples, dtype=np.float32)
        vad.pop()
        was_barge_in, barged = barged, False
        if (claude.busy or speaker.active) and not was_barge_in:
            log(f"  (ignorado: {len(seg)/SR:.1f}s de audio mientras hablaba, sin llegar a interrumpir)")
            continue
        st = asr.create_stream()
        st.accept_waveform(SR, seg)
        asr.decode_stream(st)
        text = st.result.text.strip()
        t_stt = time.time()
        t_end = t_vad - vcfg.silero_vad.min_silence_duration  # VAD closes min_silence after speech ends
        if not text:
            log("  (nada reconocido)")
            continue
        if carry:
            text, carry = f"{carry} {text}", ""
        last_text = text
        speaker.tick()
        log(f"🎤 {text}   [{len(seg)/SR:.1f}s de voz]")
        if re.sub(r"[^a-záéíóú]", "", text.lower()) in ("adiós", "adios"):
            speaker.say("Hasta luego.")
            break
        speaker.first_audio_at = None
        pending_turn = (t_end, t_stt)
        claude.ask(text)
    while speaker.active:
        time.sleep(0.1)
    log("FIN")


if __name__ == "__main__":
    main()
