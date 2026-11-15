import time, json, statistics, sys, asyncio
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from texts import SHORT, MEDIUM, LONG
import soundfile as sf
from kokoro_onnx import Kokoro

MODELS = Path(r"C:/Dev/tools/tts/bench/models")
OUT = Path(r"C:/Dev/tools/tts/bench/out")
MODEL = MODELS / "kokoro-v1.0.int8.onnx"
VOICES = MODELS / "voices-v1.0.bin"
VOICE = "af_sarah"

t0 = time.perf_counter()
kok = Kokoro(str(MODEL), str(VOICES))
load_ms = (time.perf_counter() - t0) * 1000.0
print(f"loaded in {load_ms:.0f} ms")

def run_once(text, save=None):
    t = time.perf_counter()
    samples, sr = kok.create(text, voice=VOICE, speed=1.0, lang="en-us")
    wall = time.perf_counter() - t
    dur = len(samples) / sr
    if save:
        sf.write(str(save), samples, sr)
    return wall, dur, sr

async def first_audio_ms(text):
    t = time.perf_counter()
    agen = kok.create_stream(text, voice=VOICE, speed=1.0, lang="en-us")
    async for samples, sr in agen:
        return (time.perf_counter() - t) * 1000.0
    return None

results = {}
sr_seen = None
for name, text in [("short", SHORT), ("medium", MEDIUM), ("long", LONG)]:
    rtfs, durs = [], []
    for i in range(3):
        save = OUT / f"kokoro_{name}.wav" if i == 2 else None
        wall, dur, sr = run_once(text, save)
        sr_seen = sr
        rtf = wall / dur
        if i > 0:
            rtfs.append(rtf); durs.append(dur)
        print(f"  {name} run{i}: wall={wall:.3f}s dur={dur:.2f}s rtf={rtf:.4f}")
    fa = asyncio.run(first_audio_ms(text))
    print(f"  {name} first_audio (stream) = {fa:.0f} ms")
    results[name] = {
        "rtf_median": round(statistics.median(rtfs), 4),
        "first_audio_ms_stream": round(fa, 1),
        "audio_dur_s": round(statistics.median(durs), 2),
    }

out = {
    "load_ms": round(load_ms, 1),
    "sample_rate": sr_seen,
    "model_size_mb": round(MODEL.stat().st_size / 1e6, 1),
    "voice": VOICE,
    "per_length": results,
}
print("RESULT_JSON=" + json.dumps(out))
