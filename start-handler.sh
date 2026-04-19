#!/bin/sh
set -eu

CANDIDATES="
/runpod-volume/ComfyUI/models
/workspace/ComfyUI/models
/runpod-volume/workspace/ComfyUI/models
/runpod-volume/models
"

EXPECTED_DIRS="unet clip vae pulid insightface checkpoints"
SYNC_DIRS="unet clip vae pulid insightface checkpoints loras clip_vision configs controlnet embeddings upscale_models diffusion_models text_encoders"

pick_rgthree_root() {
  for candidate in \
    "$MODEL_ROOT/../custom_nodes/rgthree-comfy" \
    "/runpod-volume/ComfyUI/custom_nodes/rgthree-comfy" \
    "/workspace/ComfyUI/custom_nodes/rgthree-comfy" \
    "/runpod-volume/custom_nodes/rgthree-comfy"
  do
    if [ -d "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

pick_model_root() {
  for candidate in $CANDIDATES; do
    for name in $EXPECTED_DIRS; do
      if [ -d "$candidate/$name" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  done
  return 1
}

MODEL_ROOT="${MODEL_ROOT_OVERRIDE:-}"
if [ -z "$MODEL_ROOT" ]; then
  MODEL_ROOT="$(pick_model_root || true)"
fi

if [ -z "$MODEL_ROOT" ]; then
  echo "No existing model root found. Checked:" >&2
  for candidate in $CANDIDATES; do
    echo "  $candidate" >&2
  done
  exit 1
fi

echo "Using model root: $MODEL_ROOT"
export MODEL_ROOT_OVERRIDE="$MODEL_ROOT"
if [ -d "$MODEL_ROOT/insightface" ]; then
  export INSIGHTFACE_ROOT="$MODEL_ROOT/insightface"
  echo "Using InsightFace root: $INSIGHTFACE_ROOT"
fi

mkdir -p /comfyui/models
mkdir -p /comfyui/custom_nodes

for name in $SYNC_DIRS; do
  src="$MODEL_ROOT/$name"
  dst="/comfyui/models/$name"
  if [ ! -e "$src" ]; then
    continue
  fi

  if [ -L "$dst" ] || [ -f "$dst" ]; then
    rm -f "$dst"
  elif [ -d "$dst" ]; then
    rm -rf "$dst"
  fi

  ln -s "$src" "$dst"
done

RGTHREE_ROOT="$(pick_rgthree_root || true)"
if [ -n "$RGTHREE_ROOT" ]; then
  RGTHREE_DST="/comfyui/custom_nodes/rgthree-comfy"
  if [ -L "$RGTHREE_DST" ] || [ -f "$RGTHREE_DST" ]; then
    rm -f "$RGTHREE_DST"
  elif [ -d "$RGTHREE_DST" ]; then
    rm -rf "$RGTHREE_DST"
  fi
  ln -s "$RGTHREE_ROOT" "$RGTHREE_DST"
  echo "Using rgthree custom nodes: $RGTHREE_ROOT"
fi

exec python3 /handler.py
