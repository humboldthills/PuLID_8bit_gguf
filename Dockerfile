FROM runpod/worker-comfyui:5.5.1-base

# insightface 0.7.3 falls back to a source build on this image, which needs g++.
RUN apt-get update && \
    apt-get install -y --no-install-recommends g++ && \
    rm -rf /var/lib/apt/lists/*

# Install custom nodes in the final image so ComfyUI can actually load them.
RUN git clone https://github.com/city96/ComfyUI-GGUF /comfyui/custom_nodes/ComfyUI-GGUF && \
    pip install --no-cache-dir -r /comfyui/custom_nodes/ComfyUI-GGUF/requirements.txt

RUN git clone https://github.com/balazik/ComfyUI-PuLID-Flux /comfyui/custom_nodes/ComfyUI-PuLID-Flux && \
    pip install --no-cache-dir -r /comfyui/custom_nodes/ComfyUI-PuLID-Flux/requirements.txt

# Pin InsightFace stack for Python 3.12. The model pack is present and valid,
# but newer package combinations still fail FaceAnalysis(name='antelopev2')
# with "assert 'detection' in self.models" in this environment.
RUN pip install --no-cache-dir --upgrade "onnx==1.18.0" "insightface==0.7.3"

# ComfyUI-PuLID-Flux assumes an insightface API variant where FaceAnalysis
# accepts providers=... in __init__. The RunPod base image can resolve a
# different variant, and some node versions pass the wrong root path.
RUN python3 - <<'PY'
from pathlib import Path

path = Path("/comfyui/custom_nodes/ComfyUI-PuLID-Flux/pulidflux.py")
text = path.read_text()
old = """        try:\n            model = FaceAnalysis(name=\"antelopev2\", root=INSIGHTFACE_DIR, providers=[provider + 'ExecutionProvider',]) # alternative to buffalo_l\n        except TypeError:\n            model = FaceAnalysis(name=\"antelopev2\", root=INSIGHTFACE_DIR) # alternative to buffalo_l\n"""
if old not in text:
    old = """        model = FaceAnalysis(name=\"antelopev2\", root=INSIGHTFACE_DIR, providers=[provider + 'ExecutionProvider',]) # alternative to buffalo_l\n"""
new = """        insightface_dir = Path(INSIGHTFACE_DIR)\n        if insightface_dir.name == 'antelopev2':\n            insightface_root = insightface_dir.parent.parent\n        elif insightface_dir.name == 'models':\n            insightface_root = insightface_dir.parent\n        else:\n            insightface_root = insightface_dir\n        try:\n            model = FaceAnalysis(name=\"antelopev2\", root=insightface_root, providers=[provider + 'ExecutionProvider',]) # alternative to buffalo_l\n        except TypeError:\n            model = FaceAnalysis(name=\"antelopev2\", root=insightface_root) # alternative to buffalo_l\n"""
if old not in text:
    raise SystemExit("expected FaceAnalysis constructor block not found")
if "from pathlib import Path" not in text:
    text = "from pathlib import Path\n" + text
path.write_text(text.replace(old, new))
PY

COPY input/lila_face_master_locked_v1.png /comfyui/input/lila_face_master_locked_v1.png
COPY handler.py /handler.py

CMD ["python3", "/handler.py"]
