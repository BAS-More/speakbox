# On-Device Speech Model Benchmark — Results

**Machine:** Intel Core Ultra 7 268V (Lunar Lake, 8C/8T) · Intel Arc 140V iGPU (16GB) · Intel AI Boost NPU · 32GB RAM · Windows 11 Pro · Python 3.13.9
**Date:** 2026-09-02 · All local, offline, no CUDA.
**Metric:** RTF = wall_seconds / audio_seconds (lower is better; <1 = faster than real time). Each config: 3 runs, first discarded (warmup), median reported.

> **Measurement caveat (important):** the box was under heavy background CPU load during the run (total CPU ~97%; Avi's stack of node/MCP servers, hooks, plus an open Task Manager). CPU-bound STT numbers (Leg 3 especially) showed large run-to-run variance and are therefore **conservative** — a quiet box would be faster. Piper (Leg 1) and the OpenVINO device comparison (Leg 5) were stable regardless.

## Summary table

| Leg | Engine | Model | Task | Device | RTF (median) | First audio / compile | Status |
|----|--------|-------|------|--------|-------------|----------------------|--------|
| 1 | Piper | en_US-lessac-medium | TTS | CPU | **0.18 / 0.10 / 0.10** (short/med/long) | first-audio 0.62 / 1.04 / 0.52 s | VERIFIED ok |
| 2 | Kokoro-82M | kokoro-v1.0 **int8** | TTS | CPU | **1.74 / 1.37 / 1.64** (short/med/long) | stream first-audio 6.0 / 32.5 / 54.4 s | VERIFIED ok (slow) |
| 2b | Kokoro-82M | kokoro-v1.0 **fp32** | TTS | CPU | **0.87 / 0.59** (short/med) | load 1.9 s | VERIFIED ok |
| 3 | faster-whisper | small INT8 | STT | CPU | **0.94** (beam=5) | load 18.0 s | VERIFIED ok |
| 3 | faster-whisper | large-v3-turbo INT8 | STT | CPU | **1.13** (beam=5) | load 58.1 s | VERIFIED ok |
| 4 | sherpa-onnx | Parakeet-TDT-0.6b-v3 int8 | STT | CPU | **0.17** | load 3.8 s | VERIFIED ok |
| 5 | openvino-genai | whisper-base int8 | STT | CPU | **0.073** | compile 1.4 s | VERIFIED ok |
| 5 | openvino-genai | whisper-base int8 | STT | **GPU (Arc 140V)** | **0.024** | compile 18.1 s | VERIFIED ok |
| 5 | openvino-genai | whisper-base int8 | STT | **NPU (AI Boost)** | **0.019** | compile 26.5 s | VERIFIED ok |
| 6 | OPUS-MT (CT2) | en→de (~148MB) | MT | CPU | **95 ms/sentence** (median; p90 123 ms; 10.2 sent/s) | load 0.6 s | VERIFIED ok |

STT sample = 29.08 s of clean speech synthesized from a known paragraph via Piper (ground truth). All STT transcripts were essentially perfect (WER ~0).

## Findings

### 1. Is CPU-only TTS fast enough? — YES, decisively (with Piper).
**Piper** on CPU hits **RTF ~0.10-0.18** (roughly 6-10x faster than real time) and streams the first audio chunk in **~0.5-1.0 s**. That is comfortably fast enough for SpeakBox's current TTS need, on CPU alone, with a 63MB model and no accelerator. It is the clear TTS winner.

**Kokoro-82M int8** on CPU is **NOT** real-time here: RTF **1.37-1.74** (slower than real time). The **fp32** re-test (Leg 2b) confirmed the int8 quantize/dequantize (QDQ) overhead theory: fp32 is **~2x faster** (short 0.87, medium 0.59) — real-time-capable for medium/long but borderline on short, and still ~5-8x slower than Piper. **Takeaway: if you use Kokoro on CPU, use fp32, not int8.** Kokoro's appeal is voice quality/variety, not speed; Piper wins decisively on latency.

G2P was a non-issue for both: Piper bundles espeak-ng data in its wheel; kokoro-onnx pulls `espeakng-loader` (bundled espeak-ng binary) + `phonemizer`. No `winget install espeak-ng` was needed.

### 2. Did the OpenVINO NPU/iGPU path work, and is it worth it for Whisper? — It WORKED cleanly; "worth it" is conditional.
The finicky leg succeeded on **all three devices** with zero driver/ABI/static-shape errors on OpenVINO **2026.3.1**. All three (`CPU`, `GPU`=Arc 140V, `NPU`=AI Boost) were enumerated, compiled, and produced identical correct transcripts — verified genuine on-device execution, not a silent CPU fallback.

Per-inference speed (whisper-base int8, 29 s clip): **NPU RTF 0.019 (~52x RT) > GPU 0.024 (~42x) > CPU 0.073 (~14x)**. So NPU/GPU are ~3-4x faster per inference than CPU.

**The catch is one-time compile cost:** NPU **26.5 s**, GPU **18.1 s**, CPU **1.4 s**. For a single 29 s clip, CPU does the whole job (compile+infer) in ~3.5 s while NPU needs ~27 s of compile before its 0.55 s inference. The accelerators only pay off when the pipeline stays **resident** and processes many clips (compile amortized), or when you need to offload the CPU for other work (e.g. running STT + MT + TTS concurrently). For occasional/offline STT, **CPU is simpler and already excellent**.

### 3. Best CPU STT is not Whisper-on-accelerator — it's Parakeet or whisper-base.
Under the same contended load that pushed faster-whisper small to RTF ~0.94, **sherpa-onnx Parakeet-TDT-0.6b int8 hit RTF 0.17** and **openvino whisper-base int8 on CPU hit 0.073** — both comfortably real-time on CPU with no accelerator. faster-whisper small/large-v3-turbo (RTF ~0.94/1.13, beam=5) are the slow options here, partly model size and partly beam search; greedy decoding would help. Model sizes differ across legs, so compare within a leg.

### 4. MT (OPUS-MT via CTranslate2) is cheap on CPU — once two Windows/Marian gotchas are cleared.
en→de translation ran at **median 95 ms/sentence** (p90 123 ms, 10.2 sent/s, batch=1, 4 threads, no torch installed). That is easily fast enough for live per-sentence translation, and batching would push throughput much higher. Two non-obvious pitfalls cost real time and are the main takeaway (below).

## Install / version / driver pitfalls encountered
- **Python 3.13 + latest wheels all resolved cleanly** — piper-tts 1.7.0, kokoro-onnx 0.6.1, faster-whisper 1.2.1 (ctranslate2 4.8.2), sherpa-onnx, openvino 2026.3.1, openvino-genai. No build-from-source needed.
- **Piper 1.x API changed** from older docs: use `PiperVoice.load(onnx)` then `voice.synthesize(text, SynthesisConfig())` yielding `AudioChunk` (`.audio_int16_bytes`). espeak data auto-located in the wheel.
- **Kokoro int8 slowness** is a major gotcha — int8 ONNX was ~2x SLOWER than fp32 on this CPU (QDQ overhead). Do not assume int8 is faster; benchmark both.
- **OPUS-MT via raw CTranslate2 needs `</s>` appended to the SOURCE tokens** (HF's MarianTokenizer does this automatically; raw SentencePiece does not). Without it the decoder never emits EOS and produces repetitive garbage while decoding to the 256-token max — ~6 s/sentence, which looked like a hang. Appending `</s>` gave correct output at ~95 ms/sentence.
- **Windows console cp1252** raised `UnicodeEncodeError` when printing SentencePiece's `▁` marker and German umlauts — set `PYTHONUTF8=1` (or keep prints ASCII-safe / `json.dumps` which is ASCII by default).
- **Sample rate:** Piper outputs 22.05kHz; Parakeet and OpenVINO Whisper need 16kHz mono — resampled with ffmpeg (faster-whisper resamples internally, so it was fine on the 22.05kHz file).
- **OpenVINO accelerator compile time**, not correctness, is the real cost on this box (NPU 26.5s / GPU 18.1s first compile). OpenVINO caches compiled blobs, so a warm process avoids repaying it.
- **CTranslate2 is CPU-only here** (no CUDA) — expected. It reported the OPUS-MT model as fp16 and auto-converted to fp32 for CPU.
- **Heavy background load** on the box inflated CPU-bound STT numbers; treat Leg 3 RTFs as upper bounds.
