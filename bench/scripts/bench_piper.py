import time, wave, io, json, statistics, os, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from texts import SHORT, MEDIUM, LONG, STT_TEXT
from piper import PiperVoice, SynthesisConfig

MODELS = Path(r"C:/Dev/tools/tts/bench/models")
OUT = Path(r"C:/Dev/tools/tts/bench/out")
MODEL = MODELS / "en_US-lessac-medium.onnx"

t0 = time.perf_counter()
voice = PiperVoice.load(str(MODEL))
load_ms = (time.perf_counter() - t0) * 1000.0
sr = voice.config.sample_rate
print(f"loaded in {load_ms:.0f} ms, sample_rate={sr}")

syn = SynthesisConfig(normalize_audio=False)

def run_once(text, save_wav=None):
    t_start = time.perf_counter()
    first_chunk_t = None
    total_samples = 0
    pcm = bytearray()
    for chunk in voice.synthesize(text, syn_config=syn):
        if first_chunk_t is None:
            first_chunk_t = time.perf_counter()
        b = chunk.audio_int16_bytes
        pcm += b
        total_samples += len(b) // 2
    wall = time.perf_counter() - t_start
    first_audio_ms = (first_chunk_t - t_start) * 1000.0 if first_chunk_t else None
    audio_dur = total_samples / sr
    if save_wav:
        with wave.open(str(save_wav), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
            w.writeframes(bytes(pcm))
    return wall, audio_dur, first_audio_ms

results = {}
for name, text in [("short", SHORT), ("medium", MEDIUM), ("long", LONG)]:
    rtfs, fa, durs = [], [], []
    for i in range(3):
        save = OUT / f"piper_{name}.wav" if i == 2 else None
        wall, dur, first_ms = run_once(text, save)
        rtf = wall / dur
        if i > 0:  # discard warmup
            rtfs.append(rtf); fa.append(first_ms); durs.append(dur)
        print(f"  {name} run{i}: wall={wall:.3f}s dur={dur:.2f}s rtf={rtf:.4f} first_audio={first_ms:.0f}ms")
    results[name] = {
        "rtf_median": round(statistics.median(rtfs), 4),
        "first_audio_ms_median": round(statistics.median(fa), 1),
        "audio_dur_s": round(statistics.median(durs), 2),
    }

# Also synthesize the STT ground-truth sample for later STT legs
wall, dur, _ = run_once(STT_TEXT, OUT / "stt_sample.wav")
print(f"STT sample: {dur:.2f}s audio saved (synth wall {wall:.2f}s)")

out = {
    "load_ms": round(load_ms, 1),
    "sample_rate": sr,
    "model_size_mb": round(MODEL.stat().st_size / 1e6, 1),
    "per_length": results,
    "stt_sample_dur_s": round(dur, 2),
}
print("RESULT_JSON=" + json.dumps(out))
