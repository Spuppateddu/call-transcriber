#!/usr/bin/env bash
#
# call-transcriber — near-live draft transcript
#
# Started in the background by start.sh while a recording is running.
# Watches the growing mic.raw / pc.raw files and, every LIVE_CHUNK
# seconds of new audio, transcribes the new piece with a FAST whisper model
# and prints time-ordered [HH:MM:SS] [ME]/[THEM] lines to the terminal.
# The same lines are appended to live.txt in the session directory.
#
# This is a quick draft to help you catch a name or a number while you talk.
# The accurate transcript.txt is still produced at the end.
#
# Usage:  ./live.sh <session-directory-being-recorded>
#
# Options (environment variables):
#   LIVE_MODEL=base   fast model for the draft (default: base on a CPU build,
#                     the best of medium/small/base on a CUDA build)
#   LIVE_CHUNK=30     seconds of audio per live chunk
#   LIVE_THREADS=N    CPU threads per live whisper run (default: half the cores)
#   LANG_CODE=en      spoken language (default: auto-detect)
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib.sh"
WHISPER_DIR="$HERE/whisper.cpp"
DIR="${1:?Usage: ./live.sh <session-directory>}"
DIR="$(cd "$DIR" && pwd)"

BPS=$((RATE * 2))            # bytes per second: s16le mono
LIVE_CHUNK="${LIVE_CHUNK:-$LIVE_CHUNK_DEFAULT}"
LANG_CODE="${LANG_CODE:-auto}"
MAX_CHUNK=120                # most seconds of audio transcribed in one go

# Half the cores. This draft runs *during* the call, so it has to leave room for
# the call itself and for the recorders; transcribe.sh takes every core instead,
# because by the time it runs the call is over.
LIVE_THREADS="${LIVE_THREADS:-}"
if [ -z "$LIVE_THREADS" ]; then
    LIVE_THREADS=$(( $(cpu_threads) / 2 ))
    [ "$LIVE_THREADS" -lt 1 ] && LIVE_THREADS=1
fi

CLI_BIN="$(find_whisper_cli "$WHISPER_DIR")" || {
    echo "live: whisper-cli not found — live view disabled." >&2
    exit 1
}

# The live draft needs a model fast enough to keep up while you talk.
# On a CPU-only build that means base; a GPU build transcribes a 30s
# chunk in a couple of seconds even with medium, so prefer the good models.
# Note this is deliberately NOT lib.sh's best_model: that one picks the most
# accurate model, while the draft needs the fastest one that can keep up.
LIVE_MODEL="${LIVE_MODEL:-}"
if [ -z "$LIVE_MODEL" ]; then
    if ldd "$CLI_BIN" 2>/dev/null | grep -q 'libggml-cuda'; then
        CANDIDATES="medium small base"
    else
        CANDIDATES="base"
    fi
    LIVE_MODEL="$(first_installed_model "$WHISPER_DIR" "$CANDIDATES")" || LIVE_MODEL=""
fi
MODEL_FILE="$(model_file "$WHISPER_DIR" "$LIVE_MODEL")" || {
    echo "live: no fast model found (get one with: MODEL=base ./install.sh) — live view disabled." >&2
    exit 1
}

# VAD: skip non-speech inside a chunk; without it whisper can hallucinate
# text on partial silence (the mean-volume check only catches silent chunks).
vad_args "$WHISPER_DIR" || true

TMP="$(mktemp -d)"
STOP=""
trap 'STOP=1' INT TERM
# The terminal is gone, so stop drawing on it: a pty whose terminal closed
# fails writes with EIO, which under 'set -e' would kill us before the EXIT
# trap could clean up $TMP. live.txt is written by a separate append in note(),
# so the draft on disk stays complete right up to the stop. Our stderr already
# points at live.log (start.sh redirects it) and is left alone.
trap 'exec >/dev/null; STOP=1' HUP
trap 'rm -rf "$TMP"' EXIT

LIVE_TXT="$DIR/live.txt"
printf '# Live draft (model: %s) — the final transcript.txt supersedes this file.\n' \
    "$LIVE_MODEL" > "$LIVE_TXT"

# Print a line on the terminal and into live.txt. \r + clear-line first, so the
# recording timer start.sh keeps redrawing is overwritten cleanly.
note() {  # $1 = line
    printf '\r\033[K%s\n' "$1"
    printf '%s\n' "$1" >> "$LIVE_TXT"
}

# Bytes of a raw file not yet processed, sample-aligned. Deliberately NOT capped:
# the caller needs to see the whole backlog to know whether it fell behind.
avail() {  # $1=rawfile  $2=offset-bytes
    local size n
    size="$(stat -c %s "$1" 2>/dev/null || echo 0)"
    n=$(( size - $2 ))
    [ "$n" -lt 0 ] && n=0
    echo $(( n - n % 2 ))
}

