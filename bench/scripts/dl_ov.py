from huggingface_hub import snapshot_download
from pathlib import Path
dest = Path(r"C:/Dev/tools/tts/bench/models/ov-whisper-base-int8")
p = snapshot_download(repo_id="OpenVINO/whisper-base-int8-ov", local_dir=str(dest))
print("downloaded to", p)
import os
for f in sorted(os.listdir(p)):
    fp = Path(p)/f
    print(f, fp.stat().st_size if fp.is_file() else "<dir>")
