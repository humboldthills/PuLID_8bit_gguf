FROM runpod/worker-comfyui:5.5.1-base

# Install custom nodes in the final image so ComfyUI can actually load them.
RUN git clone https://github.com/city96/ComfyUI-GGUF /comfyui/custom_nodes/ComfyUI-GGUF && \
    pip install --no-cache-dir -r /comfyui/custom_nodes/ComfyUI-GGUF/requirements.txt

RUN git clone https://github.com/balazik/ComfyUI-PuLID-Flux /comfyui/custom_nodes/ComfyUI-PuLID-Flux && \
    pip install --no-cache-dir -r /comfyui/custom_nodes/ComfyUI-PuLID-Flux/requirements.txt

# ComfyUI-PuLID-Flux assumes an insightface API variant where FaceAnalysis
# accepts providers=... in __init__. The RunPod base image can resolve a
# different variant, so patch the node to fall back cleanly.
RUN python3 - <<'PY'
from pathlib import Path

path = Path("/comfyui/custom_nodes/ComfyUI-PuLID-Flux/pulidflux.py")
text = path.read_text()
old = """        model = FaceAnalysis(name=\"antelopev2\", root=INSIGHTFACE_DIR, providers=[provider + 'ExecutionProvider',]) # alternative to buffalo_l\n"""
new = """        try:\n            model = FaceAnalysis(name=\"antelopev2\", root=INSIGHTFACE_DIR, providers=[provider + 'ExecutionProvider',]) # alternative to buffalo_l\n        except TypeError:\n            model = FaceAnalysis(name=\"antelopev2\", root=INSIGHTFACE_DIR) # alternative to buffalo_l\n"""
if old not in text:
    raise SystemExit("expected FaceAnalysis constructor line not found")
path.write_text(text.replace(old, new))
PY

COPY input/lila_face_master_locked_v1.png /comfyui/input/lila_face_master_locked_v1.png
COPY handler.py /handler.py

CMD ["python3", "/handler.py"]
