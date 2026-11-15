from huggingface_hub import snapshot_download
from pathlib import Path
dest = Path(r"C:/Dev/tools/tts/bench/models/opus-mt-en-de-ct2")
p = snapshot_download(repo_id="gaudi/opus-mt-en-de-ctranslate2", local_dir=str(dest))
print("downloaded to", p)
