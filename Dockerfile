# ------------------------------------------------------------
# Stage 1 — Builder with model cache
# ------------------------------------------------------------
FROM runpod/worker-comfyui:5.5.1-base AS builder

# Install GGUF node
RUN git clone https://github.com/city96/ComfyUI-GGUF /comfyui/custom_nodes/ComfyUI-GGUF

# Install PuLID Flux node
RUN git clone https://github.com/ltdrdata/ComfyUI-PuLID-Flux /comfyui/custom_nodes/ComfyUI-PuLID-Flux

# Create a persistent model cache directory
ENV COMFYUI_MODEL_CACHE=/cache/models
RUN mkdir -p $COMFYUI_MODEL_CACHE

# Configure comfy-cli to use the cache
ENV COMFY_CLI_CACHE_DIR=$COMFYUI_MODEL_CACHE

# Download models into the cache (only downloads if missing)
RUN comfy model download --url https://huggingface.co/lzyvegetable/FLUX.1-dev/resolve/main/flux1-dev.safetensors \
    --relative-path diffusion_models \
    --filename flux1-dev.safetensors

RUN comfy model download --url https://huggingface.co/Comfy-Org/stable-diffusion-3.5-fp8/resolve/main/text_encoders/clip_l.safetensors \
    --relative-path clip \
    --filename clip_l.safetensors

RUN comfy model download --url https://huggingface.co/guozinan/PuLID/resolve/main/pulid_flux_v0.9.1.safetensors \
    --relative-path pulid \
    --filename pulid_flux.safetensors

RUN comfy model download --url https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files/vae/ae.safetensors \
    --relative-path vae \
    --filename ae.safetensors


# ------------------------------------------------------------
# Stage 2 — Final runtime image
# ------------------------------------------------------------
FROM runpod/worker-comfyui:5.5.1-base

# Copy cached models from builder stage
COPY --from=builder /cache/models /comfyui/models

# Add the RunPod serverless handler
COPY handler.py /handler.py

# Default command for RunPod Serverless
CMD ["python3", "/handler.py"]
