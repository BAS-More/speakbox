import time, json, sys, wave
from pathlib import Path
from faster_whisper import WhisperModel

BENCH = Path(__file__).resolve().parents[1]  # the bench/ folder, wherever the repo is
OUT = BENCH / "out"
SAMPLE = OUT / "stt_sample.wav"
MODELS_DIR = BENCH / "models/fw"
MODELS_DIR.mkdir(parents=True, exist_ok=True)

with wave.open(str(SAMPLE), "rb") as w:
    audio_dur = w.getnframes() / w.getframerate()
print(f"audio duration = {audio_dur:.2f}s")

def bench(model_name):
    try:
        t0 = time.perf_counter()
        model = WhisperModel(model_name, device="cpu", compute_type="int8",
                             download_root=str(MODELS_DIR))
        load_ms = (time.perf_counter() - t0) * 1000.0
        rtfs, text_out = [], ""
        for i in range(3):
            t = time.perf_counter()
            segments, info = model.transcribe(str(SAMPLE), beam_size=5)
            text = " ".join(s.text for s in segments)  # generator -> force compute
            wall = time.perf_counter() - t
            rtf = wall / audio_dur
            if i > 0:
                rtfs.append(rtf)
            else:
                text_out = text.strip()
            print(f"  {model_name} run{i}: wall={wall:.3f}s rtf={rtf:.4f}")
        import statistics
        return {"status": "ok", "load_ms": round(load_ms, 1),
                "rtf_median": round(statistics.median(rtfs), 4),
                "transcript": text_out[:400], "error": None}
    except Exception as e:
        print(f"  {model_name} FAILED: {e}")
        return {"status": "failed", "error": str(e)[:300]}

results = {}
for m in ["small", "large-v3-turbo"]:
    print(f"=== {m} ===")
    results[m] = bench(m)

out = {"audio_dur_s": round(audio_dur, 2), "models": results}
print("RESULT_JSON=" + json.dumps(out))
