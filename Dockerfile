# ------------------------------------------------------------
# Stage 1 - Builder with model cache
# ------------------------------------------------------------
FROM runpod/worker-comfyui:5.5.1-base AS builder

ENV COMFYUI_MODEL_CACHE=/cache/models
ENV COMFY_CLI_CACHE_DIR=$COMFYUI_MODEL_CACHE

RUN mkdir -p "$COMFYUI_MODEL_CACHE/unet" \
    "$COMFYUI_MODEL_CACHE/clip" \
    "$COMFYUI_MODEL_CACHE/vae" \
    "$COMFYUI_MODEL_CACHE/pulid" \
    "$COMFYUI_MODEL_CACHE/insightface/models"

# Download into the exact model folders this ComfyUI build scans.
RUN python3 -c "import urllib.request; urllib.request.urlretrieve('https://huggingface.co/city96/FLUX.1-dev-gguf/resolve/main/flux1-dev-Q8_0.gguf', '$COMFYUI_MODEL_CACHE/unet/flux1-dev-Q8_0.gguf')"

RUN python3 -c "import urllib.request; urllib.request.urlretrieve('https://huggingface.co/city96/t5-v1_1-xxl-encoder-gguf/resolve/main/t5-v1_1-xxl-encoder-Q8_0.gguf', '$COMFYUI_MODEL_CACHE/clip/t5-v1_1-xxl-encoder-Q8_0.gguf')"

RUN python3 -c "import urllib.request; urllib.request.urlretrieve('https://huggingface.co/Comfy-Org/stable-diffusion-3.5-fp8/resolve/main/text_encoders/clip_l.safetensors', '$COMFYUI_MODEL_CACHE/clip/clip_l.safetensors')"

RUN python3 -c "import urllib.request; urllib.request.urlretrieve('https://huggingface.co/guozinan/PuLID/resolve/main/pulid_flux_v0.9.1.safetensors', '$COMFYUI_MODEL_CACHE/pulid/pulid_flux_v0.9.1.safetensors')"

RUN python3 -c "import urllib.request; urllib.request.urlretrieve('https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors', '$COMFYUI_MODEL_CACHE/vae/ae.safetensors')"

RUN python3 -c "import urllib.request; urllib.request.urlretrieve('https://huggingface.co/vladmandic/insightface-faceanalysis/resolve/main/antelopev2.zip', '$COMFYUI_MODEL_CACHE/insightface/antelopev2.zip')"

RUN python3 - <<'PY'
from pathlib import Path
import shutil
import zipfile

root = Path("/cache/models/insightface")
zip_path = root / "antelopev2.zip"
extract_root = root / "models"
target = extract_root / "antelopev2"

target.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(zip_path) as zf:
    zf.extractall(extract_root)

# Some archives extract into models/antelopev2/antelopev2/*.onnx. Flatten that.
nested = target / "antelopev2"
if nested.exists() and nested.is_dir():
    for item in nested.iterdir():
        shutil.move(str(item), target / item.name)
    nested.rmdir()

zip_path.unlink(missing_ok=True)
PY


# ------------------------------------------------------------
# Stage 2 - Final runtime image
# ------------------------------------------------------------
FROM runpod/worker-comfyui:5.5.1-base

# This RunPod image adds model search paths from /runpod-volume/models, so bake the
# files there. Copying into /comfyui/models alone is not enough for validation.
COPY --from=builder /cache/models /runpod-volume/models
COPY --from=builder /cache/models /comfyui/models

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
