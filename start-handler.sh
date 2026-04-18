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

mkdir -p /comfyui/models

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

exec python3 /handler.py
