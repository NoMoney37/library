#!/bin/bash
# =============================================================================
#  ComfyUI provisioning (HARDENED + PINNED) for AI-Dock images
#    0. Install system tools         -> aria2 (fast multi-connection downloads)
#    1. Update ComfyUI to a release tag -> NEW UI, tested version
#    2. Install custom nodes            -> Manager + Workflow-Models-Downloader
#    3. Fetch the model picker          -> getmodel.sh onto the volume
#
#  Idempotent + no `set -e`. Logs every step. Runs on every boot.
# =============================================================================

log(){ echo "[provisioning] $*"; }

# ---- PIN CONTROL ------------------------------------------------------------
#  ""        -> track the LATEST release tag (stable, auto-advances)
#  "v0.3.40" -> HARD-PIN to that exact tag (reproducible, never moves)
#  Tags: https://github.com/comfyanonymous/ComfyUI/releases
COMFYUI_REF=""

# ---- Resolve ComfyUI dir + the ComfyUI venv's pip ---------------------------
COMFYUI_DIR="${COMFYUI_DIR:-/opt/ComfyUI}"
[ -d /workspace/ComfyUI ] && COMFYUI_DIR=/workspace/ComfyUI
PIP="${COMFYUI_VENV_PIP:-pip}"
log "ComfyUI dir : ${COMFYUI_DIR}"
log "pip         : ${PIP}"

GETMODEL_URL="https://raw.githubusercontent.com/NoMoney37/library/refs/heads/main/getmodel.sh"

CUSTOM_NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager"
    "https://github.com/slahiri/ComfyUI-Workflow-Models-Downloader"
    "https://github.com/kijai/ComfyUI-WanVideoWrapper"
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
    "https://github.com/kijai/ComfyUI-KJNodes"
    "https://github.com/kijai/ComfyUI-segment-anything-2"
    "https://github.com/Fannovel16/comfyui_controlnet_aux"
)

# ---- System packages (apt) — reinstalled each boot (ephemeral container) ----
APT_PACKAGES=(
    aria2
)

# =============================================================================
#  0. System tools
# =============================================================================
install_tools(){
    if [ ${#APT_PACKAGES[@]} -gt 0 ]; then
        log "Installing system tools: ${APT_PACKAGES[*]}"
        apt-get update -qq && apt-get install -y -qq "${APT_PACKAGES[@]}" \
            || log "apt install had issues (continuing)"
    fi
}
apt-get update && apt-get install -y aria2
which aria2c

# =============================================================================
#  1. Update ComfyUI to a release tag + new frontend
# =============================================================================
update_comfyui(){
    if [ -d "${COMFYUI_DIR}/.git" ]; then
        git -C "${COMFYUI_DIR}" stash >/dev/null 2>&1
        log "Fetching ComfyUI tags..."
        git -C "${COMFYUI_DIR}" fetch --all --tags --prune || log "fetch failed (continuing)"
        local ref="${COMFYUI_REF}"
        if [ -z "${ref}" ]; then
            ref="$(git -C "${COMFYUI_DIR}" describe --tags "$(git -C "${COMFYUI_DIR}" rev-list --tags --max-count=1)" 2>/dev/null)"
        fi
        if [ -n "${ref}" ]; then
            log "Checking out ComfyUI ${ref}"
            git -C "${COMFYUI_DIR}" checkout -f "${ref}" || log "checkout ${ref} failed (continuing)"
        else
            log "Could not resolve a tag; leaving ComfyUI as-is"
        fi
    else
        log "No .git in ComfyUI dir; skipping update"
    fi
    log "Updating ComfyUI dependencies (includes the new frontend package)..."
    "${PIP}" install -r "${COMFYUI_DIR}/requirements.txt" || log "requirements install had issues (continuing)"
}

# =============================================================================
#  2. Custom nodes
# =============================================================================
install_nodes(){
    local dir="${COMFYUI_DIR}/custom_nodes"
    mkdir -p "${dir}"
    for repo in "${CUSTOM_NODES[@]}"; do
        local name; name="$(basename "${repo}")"
        if [ -d "${dir}/${name}" ]; then
            log "node present : ${name}"
        else
            log "cloning node : ${name}"
            git clone --depth 1 "${repo}" "${dir}/${name}" || log "CLONE FAILED: ${name}"
        fi
        if [ -f "${dir}/${name}/requirements.txt" ]; then
            "${PIP}" install -r "${dir}/${name}/requirements.txt" || log "deps failed: ${name}"
        fi
    done
}

# =============================================================================
#  3. Model picker
# =============================================================================
fetch_picker(){
    log "Fetching model picker (getmodel.sh)..."
    if wget -q -O /workspace/getmodel.sh "${GETMODEL_URL}"; then
        chmod +x /workspace/getmodel.sh
        log "getmodel.sh ready at /workspace/getmodel.sh"
    else
        log "getmodel.sh fetch FAILED"
    fi
}

log "Starting provisioning..."
install_tools          # <-- add this line
update_comfyui
install_nodes
fetch_picker
log "Provisioning complete. ComfyUI launches after this."
