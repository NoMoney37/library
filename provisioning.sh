#!/bin/bash
# =============================================================================
#  ComfyUI provisioning script for AI-Dock images (RunPod / Vast)
#  - Downloads a curated "most-used" model library onto your network volume
#  - Skips files that already exist (safe to re-run every boot)
#  - Supports gated/private downloads via HF_TOKEN and CIVITAI_TOKEN env vars
#
#  USAGE:
#    1. Edit the arrays below to taste (comment out anything you don't want).
#    2. Host this file as a RAW text URL (GitHub Gist -> Raw, or Pastebin raw).
#    3. In your RunPod template, set env var:
#         PROVISIONING_SCRIPT = https://your-raw-url/provisioning.sh
#    4. (Optional) set HF_TOKEN and CIVITAI_TOKEN env vars for gated models.
#
#  NOTE: Keep the template PRIVATE if you ever put tokens in Docker options.
#        Prefer passing tokens as separate env vars, not inside this script.
# =============================================================================

set -euo pipefail

# ---- Locate the ComfyUI directory (AI-Dock usually sets this) ---------------
COMFYUI_DIR="${COMFYUI_DIR:-/opt/ComfyUI}"
[ -d "/workspace/ComfyUI" ] && COMFYUI_DIR="/workspace/ComfyUI"
[ -d "/workspace/comfyui" ] && COMFYUI_DIR="/workspace/comfyui"
MODELS_DIR="${COMFYUI_DIR}/models"
echo "[provisioning] Using model dir: ${MODELS_DIR}"

# =============================================================================
#  MODEL LISTS  ---  comment out anything you don't need
#  Each entry is a direct download URL. HuggingFace = .../resolve/main/file
# =============================================================================

# ---- Checkpoints (base diffusion models) ------------------------------------
CHECKPOINT_MODELS=(
    # SDXL base (most common general-purpose XL model)
    "https://huggingface.co/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors"
    # SD 1.5 (still required by tons of older workflows / LoRAs / controlnets)
    "https://huggingface.co/Comfy-Org/stable-diffusion-v1-5-archive/resolve/main/v1-5-pruned-emaonly-fp16.safetensors"
    # FLUX.1-schnell (fast, non-gated, Apache-2.0)
    "https://huggingface.co/Comfy-Org/flux1-schnell/resolve/main/flux1-schnell-fp8.safetensors"
    # FLUX.1-dev fp8 (GATED on HF — requires HF_TOKEN + accepting the license)
    # "https://huggingface.co/Comfy-Org/flux1-dev/resolve/main/flux1-dev-fp8.safetensors"
)

# ---- UNET / diffusion_models (for split FLUX setups) ------------------------
UNET_MODELS=(
    # "https://huggingface.co/..."   # add full-precision flux unet here if wanted
)

# ---- VAE --------------------------------------------------------------------
VAE_MODELS=(
    # SDXL VAE
    "https://huggingface.co/stabilityai/sdxl-vae/resolve/main/sdxl_vae.safetensors"
    # SD1.5 improved VAE (ft-mse-840000)
    "https://huggingface.co/stabilityai/sd-vae-ft-mse-original/resolve/main/vae-ft-mse-840000-ema-pruned.safetensors"
    # FLUX VAE (ae.safetensors) — needed for Flux split workflows
    "https://huggingface.co/Comfy-Org/Lumina_Image_2.0_Repackaged/resolve/main/split_files/vae/ae.safetensors"
)

# ---- CLIP / text encoders (needed for FLUX / SD3 split workflows) -----------
CLIP_MODELS=(
    "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/clip_l.safetensors"
    "https://huggingface.co/comfyanonymous/flux_text_encoders/resolve/main/t5xxl_fp8_e4m3fn.safetensors"
)

# ---- LoRAs ------------------------------------------------------------------
LORA_MODELS=(
    # Add your favourite LoRAs here. Civitai example (needs CIVITAI_TOKEN):
    # "https://civitai.com/api/download/models/XXXXXX"
)

# ---- ControlNet -------------------------------------------------------------
CONTROLNET_MODELS=(
    # SDXL controlnets (Xinsir / community). Uncomment what you use.
    # "https://huggingface.co/xinsir/controlnet-union-sdxl-1.0/resolve/main/diffusion_pytorch_model_promax.safetensors"
)

