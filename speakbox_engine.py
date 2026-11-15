"""SpeakBox neural voice engine (Piper + Kokoro), driven over stdin/stdout.

One JSON object per line in, one per line out. SpeakBox.ps1 starts this once
and keeps it warm, so models load only the first time a voice is used.

In:
  {"cmd":"voices"}
  {"cmd":"synth","id":7,"gen":3,"engine":"piper","voice":"en_GB-alan-medium",
   "text":"Hello.","speed":1.2,"out":"C:/.../7.wav"}
  {"cmd":"flush","gen":4}      drop queued synth requests older than gen 4
  {"cmd":"quit"}
Out:
  {"ready":true}
  {"voices":[{"engine":"piper","id":"...","label":"..."}, ...]}
  {"id":7,"ok":true,"out":"...","dur":1.93}
  {"id":7,"ok":false,"error":"..."}       (also sent for dropped requests)
"""
import json
import queue
import sys
import threading
import traceback
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def first_existing(*relative):
    """First path that exists; else the first (standard) one. Same order as SpeakBox.ps1."""
    paths = [ROOT / r for r in relative]
    return next((p for p in paths if p.exists()), paths[0])


PIPER_DIR = ROOT / "voices" / "piper"
# fp32, not int8: the int8 model measured ~2x SLOWER on CPU (quantize/dequantize overhead).
KOKORO_MODEL = first_existing("models/kokoro-v1.0.onnx", "models/kokoro-v1.0.fp32.onnx",
                              "bench/models/kokoro-v1.0.fp32.onnx")
KOKORO_VOICES = first_existing("models/voices-v1.0.bin", "bench/models/voices-v1.0.bin")
LOG = ROOT / "speakbox-engine.log"

KOKORO_NAMES = {
    "af": "US female", "am": "US male", "bf": "British female", "bm": "British male",
}

sys.stdout.reconfigure(encoding="utf-8")

_out_lock = threading.Lock()


def send(obj):
    with _out_lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


def log(msg):
    try:
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(msg.rstrip() + "\n")
    except OSError:
        pass


def list_voices():
    voices = []
    for onnx in sorted(PIPER_DIR.glob("*.onnx")):
        if not onnx.with_suffix(".onnx.json").exists():
            continue
        # en_GB-northern_english_male-medium -> "en_GB northern english male (medium)"
        parts = onnx.stem.split("-")
        lang, name, quality = (parts + ["", "", ""])[:3]
        voices.append({"engine": "piper", "id": onnx.stem,
                       "label": f"{lang} {name.replace('_', ' ')} ({quality})"})
    if KOKORO_MODEL.exists() and KOKORO_VOICES.exists():
        try:
            import numpy as np
            names = sorted(np.load(str(KOKORO_VOICES)).keys())
        except Exception as e:  # noqa: BLE001 - report, keep Piper usable
            log(f"kokoro voice list failed: {e}")
            names = []
        for n in names:
            prefix = n[:2]
            if prefix in KOKORO_NAMES:  # English voices only
                voices.append({"engine": "kokoro", "id": n,
                               "label": f"{n.split('_', 1)[1]} ({KOKORO_NAMES[prefix]})"})
    return voices


_piper = {}
_kokoro = None


def piper_voice(vid):
    if vid not in _piper:
        from piper import PiperVoice
        path = PIPER_DIR / f"{vid}.onnx"
        if not path.exists():
            raise FileNotFoundError(f"piper voice not found: {vid}")
        _piper[vid] = PiperVoice.load(str(path))
    return _piper[vid]


def kokoro():
    global _kokoro
    if _kokoro is None:
        from kokoro_onnx import Kokoro
        _kokoro = Kokoro(str(KOKORO_MODEL), str(KOKORO_VOICES))
    return _kokoro


def write_wav(path, pcm16: bytes, rate: int):
    tmp = Path(str(path) + ".part")
    with wave.open(str(tmp), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm16)
    tmp.replace(path)  # atomic: SpeakBox never sees a half-written file
    return len(pcm16) / 2 / rate


def synth(req):
    text = req["text"].strip()
    speed = min(max(float(req.get("speed", 1.0)), 0.5), 2.0)
    out = req["out"]
    if req["engine"] == "piper":
        from piper import SynthesisConfig
        v = piper_voice(req["voice"])
        cfg = SynthesisConfig(length_scale=1.0 / speed)
        pcm = b"".join(c.audio_int16_bytes for c in v.synthesize(text, syn_config=cfg))
        if not pcm:
            raise ValueError("no audio produced")
        return write_wav(out, pcm, v.config.sample_rate)
    if req["engine"] == "kokoro":
        import numpy as np
        vid = req["voice"]
        lang = "en-gb" if vid.startswith("b") else "en-us"
        samples, sr = kokoro().create(text, voice=vid, speed=speed, lang=lang)
        pcm = (np.clip(samples, -1.0, 1.0) * 32767).astype("<i2").tobytes()
        if not pcm:
            raise ValueError("no audio produced")
        return write_wav(out, pcm, sr)
    raise ValueError(f"unknown engine: {req['engine']}")


# A reader thread queues requests so a "flush" can overtake synth work that is
# still waiting. Without it, seeking would wait for every stale sentence ahead.
_q = queue.Queue()
_min_gen = 0
_gen_lock = threading.Lock()


def reader(src):
    global _min_gen
    for line in src:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except json.JSONDecodeError as e:
            log(f"bad json: {e}: {line[:200]}")
            continue
        cmd = req.get("cmd")
        if cmd == "flush":
            with _gen_lock:
                _min_gen = max(_min_gen, int(req.get("gen", 0)))
        else:
            _q.put(req)
    _q.put({"cmd": "quit"})  # stdin closed: SpeakBox exited


def detach_stdin():
    """Give the reader thread a private handle to the request pipe.

    On Windows, synchronous I/O on one pipe handle is serialized: while the
    reader thread sits in a blocking read, any other call that touches stdin
    (libraries probing isatty/GetFileType while loading models) blocks too, so
    the first synth hung forever. Point fd 0 / sys.stdin at NUL for everyone
    else and keep the real pipe on a duplicated descriptor.
    """
    import os
    pipe_fd = os.dup(0)
    nul = os.open(os.devnull, os.O_RDONLY)
    os.dup2(nul, 0)
    os.close(nul)
    sys.stdin = open(os.devnull, encoding="utf-8")
    return os.fdopen(pipe_fd, "r", encoding="utf-8")


def main():
    src = detach_stdin()
    threading.Thread(target=reader, args=(src,), daemon=True).start()
    send({"ready": True})
    while True:
        req = _q.get()
        cmd = req.get("cmd")
        if cmd == "quit":
            return
        if cmd == "voices":
            send({"voices": list_voices()})
            continue
        if cmd != "synth":
            continue
        with _gen_lock:
            stale = int(req.get("gen", 0)) < _min_gen
        if stale:
            send({"id": req.get("id"), "ok": False, "error": "dropped"})
            continue
        try:
            dur = synth(req)
            send({"id": req.get("id"), "ok": True, "out": req["out"], "dur": round(dur, 3)})
        except Exception as e:  # noqa: BLE001 - one bad sentence must not kill the engine
            log(traceback.format_exc())
            send({"id": req.get("id"), "ok": False, "error": str(e)[:300]})


if __name__ == "__main__":
    main()
