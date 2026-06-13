#!/bin/bash
# =============================================================================
#  getmodel.sh  —  selective model downloader for ComfyUI on RunPod / Vast
# =============================================================================
#  Reads a catalog of model links (local file OR raw URL), shows a numbered
#  menu, and downloads ONLY the ones you pick into the right models/ subfolder
#  on your network volume. Skips files already present.
#
#  USAGE:
#    ./getmodel.sh https://raw.githubusercontent.com/you/repo/main/models-catalog.txt
#    ./getmodel.sh /workspace/models-catalog.txt
#    MODEL_CATALOG_URL=https://...raw... ./getmodel.sh        # via env var
#
#  AT THE PROMPT you can enter:
#    1 3 5        download items 1, 3 and 5
#    2-6          download items 2 through 6
#    loras        download every item in the "loras" folder/category
#    all          download everything in the catalog
#    q            quit
#
#  Gated/private files: export HF_TOKEN and/or CIVITAI_TOKEN before running.
# =============================================================================

set -uo pipefail

# ---- Locate ComfyUI models dir ----------------------------------------------
COMFYUI_DIR="${COMFYUI_DIR:-/opt/ComfyUI}"
[ -d "/workspace/ComfyUI" ] && COMFYUI_DIR="/workspace/ComfyUI"
[ -d "/workspace/comfyui" ] && COMFYUI_DIR="/workspace/comfyui"
MODELS_DIR="${COMFYUI_DIR}/models"

# ---- Resolve catalog source -------------------------------------------------
CATALOG_SRC="${1:-${MODEL_CATALOG_URL:-}}"
if [ -z "$CATALOG_SRC" ]; then
    echo "ERROR: give a catalog file path or URL (or set MODEL_CATALOG_URL)."
    exit 1
fi

TMP_CATALOG="$(mktemp)"
trap 'rm -f "$TMP_CATALOG"' EXIT

if [[ "$CATALOG_SRC" == http* ]]; then
    echo "Fetching catalog: $CATALOG_SRC"
    wget -q -O "$TMP_CATALOG" "$CATALOG_SRC" || { echo "Failed to fetch catalog."; exit 1; }
else
    cp "$CATALOG_SRC" "$TMP_CATALOG" || { echo "Catalog file not found."; exit 1; }
fi

# ---- Parse catalog into parallel arrays -------------------------------------
declare -a C_FOLDER C_URL C_FNAME
while IFS= read -r line; do
    line="${line%%$'\r'}"                          # strip CR
    [[ -z "${line// }" ]] && continue              # skip blank
    [[ "${line#"${line%%[![:space:]]*}"}" == \#* ]] && continue  # skip comments
    IFS='|' read -r f u n <<< "$line"
    f="$(echo "$f" | xargs)"; u="$(echo "$u" | xargs)"; n="$(echo "${n:-}" | xargs)"
    [[ -z "$f" || -z "$u" ]] && continue
    [[ -z "$n" ]] && n="$(basename "${u%%\?*}")"
    C_FOLDER+=("$f"); C_URL+=("$u"); C_FNAME+=("$n")
done < "$TMP_CATALOG"

TOTAL=${#C_URL[@]}
if [ "$TOTAL" -eq 0 ]; then echo "Catalog is empty."; exit 1; fi

# ---- Print menu -------------------------------------------------------------
echo
echo "================ MODEL CATALOG ($TOTAL items) ================"
last_folder=""
for i in "${!C_URL[@]}"; do
    if [ "${C_FOLDER[$i]}" != "$last_folder" ]; then
        echo "  --- ${C_FOLDER[$i]} ---"
        last_folder="${C_FOLDER[$i]}"
    fi
    present=""
    [ -f "${MODELS_DIR}/${C_FOLDER[$i]}/${C_FNAME[$i]}" ] && present="  [already downloaded]"
    printf "  %2d) %s%s\n" $((i+1)) "${C_FNAME[$i]}" "$present"
done
echo "============================================================"
echo "Select: numbers (1 3 5), range (2-6), category name, 'all', or 'q'."
read -r -p "> " SELECTION
[[ "$SELECTION" == "q" ]] && { echo "Cancelled."; exit 0; }

# ---- Build the list of indices to download ----------------------------------
declare -a PICK
if [[ "$SELECTION" == "all" ]]; then
    for i in "${!C_URL[@]}"; do PICK+=("$i"); done
else
    for tok in $SELECTION; do
        if [[ "$tok" =~ ^[0-9]+-[0-9]+$ ]]; then          # range
            lo="${tok%-*}"; hi="${tok#*-}"
            for ((n=lo; n<=hi; n++)); do PICK+=("$((n-1))"); done
        elif [[ "$tok" =~ ^[0-9]+$ ]]; then               # single number
            PICK+=("$((tok-1))")
        else                                              # category name
            for i in "${!C_FOLDER[@]}"; do
                [[ "${C_FOLDER[$i]}" == "$tok" ]] && PICK+=("$i")
            done
        fi
    done
fi

if [ ${#PICK[@]} -eq 0 ]; then echo "Nothing selected."; exit 0; fi

# ---- Download helper (auth + skip-if-exists) --------------------------------
download_one() {
    local folder="$1" url="$2" fname="$3"
    local dest="${MODELS_DIR}/${folder}"
    mkdir -p "$dest"
    if [ -f "${dest}/${fname}" ]; then
        echo "[skip] ${folder}/${fname} already present"; return 0
    fi
    local header=""
    if [[ "$url" == *huggingface.co* && -n "${HF_TOKEN:-}" ]]; then
        header="Authorization: Bearer ${HF_TOKEN}"
    elif [[ "$url" == *civitai.com* && -n "${CIVITAI_TOKEN:-}" ]]; then
        header="Authorization: Bearer ${CIVITAI_TOKEN}"
    fi
    echo "[get ] ${folder}/${fname}"
    if [ -n "$header" ]; then
        wget --header="$header" --content-disposition -q --show-progress -O "${dest}/${fname}" "$url" \
            || { echo "[fail] ${fname}"; rm -f "${dest}/${fname}"; }
    else
        wget --content-disposition -q --show-progress -O "${dest}/${fname}" "$url" \
            || { echo "[fail] ${fname}"; rm -f "${dest}/${fname}"; }
    fi
}

# ---- Run downloads (dedup indices) ------------------------------------------
echo
declare -A SEEN
for i in "${PICK[@]}"; do
    [[ -n "${SEEN[$i]:-}" ]] && continue
    SEEN[$i]=1
    download_one "${C_FOLDER[$i]}" "${C_URL[$i]}" "${C_FNAME[$i]}"
done
echo
echo "Done. Files are on your network volume under ${MODELS_DIR}/"
