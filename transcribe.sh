#!/usr/bin/env bash
#
# call-transcriber — transcription
#
# Two modes:
#
#   1) Session directory (the normal case, run automatically by start.sh):
#        ./transcribe.sh sessions/2026-07-14_21-00-00
#      Transcribes mic.wav and pc.wav and merges them, time-ordered and
#      labeled [ME] / [THEM], into transcript.txt in the same directory.
#
#   2) Single audio file:
#        ./transcribe.sh some-audio.wav
#      Produces some-audio.txt next to it.
#
# Options (environment variables):
#   LANG_CODE=en   spoken language (default: auto-detect)
#   MODEL=medium   whisper model (default: best one you have installed)
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
WHISPER_DIR="$HERE/whisper.cpp"
LANG_CODE="${LANG_CODE:-auto}"

# A transcript is as private as the call it came from. start.sh already sets
# this before exec'ing us; set it here too, for the times we are run by hand.
umask 077

TARGET="${1:-}"
if [ -z "$TARGET" ] || { [ ! -f "$TARGET" ] && [ ! -d "$TARGET" ]; }; then
    echo "Usage: ./transcribe.sh <session-directory | audio-file>" >&2
    exit 1
fi

CLI_BIN="$(find_whisper_cli "$WHISPER_DIR")" || {
    echo "ERROR: whisper-cli not found. Run ./install.sh first." >&2
    exit 1
}

# Model: use $MODEL if forced, otherwise the best installed one — the same pick
# start.sh offers as its default (MODEL_PREFERENCE in lib.sh).
MODEL="${MODEL:-}"
if [ -z "$MODEL" ]; then
    MODEL="$(best_model "$WHISPER_DIR")" || {
        echo "ERROR: no whisper model installed. Run ./install.sh first." >&2
        exit 1
    }
fi
MODEL_FILE="$(model_file "$WHISPER_DIR" "$MODEL")" || {
    echo "ERROR: model '$MODEL' not found at $WHISPER_DIR/models/ggml-$MODEL.bin" >&2
    echo "Get it with:  MODEL=$MODEL ./install.sh" >&2
    exit 1
}

THREADS="$(cpu_threads)"

vad_args "$WHISPER_DIR" || {
    echo "NOTE: VAD model missing; silent stretches may produce hallucinated text." >&2
    echo "      Get it with:  bash whisper.cpp/models/download-vad-model.sh silero-v6.2.0" >&2
}

# Run whisper on one wav, producing <prefix>.srt (timestamps needed for merging).
run_whisper_srt() {  # $1=wav  $2=output-prefix  $3=threads
    "$CLI_BIN" -m "$MODEL_FILE" -l "$LANG_CODE" -t "$3" "${VAD_ARGS[@]}" \
        -osrt -of "$2" -f "$1" > "$2.log" 2>&1
}

