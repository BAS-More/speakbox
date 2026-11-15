import time, json, statistics
from pathlib import Path
import ctranslate2
import sentencepiece as spm

MDIR = Path(r"C:/Dev/tools/tts/bench/models/opus-mt-en-de-ct2")

# 100 short English sentences
subjects = ["The team", "My friend", "The company", "A child", "The doctor",
            "Our teacher", "The engineer", "A tourist", "The chef", "The pilot"]
verbs = ["finished the project", "opened the door", "read the book",
         "solved the problem", "bought a new car", "planted a tree",
         "wrote a long letter", "answered the question", "cleaned the room",
         "watched the sunset"]
SENTS = []
for s in subjects:
    for v in verbs:
        SENTS.append(f"{s} {v} yesterday.")
SENTS = SENTS[:100]

sp_src = spm.SentencePieceProcessor(model_file=str(MDIR / "source.spm"))
sp_tgt = spm.SentencePieceProcessor(model_file=str(MDIR / "target.spm"))

t0 = time.perf_counter()
tr = ctranslate2.Translator(str(MDIR), device="cpu", intra_threads=4, inter_threads=1)
load_ms = (time.perf_counter() - t0) * 1000.0
print(f"loaded in {load_ms:.0f} ms; {len(SENTS)} sentences")

def enc(s):
    return sp_src.encode(s, out_type=str) + ["</s>"]  # Marian appends EOS to source
def dec(hyp):
    return sp_tgt.decode([x for x in hyp if x != "</s>"])

# warmup
_ = tr.translate_batch([enc(SENTS[0])], beam_size=1)

lat = []
sample_out = None
t_all = time.perf_counter()
for i, s in enumerate(SENTS):
    toks = enc(s)
    t = time.perf_counter()
    res = tr.translate_batch([toks], beam_size=1)
    dt = (time.perf_counter() - t) * 1000.0
    lat.append(dt)
    if i == 0:
        sample_out = dec(res[0].hypotheses[0])
total_wall = time.perf_counter() - t_all

out = {
    "status": "ok", "load_ms": round(load_ms, 1),
    "n_sentences": len(SENTS),
    "median_ms_per_sentence": round(statistics.median(lat), 2),
    "mean_ms_per_sentence": round(statistics.mean(lat), 2),
    "p90_ms": round(sorted(lat)[int(len(lat)*0.9)], 2),
    "throughput_sent_per_s": round(len(SENTS) / total_wall, 1),
    "threads": 4,
    "beam_size": 1,
    "sample": f"EN: {SENTS[0]} -> DE: {sample_out}",
}
print("sample:", (f"{SENTS[0]} -> {sample_out}").encode("ascii", "replace").decode())
print("RESULT_JSON=" + json.dumps(out))
