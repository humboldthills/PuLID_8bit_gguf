# ------------------------------------------------------------
# Stage 1 - Builder with model cache
# ------------------------------------------------------------
FROM runpod/worker-comfyui:5.5.1-base AS builder

ENV COMFYUI_MODEL_CACHE=/cache/models
ENV COMFY_CLI_CACHE_DIR=$COMFYUI_MODEL_CACHE

RUN mkdir -p "$COMFYUI_MODEL_CACHE/unet" \
    "$COMFYUI_MODEL_CACHE/clip" \
    "$COMFYUI_MODEL_CACHE/vae" \
    "$COMFYUI_MODEL_CACHE/pulid"

# Download into the exact model folders this ComfyUI build scans.
RUN curl -L "https://huggingface.co/city96/FLUX.1-dev-gguf/resolve/main/flux1-dev-Q8_0.gguf" \
    -o "$COMFYUI_MODEL_CACHE/unet/flux1-dev-Q8_0.gguf"

RUN curl -L "https://huggingface.co/city96/t5-v1_1-xxl-encoder-gguf/resolve/main/t5-v1_1-xxl-encoder-Q8_0.gguf" \
    -o "$COMFYUI_MODEL_CACHE/clip/t5-v1_1-xxl-encoder-Q8_0.gguf"

RUN curl -L "https://huggingface.co/Comfy-Org/stable-diffusion-3.5-fp8/resolve/main/text_encoders/clip_l.safetensors" \
    -o "$COMFYUI_MODEL_CACHE/clip/clip_l.safetensors"

RUN curl -L "https://huggingface.co/guozinan/PuLID/resolve/main/pulid_flux_v0.9.1.safetensors" \
    -o "$COMFYUI_MODEL_CACHE/pulid/pulid_flux_v0.9.1.safetensors"

RUN curl -L "https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors" \
    -o "$COMFYUI_MODEL_CACHE/vae/ae.safetensors"


# ------------------------------------------------------------
# Stage 2 - Final runtime image
# ------------------------------------------------------------
FROM runpod/worker-comfyui:5.5.1-base

COPY --from=builder /cache/models /comfyui/models

# Install custom nodes in the final image so ComfyUI can actually load them.
RUN git clone https://github.com/city96/ComfyUI-GGUF /comfyui/custom_nodes/ComfyUI-GGUF && \
    pip install --no-cache-dir -r /comfyui/custom_nodes/ComfyUI-GGUF/requirements.txt

RUN git clone https://github.com/balazik/ComfyUI-PuLID-Flux /comfyui/custom_nodes/ComfyUI-PuLID-Flux && \
    pip install --no-cache-dir -r /comfyui/custom_nodes/ComfyUI-PuLID-Flux/requirements.txt

COPY input/lila_face_master_locked_v1.png /comfyui/input/lila_face_master_locked_v1.png

COPY handler.py /handler.py

CMD ["python3", "/handler.py"]
