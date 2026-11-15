import os, time, sys
os.environ["OMP_NUM_THREADS"] = "1"
os.environ["CT2_FORCE_CPU_ISA"] = os.environ.get("CT2_FORCE_CPU_ISA", "")
from pathlib import Path
import ctranslate2, sentencepiece as spm
print("ct2", ctranslate2.__version__, flush=True)
BENCH = Path(__file__).resolve().parents[1]  # the bench/ folder, wherever the repo is
MDIR = BENCH / "models/opus-mt-en-de-ct2"
sp_src = spm.SentencePieceProcessor(model_file=str(MDIR/"source.spm"))
sp_tgt = spm.SentencePieceProcessor(model_file=str(MDIR/"target.spm"))
print("spm loaded", flush=True)
tr = ctranslate2.Translator(str(MDIR), device="cpu", intra_threads=1, inter_threads=1)
print("translator built", flush=True)
tests = ["The team finished the project yesterday.",
         "My friend bought a new car.",
         "The doctor answered the question."]
for s in tests:
    toks = sp_src.encode(s, out_type=str) + ["</s>"]  # Marian appends EOS to source
    t=time.perf_counter()
    res = tr.translate_batch([toks], beam_size=1)
    dt=(time.perf_counter()-t)*1000
    out = sp_tgt.decode([x for x in res[0].hypotheses[0] if x != "</s>"])
    print("%.1f ms | %r" % (dt, out.encode("ascii","replace").decode()), flush=True)