# ==============================================================================
# Mode 1: session directory -> merged transcript.txt
# ==============================================================================
if [ -d "$TARGET" ]; then
    DIR="$(cd "$TARGET" && pwd)"
    MIC_WAV="$DIR/mic.wav"
    PC_WAV="$DIR/pc.wav"
    PC_PREFIX="${PC_WAV%.wav}"
    TXT="$DIR/transcript.txt"

    TRACKS=0
    [ -f "$MIC_WAV" ] && TRACKS=$((TRACKS+1))
    [ -f "$PC_WAV" ] && TRACKS=$((TRACKS+1))
    if [ "$TRACKS" -eq 0 ]; then
        echo "ERROR: no mic.wav / pc.wav found in $DIR" >&2
        exit 1
    fi

    # Clear the .srt files of any earlier run before producing new ones. The
    # merge at the bottom takes whatever .srt it finds, and an .srt outlives its
    # .wav easily — deleting the audio to reclaim space is the normal reason.
    # Left in place, that orphan gets spliced into this transcript as if it had
    # just been produced, silently pairing today's [THEM] with a [ME] from a
    # different model and possibly a different language.
    rm -f "$DIR/mic.srt" "$PC_PREFIX.srt"

    # Running both tracks at once splits the CPU threads but DOUBLES the memory:
    # each whisper process loads its own copy of the weights (large-v3 is ~3 GB).
    # On a machine that cannot hold two, the OOM killer takes one down after a
    # long wait and the whole run is lost — so check first and go one at a time
    # instead. Sequential is barely slower anyway, since each run then gets all
    # the threads that the parallel version was splitting.
    PARALLEL=1
    if [ "$TRACKS" -gt 1 ]; then
        MODEL_BYTES="$(stat -c %s "$MODEL_FILE" 2>/dev/null || echo 0)"
        RAM_BYTES="$(available_ram || echo 0)"
        # 1.4x the weights per process: whisper's compute buffers and KV cache
        # sit on top of the model file itself.
        NEEDED=$(( MODEL_BYTES * TRACKS * 14 / 10 ))
        if [ "$RAM_BYTES" -gt 0 ] && [ "$NEEDED" -gt "$RAM_BYTES" ]; then
            PARALLEL=0
            echo "==> Only $(( RAM_BYTES / 1024 / 1024 )) MB RAM available and '$MODEL' needs"
            echo "    ~$(( NEEDED / 1024 / 1024 )) MB for $TRACKS parallel tracks — transcribing them one at a time."
        fi
    fi

    if [ "$PARALLEL" = "1" ]; then
        T_EACH=$(( THREADS / TRACKS )); [ "$T_EACH" -lt 1 ] && T_EACH=1
    else
        T_EACH="$THREADS"
    fi
    echo "==> Transcribing $TRACKS track(s) (model: $MODEL, language: $LANG_CODE, $T_EACH threads each)..."
    echo "    This runs offline and can take a while for long recordings."

    FAIL=0
    if [ "$PARALLEL" = "1" ]; then
        PIDS=()
        if [ -f "$MIC_WAV" ]; then
            run_whisper_srt "$MIC_WAV" "$DIR/mic" "$T_EACH" & PIDS+=($!)
        fi
        if [ -f "$PC_WAV" ]; then
            run_whisper_srt "$PC_WAV" "$PC_PREFIX" "$T_EACH" & PIDS+=($!)
        fi
        for pid in "${PIDS[@]}"; do
            wait "$pid" || FAIL=1
        done
    else
        if [ -f "$MIC_WAV" ]; then
            run_whisper_srt "$MIC_WAV" "$DIR/mic" "$T_EACH" || FAIL=1
        fi
        if [ -f "$PC_WAV" ]; then
            run_whisper_srt "$PC_WAV" "$PC_PREFIX" "$T_EACH" || FAIL=1
        fi
    fi
    if [ "$FAIL" -ne 0 ]; then
        echo "ERROR: whisper failed on a track. See the .log files in $DIR" >&2
        exit 1
    fi

    echo "==> Merging tracks into transcript.txt ..."
    {
        echo "# Recording $(basename "$DIR") — language: $LANG_CODE, model: $MODEL"
        echo "# [ME]   = my microphone: me talking."
        echo "# [THEM] = my PC's audio: everyone else on the call, plus any other sound my PC played."
        echo
        {
            [ -f "$DIR/mic.srt" ]       && srt_to_tsv "$DIR/mic.srt"       "ME"
            [ -f "$PC_PREFIX.srt" ]     && srt_to_tsv "$PC_PREFIX.srt"     "THEM"
            # Without this the group exits 1 whenever the LAST track is missing,
            # and pipefail + set -e would abort right before the "Done" message.
            true
        } | sort -s -n -k1,1 | fmt_tsv
    } > "$TXT"

    # Count the transcript lines themselves, not the header written above.
    LINES="$(grep -c '^\[' "$TXT" || true)"
    echo
    echo "==> Done: $TXT  ($LINES lines)"
    if [ "$LINES" -eq 0 ]; then
        echo "    (empty transcript — were the tracks silent? Check the .wav files)" >&2
    fi
    exit 0
fi

# ==============================================================================
# Mode 2: single audio file -> <file>.txt
# ==============================================================================
AUDIO="$TARGET"
# Strip the extension from the FILE name only: a plain "${AUDIO%.*}" on a path
# like recordings.old/interview would cut at the dot in the DIRECTORY instead.
AUDIO_DIR="$(dirname "$AUDIO")"
AUDIO_BASE="$(basename "$AUDIO")"
case "$AUDIO_BASE" in
    *.*) AUDIO_BASE="${AUDIO_BASE%.*}" ;;
esac
if [ "$AUDIO_DIR" = "." ]; then OUT="$AUDIO_BASE"; else OUT="$AUDIO_DIR/$AUDIO_BASE"; fi

# whisper.cpp wants 16 kHz mono wav; convert whatever we were given.
TMP_WAV="$(mktemp --suffix=.wav)"
trap 'rm -f "$TMP_WAV"' EXIT
ffmpeg -hide_banner -loglevel error -y -i "$AUDIO" -ar "$RATE" -ac 1 "$TMP_WAV"

echo "==> Transcribing '$AUDIO' (model: $MODEL, language: $LANG_CODE)..."
"$CLI_BIN" -m "$MODEL_FILE" -l "$LANG_CODE" -t "$THREADS" "${VAD_ARGS[@]}" \
    -otxt -of "$OUT" -f "$TMP_WAV"
echo "==> Done: $OUT.txt"
