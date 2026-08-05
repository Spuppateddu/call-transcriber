#!/usr/bin/env bash
#
# call-transcriber — installer
# Installs all dependencies and builds whisper.cpp (offline speech-to-text).
# Tested on Ubuntu 24.04 (PipeWire).
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
WHISPER_DIR="$HERE/whisper.cpp"
DEFAULT_WHISPER_REF="v1.9.1"           # whisper.cpp release this was tested with
WHISPER_REF="${WHISPER_REF:-$DEFAULT_WHISPER_REF}"
# The commit that tag pointed at when it was tested. A git tag is a movable
# label, so pinning the tag alone does not pin the code: we compile and then run
# whatever we check out, and only this makes that byte-exact. Asking for a
# different WHISPER_REF drops the pin (nothing to compare against) unless you
# supply the matching WHISPER_SHA yourself. WHISPER_SHA= skips the check.
if [ "$WHISPER_REF" = "$DEFAULT_WHISPER_REF" ]; then
    WHISPER_SHA="${WHISPER_SHA-f049fff95a089aa9969deb009cdd4892b3e74916}"
else
    WHISPER_SHA="${WHISPER_SHA-}"
fi

# Which model to download. You can force it non-interactively with MODEL=...
#   base  small  medium  large-v3   (smaller = faster, larger = accurate)
# If MODEL is not set, the script detects your CPU/RAM, recommends a model and
# lets you choose.
MODEL="${MODEL:-}"

# One-line blurb per model, for the menu below. MODEL_SIZES (lib.sh) is what
# decides which models are offered and in what order; this only decides how
# each one is described, so a model added there still shows up in the menu —
# it just arrives without a blurb until someone writes it one.
model_blurb() {  # $1 = model name
    case "$1" in
        base)     printf 'fast, decent quality            (~140 MB)' ;;
        small)    printf 'good balance                    (~460 MB)' ;;
        medium)   printf 'very accurate, slower           (~1.5 GB)' ;;
        large-v3) printf 'best quality, VERY slow on CPU  (~3 GB)'   ;;
    esac
}