# Split a backlog into the piece to transcribe (CHUNK_LEN) and the older piece
# to give up on (CHUNK_SKIP). Transcribing the oldest audio first keeps the draft
# in order, but on a machine where whisper is slower than real time that order
# costs unbounded lag: the backlog only ever grows, and a bigger chunk takes
# proportionally longer, so it can never catch up by working harder. Past
# MAX_CHUNK we therefore drop the stale head and jump to the newest audio. Only
# the draft loses it — the .raw file is untouched and the final transcript.txt
# still covers every second.
CHUNK_LEN=0
CHUNK_SKIP=0
plan_chunk() {  # $1 = backlog in bytes
    local max=$(( MAX_CHUNK * BPS ))
    CHUNK_SKIP=0
    CHUNK_LEN="$1"
    if [ "$CHUNK_LEN" -gt "$max" ]; then
        CHUNK_SKIP=$(( CHUNK_LEN - max ))
        CHUNK_LEN="$max"
    fi
}

# Transcribe one new chunk of one raw track; emits tsv lines on stdout.
# Any failure (device gone, Ctrl+C mid-whisper) just skips the chunk, but it
# leaves a marker so the loop can say so once instead of drafting nothing
# forever. stderr is NOT discarded: start.sh points it at live.log.
do_chunk() {  # $1=rawfile  $2=label  $3=offset-bytes  $4=length-bytes
    local start_s=$(( $3 / BPS )) mean=""
    rm -f "$TMP/chunk.raw" "$TMP/chunk.wav" "$TMP/chunk.srt"
    dd if="$1" of="$TMP/chunk.raw" iflag=skip_bytes,count_bytes \
        skip="$3" count="$4" status=none || { : > "$TMP/failed"; return 0; }
    ffmpeg -hide_banner -loglevel error -y \
        -f s16le -ar "$RATE" -ac 1 -i "$TMP/chunk.raw" "$TMP/chunk.wav" \
        || { : > "$TMP/failed"; return 0; }
    # Skip silent chunks: whisper hallucinates text on silence.
    if mean="$(mean_volume "$TMP/chunk.wav")" && db_below "$mean" "$SILENCE_DB"; then
        return 0
    fi
    # nice: the draft is the lowest-priority thing on this machine right now.
    # Whatever is carrying the call gets the CPU first, always.
    nice -n 15 "$CLI_BIN" -m "$MODEL_FILE" -l "$LANG_CODE" -t "$LIVE_THREADS" -np \
        "${VAD_ARGS[@]}" \
        -osrt -of "$TMP/chunk" -f "$TMP/chunk.wav" >/dev/null \
        || { : > "$TMP/failed"; return 0; }
    [ -f "$TMP/chunk.srt" ] && srt_to_tsv "$TMP/chunk.srt" "$2" "$start_s"
    return 0
}

OFF_MIC=0
OFF_PC=0
NEED=$(( LIVE_CHUNK * BPS ))
WARNED=0

# One track, one round: skip ahead if we fell behind, transcribe the next chunk,
# append its lines to OUT and advance that track's offset. The offset is passed
# by NAME because a function cannot hand back both the lines and the new offset.
step_track() {  # $1=rawfile  $2=label  $3=name of the offset variable
    local raw="$1" label="$2" var="$3" off="${!3}" have
    have="$(avail "$raw" "$off")"
    [ "$have" -ge "$NEED" ] || return 0
    plan_chunk "$have"
    if [ "$CHUNK_SKIP" -gt 0 ]; then
        off=$(( off + CHUNK_SKIP ))
        note "--- [$label] draft skipped $(( CHUNK_SKIP / BPS ))s to stay live (kept in transcript.txt) ---"
    fi
    OUT+="$(do_chunk "$raw" "$label" "$off" "$CHUNK_LEN")"$'\n'
    printf -v "$var" '%d' $(( off + CHUNK_LEN ))
}

while [ -z "$STOP" ]; do
    sleep 1 || true
    [ -n "$STOP" ] && break

    OUT=""
    step_track "$DIR/mic.raw" "ME" OFF_MIC
    [ -n "$STOP" ] && break
    step_track "$DIR/pc.raw" "THEM" OFF_PC

    # start.sh already announced the draft by the time a chunk can fail, so say
    # here (once) that it is not coming — stdout is the terminal, stderr is the log.
    if [ -e "$TMP/failed" ] && [ "$WARNED" = "0" ]; then
        WARNED=1
        printf '\r\033[Klive: a draft chunk failed — details in %s\n' "$DIR/live.log"
    fi

    [ -n "${OUT//$'\n'/}" ] || continue
    printf '%s' "$OUT" | grep -v '^$' | sort -s -n -k1,1 | fmt_tsv \
        | while IFS= read -r line; do note "$line"; done
done
