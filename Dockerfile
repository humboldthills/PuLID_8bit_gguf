FROM runpod/worker-comfyui:5.5.1-base

# insightface 0.7.3 falls back to a source build on this image, which needs a
# minimal C/C++ toolchain plus Python headers.
RUN apt-get update && \
    apt-get install -y --no-install-recommends g++ python3-dev && \
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
text = text.replace(old, new)

old_sig = """def forward_orig(\n\n self,\n\n img: Tensor,\n\n img_ids: Tensor,\n  txt: Tensor,\n\n txt_ids: Tensor,\n\n timesteps: Tensor,\n\n y: Tensor,\n\n guidance: Tensor = None,\n\n control=None,\n\n) -> Tensor:\n"""
new_sig = """def forward_orig(\n\n self,\n\n img: Tensor,\n\n img_ids: Tensor,\n  txt: Tensor,\n\n txt_ids: Tensor,\n\n timesteps: Tensor,\n\n y: Tensor,\n\n guidance: Tensor = None,\n\n control=None,\n\n transformer_options=None,\n\n attn_mask=None,\n\n **kwargs,\n\n) -> Tensor:\n"""
if old_sig not in text:
    raise SystemExit("expected forward_orig signature block not found")
text = text.replace(old_sig, new_sig)

old_double = """ img, txt = block(img=img, txt=txt, vec=vec, pe=pe)\n"""
new_double = """ try:\n  img, txt = block(img=img, txt=txt, vec=vec, pe=pe, transformer_options=transformer_options, attn_mask=attn_mask)\n except TypeError as e:\n  if \"unexpected keyword argument\" not in str(e):\n   raise\n  try:\n   img, txt = block(img=img, txt=txt, vec=vec, pe=pe, attn_mask=attn_mask)\n  except TypeError as e:\n   if \"unexpected keyword argument\" not in str(e):\n    raise\n   img, txt = block(img=img, txt=txt, vec=vec, pe=pe)\n"""
if old_double not in text:
    raise SystemExit("expected double block call not found")
text = text.replace(old_double, new_double, 1)

old_single = """ img = block(img, vec=vec, pe=pe)\n"""
new_single = """ try:\n  img = block(img, vec=vec, pe=pe, transformer_options=transformer_options, attn_mask=attn_mask)\n except TypeError as e:\n  if \"unexpected keyword argument\" not in str(e):\n   raise\n  try:\n   img = block(img, vec=vec, pe=pe, attn_mask=attn_mask)\n  except TypeError as e:\n   if \"unexpected keyword argument\" not in str(e):\n    raise\n   img = block(img, vec=vec, pe=pe)\n"""
if old_single not in text:
    raise SystemExit("expected single block call not found")
text = text.replace(old_single, new_single, 1)

path.write_text(text)
PY

# ComfyUI 0.3.68 calls self.forward_orig(..., attn_mask=...) in Flux model
# code, but the PuLID monkeypatch still targets an older signature in some
# revisions. Patch the caller to retry without attn_mask/transformer_options
# when the monkeypatched method does not accept them.
RUN python3 - <<'PY'
from pathlib import Path

path = Path("/comfyui/comfy/ldm/flux/model.py")
text = path.read_text()
old = """        out = self.forward_orig(img, img_ids, context, txt_ids, timestep, y, guidance, control, transformer_options, attn_mask=kwargs.get(\"attention_mask\", None))\n"""
new = """        try:\n            out = self.forward_orig(img, img_ids, context, txt_ids, timestep, y, guidance, control, transformer_options, attn_mask=kwargs.get(\"attention_mask\", None))\n        except TypeError as e:\n            if \"unexpected keyword argument 'attn_mask'\" not in str(e):\n                raise\n            try:\n                out = self.forward_orig(img, img_ids, context, txt_ids, timestep, y, guidance, control, transformer_options)\n            except TypeError as e:\n                if \"positional arguments\" not in str(e) and \"unexpected keyword argument 'transformer_options'\" not in str(e):\n                    raise\n                out = self.forward_orig(img, img_ids, context, txt_ids, timestep, y, guidance, control)\n"""
if old not in text:
    raise SystemExit("expected Flux forward_orig call not found")
text = text.replace(old, new, 1)
path.write_text(text)
PY

COPY input/lila_face_master_locked_v1.png /comfyui/input/lila_face_master_locked_v1.png
COPY handler.py /handler.py

CMD ["python3", "/handler.py"]
