import time, json, statistics, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from texts import SHORT, MEDIUM
import soundfile as sf
from kokoro_onnx import Kokoro

BENCH = Path(__file__).resolve().parents[1]  # the bench/ folder, wherever the repo is
MODELS = BENCH / "models"
OUT = BENCH / "out"
MODEL = MODELS / "kokoro-v1.0.fp32.onnx"
VOICES = MODELS / "voices-v1.0.bin"
VOICE = "af_sarah"

t0 = time.perf_counter()
kok = Kokoro(str(MODEL), str(VOICES))
load_ms = (time.perf_counter() - t0) * 1000.0
print(f"loaded fp32 in {load_ms:.0f} ms")

def run_once(text, save=None):
    t = time.perf_counter()
    samples, sr = kok.create(text, voice=VOICE, speed=1.0, lang="en-us")
    wall = time.perf_counter() - t
    if save:
        sf.write(str(save), samples, sr)
    return wall, len(samples) / sr

results = {}
for name, text in [("short", SHORT), ("medium", MEDIUM)]:
    rtfs, durs = [], []
    for i in range(3):
        save = OUT / f"kokoro_fp32_{name}.wav" if i == 2 else None
        wall, dur = run_once(text, save)
        rtf = wall / dur
        if i > 0:
            rtfs.append(rtf); durs.append(dur)
        print(f"  {name} run{i}: wall={wall:.3f}s dur={dur:.2f}s rtf={rtf:.4f}")
    results[name] = {"rtf_median": round(statistics.median(rtfs), 4),
                     "audio_dur_s": round(statistics.median(durs), 2)}

out = {"load_ms": round(load_ms, 1),
       "model_size_mb": round(MODEL.stat().st_size / 1e6, 1),
       "per_length": results}
print("RESULT_JSON=" + json.dumps(out))
