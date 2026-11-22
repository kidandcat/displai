"""Measure Claude Code headless stream-json latency and interrupt behaviour.

Starts one persistent `claude -p --input-format stream-json` process, sends a
few short Spanish voice-style prompts and records, per turn:
  - time to first text delta (TTFT)
  - time to the end of the first sentence (what TTS needs to start speaking)
  - time to the `result` message
Then starts a long turn and sends a `control_request` interrupt mid-stream.

Usage: python claude_latency.py [--model sonnet] [--bare] [--turns 3]
"""

import argparse
import json
import re
import subprocess
import sys
import threading
import time
import queue

SYSTEM = (
    "You are the voice of a desktop assistant. Answer in Spanish, in one or two "
    "short spoken sentences. No markdown, no lists."
)

PROMPTS = [
    "¿Qué hora es más o menos en Tokio si en Madrid son las diez de la mañana?",
    "Dame una idea rápida para cenar hoy.",
    "¿Cuántos días tiene un año bisiesto?",
    "Explícame en una frase qué es un agujero negro.",
]

SENTENCE_END = re.compile(r"[.!?¿¡…]\s|[.!?…]$")


def reader(proc, q):
    for line in proc.stdout:
        line = line.strip()
        if not line:
            continue
        try:
            q.put((time.perf_counter(), json.loads(line)))
        except json.JSONDecodeError:
            q.put((time.perf_counter(), {"type": "raw", "line": line}))
    q.put((time.perf_counter(), {"type": "eof"}))


def send(proc, obj):
    proc.stdin.write(json.dumps(obj) + "\n")
    proc.stdin.flush()


def user_msg(text):
    return {"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": text}]}}


def run_turn(proc, q, text, interrupt_after=None):
    t0 = time.perf_counter()
    send(proc, user_msg(text))
    first_delta = first_sentence = None
    buf = ""
    interrupted_at = None
    while True:
        t, ev = q.get(timeout=120)
        et = ev.get("type")
        if et == "stream_event":
            e = ev.get("event", {})
            if e.get("type") == "content_block_delta" and e.get("delta", {}).get("type") == "text_delta":
                if first_delta is None:
                    first_delta = t - t0
                buf += e["delta"]["text"]
                if first_sentence is None and SENTENCE_END.search(buf):
                    first_sentence = t - t0
                if interrupt_after and interrupted_at is None and len(buf) > interrupt_after:
                    interrupted_at = time.perf_counter()
                    send(proc, {"type": "control_request", "request_id": "int-1",
                                "request": {"subtype": "interrupt"}})
        elif et == "control_response":
            print(f"    control_response after {(t - interrupted_at)*1000:.0f} ms: {json.dumps(ev)[:200]}")
        elif et == "result":
            total = t - t0
            extra = ""
            if interrupted_at:
                extra = f" | result {(t - interrupted_at)*1000:.0f} ms after interrupt, subtype={ev.get('subtype')}"
            return first_delta, first_sentence, total, buf, extra
        elif et == "eof":
            raise RuntimeError("claude exited")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=None)
    ap.add_argument("--bare", action="store_true")
    ap.add_argument("--turns", type=int, default=3)
    a = ap.parse_args()

    cmd = ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json",
           "--include-partial-messages", "--verbose", "--append-system-prompt", SYSTEM,
           "--tools", "", "--no-session-persistence", "--setting-sources", ""]
    if a.model:
        cmd += ["--model", a.model]
    if a.bare:
        cmd += ["--bare"]

    t_spawn = time.perf_counter()
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr,
                            text=True, bufsize=1)
    q = queue.Queue()
    threading.Thread(target=reader, args=(proc, q), daemon=True).start()

    print(f"model={a.model or 'default'} bare={a.bare}")
    for i, p in enumerate(PROMPTS[: a.turns]):
        fd, fs, tot, text, _ = run_turn(proc, q, p)
        label = "cold" if i == 0 else "warm"
        if i == 0:
            print(f"  (spawn->first result {time.perf_counter() - t_spawn:.2f}s)")
        print(f"  turn{i} {label}: first_delta={fd*1000:.0f}ms first_sentence={fs*1000 if fs else -1:.0f}ms "
              f"total={tot*1000:.0f}ms :: {text[:80]!r}")

    print("  interrupt test:")
    fd, fs, tot, text, extra = run_turn(
        proc, q, "Cuéntame con mucho detalle la historia completa del Imperio Romano, al menos 600 palabras.",
        interrupt_after=40)
    print(f"    streamed {len(text)} chars before stop{extra}")
    fd, fs, tot, text, _ = run_turn(proc, q, "Vale, olvida eso. Di solo: listo.")
    print(f"    next turn after interrupt: first_delta={fd*1000:.0f}ms total={tot*1000:.0f}ms :: {text[:60]!r}")
    proc.stdin.close()
    proc.wait(timeout=20)


if __name__ == "__main__":
    main()