# ---- Upscalers --------------------------------------------------------------
UPSCALE_MODELS=(
    "https://huggingface.co/lllyasviel/Annotators/resolve/main/RealESRGAN_x4plus.pth"
    "https://huggingface.co/Kim2091/UltraSharp/resolve/main/4x-UltraSharp.pth"
)

# ---- Embeddings / textual inversions ----------------------------------------
EMBEDDING_MODELS=(
    # "https://huggingface.co/.../easynegative.safetensors"
)

# ---- Custom nodes (git repos) — installed into custom_nodes/ ----------------
CUSTOM_NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager"
    "https://github.com/ltdrdata/ComfyUI-Impact-Pack"
    "https://github.com/Fannovel16/comfyui_controlnet_aux"
    "https://github.com/cubiq/ComfyUI_essentials"
    "https://github.com/rgthree/rgthree-comfy"
    "https://github.com/city96/ComfyUI-GGUF"
)

# =============================================================================
#  DOWNLOAD HELPERS  (skip-if-exists, with auth headers)
# =============================================================================

provisioning_download() {
    # $1 = url, $2 = destination directory
    local url="$1" dest="$2" auth_header="" fname
    mkdir -p "$dest"

    # Choose auth header by host
    if [[ "$url" == *"huggingface.co"* && -n "${HF_TOKEN:-}" ]]; then
        auth_header="Authorization: Bearer ${HF_TOKEN}"
    elif [[ "$url" == *"civitai.com"* && -n "${CIVITAI_TOKEN:-}" ]]; then
        # Civitai wants the token as a query param OR bearer; bearer works for API dl
        auth_header="Authorization: Bearer ${CIVITAI_TOKEN}"
    fi

    # Resolve a filename (HF/most direct links); --content-disposition handles Civitai
    fname="$(basename "${url%%\?*}")"
    if [ -f "${dest}/${fname}" ]; then
        echo "[skip] ${fname} already present"
        return 0
    fi

    echo "[get ] ${url}"
    if [ -n "$auth_header" ]; then
        wget --header="$auth_header" --content-disposition -q --show-progress \
             -P "$dest" "$url"
    else
        wget --content-disposition -q --show-progress -P "$dest" "$url"
    fi
}

provisioning_download_list() {
    # $1 = subdir under models/, rest = urls
    local subdir="$1"; shift
    local arr=("$@")
    [ ${#arr[@]} -eq 0 ] && return 0
    for url in "${arr[@]}"; do
        provisioning_download "$url" "${MODELS_DIR}/${subdir}"
    done
}

provisioning_clone_nodes() {
    local nodes_dir="${COMFYUI_DIR}/custom_nodes"
    mkdir -p "$nodes_dir"
    for repo in "${CUSTOM_NODES[@]}"; do
        local name; name="$(basename "$repo")"
        if [ -d "${nodes_dir}/${name}" ]; then
            echo "[skip] custom node ${name} present"
        else
            echo "[git ] ${repo}"
            git clone --depth 1 "$repo" "${nodes_dir}/${name}" || true
        fi
        # Install node requirements if present
        if [ -f "${nodes_dir}/${name}/requirements.txt" ]; then
            pip install -q -r "${nodes_dir}/${name}/requirements.txt" || true
        fi
    done
}

# =============================================================================
#  RUN
# =============================================================================
provisioning_start() {
    echo "[provisioning] Starting model library download..."
    provisioning_clone_nodes
    provisioning_download_list "checkpoints"       "${CHECKPOINT_MODELS[@]}"
    provisioning_download_list "diffusion_models"  "${UNET_MODELS[@]}"
    provisioning_download_list "vae"               "${VAE_MODELS[@]}"
    provisioning_download_list "clip"              "${CLIP_MODELS[@]}"
    provisioning_download_list "loras"             "${LORA_MODELS[@]}"
    provisioning_download_list "controlnet"        "${CONTROLNET_MODELS[@]}"
    provisioning_download_list "upscale_models"    "${UPSCALE_MODELS[@]}"
    provisioning_download_list "embeddings"        "${EMBEDDING_MODELS[@]}"
    echo "[provisioning] Done. Library ready on the network volume."
}

provisioning_start
