import time, json, wave, sys, statistics
from pathlib import Path
import numpy as np

BENCH = Path(__file__).resolve().parents[1]  # the bench/ folder, wherever the repo is
MODELS = BENCH / "models/ov-whisper-base-int8"
SAMPLE = BENCH / "out/stt_sample_16k.wav"

import openvino as ov
import openvino_genai as ov_genai
print("openvino:", ov.__version__)
core = ov.Core()
avail = core.available_devices
print("available_devices:", avail)
dev_names = {}
for d in avail:
    try:
        dev_names[d] = core.get_property(d, "FULL_DEVICE_NAME")
    except Exception as e:
        dev_names[d] = f"<err {e}>"
print("device names:", dev_names)

with wave.open(str(SAMPLE), "rb") as w:
    sr = w.getframerate(); n = w.getnframes(); raw = w.readframes(n)
audio_dur = n / sr
speech = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
print(f"audio: {audio_dur:.2f}s @ {sr}Hz")

def bench_device(device):
    res = {"device": device, "device_name": dev_names.get(device, "n/a")}
    try:
        t0 = time.perf_counter()
        pipe = ov_genai.WhisperPipeline(str(MODELS), device)
        compile_ms = (time.perf_counter() - t0) * 1000.0
        res["compile_ms"] = round(compile_ms, 1)
        print(f"[{device}] compiled/loaded in {compile_ms:.0f} ms")
        rtfs, text = [], ""
        for i in range(3):
            t = time.perf_counter()
            out = pipe.generate(speech, language="<|en|>", task="transcribe")
            wall = time.perf_counter() - t
            text = str(out)
            rtf = wall / audio_dur
            if i > 0:
                rtfs.append(rtf)
            print(f"  [{device}] run{i}: wall={wall:.3f}s rtf={rtf:.4f}")
        res["rtf_median"] = round(statistics.median(rtfs), 4)
        res["transcript"] = text[:300]
        res["status"] = "ok"; res["error"] = None
    except Exception as e:
        res["status"] = "failed"; res["error"] = f"{type(e).__name__}: {str(e)[:500]}"
        print(f"[{device}] FAILED: {res['error']}")
    return res

results = {"openvino_version": ov.__version__, "available_devices": avail,
           "device_names": dev_names, "audio_dur_s": round(audio_dur, 2),
           "model": "OpenVINO/whisper-base-int8-ov", "runs": []}
for device in ["CPU", "GPU", "NPU"]:
    if device not in avail:
        print(f"[{device}] not in available_devices -> skipping")
        results["runs"].append({"device": device, "status": "skipped",
                                "error": "device not present in core.available_devices"})
        continue
    results["runs"].append(bench_device(device))

print("RESULT_JSON=" + json.dumps(results))