choose_model() {
    # --- detect hardware -----------------------------------------------------
    local cores ram_gb rec models=() m i def_i=1 choice
    cores="$(cpu_threads)"
    # 'found' is what makes the fallback work: on a /proc/meminfo without a
    # MemTotal line awk prints nothing and still exits 0, so '|| echo 8' never
    # fires and every comparison below runs against an empty string. Same guard
    # as available_ram() in lib.sh.
    ram_gb="$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024; found=1}
                   END {exit !found}' /proc/meminfo 2>/dev/null || echo 8)"

    # --- recommendation based on cores + RAM ---------------------------------
    # 'medium' is the accuracy sweet spot and only uses ~2-2.5 GB while running,
    # so ~12 GB total is plenty of headroom. We deliberately gate at 12, not 16:
    # a "16 GB" machine usually reports ~15 GB (the iGPU reserves some), and a
    # 16 GB gate would wrongly miss it and suggest 'small' instead.
    if   [ "$ram_gb" -ge 12 ] && [ "$cores" -ge 4 ]; then rec="medium"
    elif [ "$ram_gb" -ge 6  ] && [ "$cores" -ge 2 ]; then rec="small"
    else                                                   rec="base"
    fi

    echo "==> Detected CPU: ${cores} cores, ${ram_gb} GB RAM" >&2
    echo "    Recommended model for this machine: ${rec}" >&2
    echo >&2
    for m in $MODEL_SIZES; do models+=("$m"); done
    echo "Choose the model to download (used to transcribe after each recording):" >&2
    for i in "${!models[@]}"; do
        [ "${models[$i]}" = "$rec" ] && def_i=$((i+1))
        printf '   %d) %-9s- %s\n' "$((i+1))" "${models[$i]}" \
            "$(model_blurb "${models[$i]}")" >&2
    done
    echo >&2
    echo "All models are multilingual: ~100 languages, auto-detected." >&2
    echo >&2
    read -rp "Number [Enter = recommended: ${rec}]: " choice </dev/tty || choice=""
    # Through pick_index, like every other numbered menu here: an empty reply,
    # a typo or an out-of-range number all land on the recommendation, and the
    # "==> Downloading model: X" line below then says which one that was.
    choice="$(pick_index "$choice" "${#models[@]}" "$def_i")"
    printf '%s' "${models[$((choice-1))]}"
}

if [ -z "$MODEL" ]; then
    if [ -t 0 ] || [ -e /dev/tty ]; then
        MODEL="$(choose_model)"
    else
        MODEL="small"   # no interactive terminal: use a sensible default
    fi
fi

echo "==> Installing system packages (needs sudo)..."
sudo apt-get update
sudo apt-get install -y \
    build-essential cmake git \
    ffmpeg \
    pulseaudio-utils \
    procps \
    pipewire-audio-client-libraries wireplumber

echo "==> Getting whisper.cpp ($WHISPER_REF)..."
# Pinned to a release so it does not change under us on every install.
# Override with WHISPER_REF=<tag|branch> (and WHISPER_SHA=<sha> to keep the
# verification below, or WHISPER_SHA= to skip it).
if [ -d "$WHISPER_DIR/.git" ]; then
    git -C "$WHISPER_DIR" fetch --depth 1 origin tag "$WHISPER_REF" 2>/dev/null \
        || git -C "$WHISPER_DIR" fetch --tags origin
    git -C "$WHISPER_DIR" checkout -q "$WHISPER_REF"
else
    git clone --depth 1 --branch "$WHISPER_REF" \
        https://github.com/ggerganov/whisper.cpp "$WHISPER_DIR"
fi

# A tag can be moved upstream, and the re-install path above would follow it
# without a word. Refuse to build code we did not pin rather than compile and
# run something we were never tested against.
GOT_SHA="$(git -C "$WHISPER_DIR" rev-parse HEAD)"
if [ -z "$WHISPER_SHA" ]; then
    echo "    NOTE: no pinned commit for '$WHISPER_REF' — skipping the check." >&2
    echo "          Building whisper.cpp at $GOT_SHA" >&2
elif [ "$GOT_SHA" != "$WHISPER_SHA" ]; then
    echo "ERROR: whisper.cpp '$WHISPER_REF' is not the commit this was pinned to." >&2
    echo "       expected: $WHISPER_SHA" >&2
    echo "       got:      $GOT_SHA" >&2
    echo "       The tag was moved upstream, or WHISPER_REF names something else." >&2
    echo "       If that is expected, re-run with the new commit:" >&2
    echo "         WHISPER_SHA=$GOT_SHA ./install.sh" >&2
    echo "       or skip the check entirely with:  WHISPER_SHA= ./install.sh" >&2
    exit 1
fi

echo "==> Building whisper.cpp..."
# With an NVIDIA GPU + CUDA toolkit, build GPU-accelerated: transcription gets
# ~10-20x faster and bigger models become usable even for the live draft.
# Always passed explicitly, ON or OFF: cmake remembers the variables of a
# previous configure, so leaving the flag out does NOT mean "no CUDA" — it means
# "keep whatever the build directory was configured with last time". A machine
# that has since lost the CUDA toolkit would otherwise keep rebuilding with
# GGML_CUDA=ON out of the cache, and fail without ever saying why.
CUDA_FLAG="-DGGML_CUDA=OFF"
JOBS="$(cpu_threads)"
if command -v nvcc >/dev/null 2>&1 && command -v nvidia-smi >/dev/null 2>&1; then
    echo "    NVIDIA GPU + CUDA toolkit found: building with GPU support."
    CUDA_FLAG="-DGGML_CUDA=ON"
    # nvcc jobs need gigabytes of RAM each: unbounded -j can freeze the PC.
    [ "$JOBS" -gt 4 ] && JOBS=4
fi
cmake -S "$WHISPER_DIR" -B "$WHISPER_DIR/build" -DCMAKE_BUILD_TYPE=Release "$CUDA_FLAG"
cmake --build "$WHISPER_DIR/build" -j"$JOBS" --config Release

echo "==> Downloading model: $MODEL ..."
bash "$WHISPER_DIR/models/download-ggml-model.sh" "$MODEL"

# VAD model: lets whisper skip non-speech, preventing hallucinated text on
# the long silences of the mic track while the other people are talking.
if [ ! -f "$WHISPER_DIR/models/ggml-silero-v6.2.0.bin" ]; then
    echo "==> Downloading VAD model (skips silence, ~1 MB)..."
    bash "$WHISPER_DIR/models/download-vad-model.sh" silero-v6.2.0
fi

# The live draft shown while recording needs a fast model (base);
# big models can't keep up in real time on CPU.
case "$MODEL" in
    base) : ;;   # the main model is already fast enough for the live draft
    *)
        if [ ! -f "$WHISPER_DIR/models/ggml-base.bin" ]; then
            echo "==> Downloading 'base' too (fast model for the live draft, ~140 MB)..."
            bash "$WHISPER_DIR/models/download-ggml-model.sh" base
        fi ;;
esac

echo
echo "==> Done."
echo "    whisper.cpp built in: $WHISPER_DIR/build/bin"
echo "    model:                $WHISPER_DIR/models/ggml-$MODEL.bin"
echo
echo "Now start recording with:  $HERE/start.sh"
