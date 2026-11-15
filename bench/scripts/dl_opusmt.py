from huggingface_hub import snapshot_download
from pathlib import Path
BENCH = Path(__file__).resolve().parents[1]  # the bench/ folder, wherever the repo is
dest = BENCH / "models/opus-mt-en-de-ct2"
p = snapshot_download(repo_id="gaudi/opus-mt-en-de-ctranslate2", local_dir=str(dest))
print("downloaded to", p)
