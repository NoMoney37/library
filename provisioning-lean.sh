#!/bin/bash
# =============================================================================
#  ComfyUI provisioning script (LEAN) for AI-Dock images (RunPod / Vast)
#  - Installs ONLY custom nodes (no pre-filled model library)
#  - Models are downloaded ON DEMAND, per-workflow, via the scanner node
#  - Everything lands on your network volume, so it persists across pods
#
#  HOW ON-DEMAND DOWNLOADING WORKS:
#    1. Drop a workflow .json onto the ComfyUI canvas.
#    2. Click "Workflow Models" in the menu bar (added by the scanner node).
#    3. Hit Auto-Resolve -> it finds + downloads every required model into the
#       correct ComfyUI/models/<type> folder on your /workspace volume.
#
#  USAGE:
#    1. Host this file as a RAW text URL (GitHub Gist -> Raw, or Pastebin raw).
#    2. In your RunPod template, set env var:
#         PROVISIONING_SCRIPT = https://your-raw-url/provisioning-lean.sh
#    3. (Optional, for gated/private models) set env vars:
#         HF_TOKEN        = your HuggingFace token
#         CIVITAI_TOKEN   = your Civitai token
#       Then enter the same tokens in the scanner node's Settings inside ComfyUI.
#
#  NOTE: Keep the template PRIVATE if you ever put tokens in Docker options.
# =============================================================================

set -euo pipefail

# ---- Locate the ComfyUI directory (AI-Dock usually sets COMFYUI_DIR) --------
COMFYUI_DIR="${COMFYUI_DIR:-/opt/ComfyUI}"
[ -d "/workspace/ComfyUI" ] && COMFYUI_DIR="/workspace/ComfyUI"
[ -d "/workspace/comfyui" ] && COMFYUI_DIR="/workspace/comfyui"
echo "[provisioning] ComfyUI dir: ${COMFYUI_DIR}"

# ---- Custom nodes to install ------------------------------------------------
CUSTOM_NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager"
    "https://github.com/slahiri/ComfyUI-Workflow-Models-Downloader"
)

# ---- Clone nodes (skip if already present) + install their requirements -----
provisioning_clone_nodes() {
    local nodes_dir="${COMFYUI_DIR}/custom_nodes"
    mkdir -p "$nodes_dir"
    for repo in "${CUSTOM_NODES[@]}"; do
        local name; name="$(basename "$repo")"
        if [ -d "${nodes_dir}/${name}" ]; then
            echo "[skip] custom node ${name} already present"
        else
            echo "[git ] cloning ${repo}"
            git clone --depth 1 "$repo" "${nodes_dir}/${name}" || true
        fi
        if [ -f "${nodes_dir}/${name}/requirements.txt" ]; then
            echo "[pip ] installing requirements for ${name}"
            pip install -q -r "${nodes_dir}/${name}/requirements.txt" || true
        fi
    done
}

provisioning_start() {
    echo "[provisioning] Installing custom nodes (no model library prefill)..."
    provisioning_clone_nodes
    echo "[provisioning] Done. Drop a workflow and use 'Workflow Models' to fetch models on demand."
}

provisioning_start
