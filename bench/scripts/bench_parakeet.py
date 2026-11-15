import time, json, wave, sys, statistics
from pathlib import Path
import numpy as np
import sherpa_onnx

BUNDLE = Path(r"C:/Dev/tools/tts/bench/models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8")
SAMPLE = Path(r"C:/Dev/tools/tts/bench/out/stt_sample_16k.wav")
NUM_THREADS = 8

with wave.open(str(SAMPLE), "rb") as w:
    sr = w.getframerate()
    n = w.getnframes()
    raw = w.readframes(n)
audio_dur = n / sr
samples = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
print(f"audio: {audio_dur:.2f}s @ {sr}Hz, {len(samples)} samples")

def build():
    return sherpa_onnx.OfflineRecognizer.from_transducer(
        encoder=str(BUNDLE / "encoder.int8.onnx"),
        decoder=str(BUNDLE / "decoder.int8.onnx"),
        joiner=str(BUNDLE / "joiner.int8.onnx"),
        tokens=str(BUNDLE / "tokens.txt"),
        num_threads=NUM_THREADS,
        model_type="nemo_transducer",
        decoding_method="greedy_search",
    )

t0 = time.perf_counter()
rec = build()
load_ms = (time.perf_counter() - t0) * 1000.0
print(f"loaded in {load_ms:.0f} ms")

def run_once():
    t = time.perf_counter()
    stream = rec.create_stream()
    stream.accept_waveform(sr, samples)
    rec.decode_stream(stream)
    wall = time.perf_counter() - t
    return wall, stream.result.text

rtfs = []
text = ""
for i in range(3):
    wall, text = run_once()
    rtf = wall / audio_dur
    if i > 0:
        rtfs.append(rtf)
    print(f"  run{i}: wall={wall:.3f}s rtf={rtf:.4f}")
print("transcript:", text[:300])

out = {
    "status": "ok", "load_ms": round(load_ms, 1),
    "audio_dur_s": round(audio_dur, 2),
    "rtf_median": round(statistics.median(rtfs), 4),
    "threads": NUM_THREADS,
    "transcript": text[:400],
}
print("RESULT_JSON=" + json.dumps(out))
