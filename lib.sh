#!/usr/bin/env bash
#
# call-transcriber — helpers shared by install.sh, start.sh, live.sh and
# transcribe.sh. This file is sourced, never run directly.
#

# whisper wants 16 kHz mono; recording it directly avoids conversions.
RATE=16000

# A track quieter than this is treated as silence: whisper hallucinates
# sentences on silence, and a silent track usually means the wrong device.
SILENCE_DB=-55

# Every model install.sh can fetch, smallest first — menu display order.
MODEL_SIZES="base small medium large-v3"

# Order used whenever a model is picked automatically, best first. 'large-v3'
# sits below 'medium' and 'small' on purpose: on CPU it can take longer than
# the recording itself, so it is only chosen when nothing else is installed.
MODEL_PREFERENCE="medium small large-v3 base"

# Seconds of audio per live-draft chunk. start.sh announces this number and
# live.sh transcribes by it, so it lives here: announcing 30 while drafting at
# some other interval is worse than either value on its own.
LIVE_CHUNK_DEFAULT=30

# CPU threads to use, with a fallback for the rare box without nproc.
cpu_threads() {
    nproc 2>/dev/null || echo 4
}

# Echo the whisper CLI of a built whisper.cpp; fail if it is not built.
find_whisper_cli() {  # $1 = whisper.cpp directory
    local bin="$1/build/bin/whisper-cli"
    [ -x "$bin" ] || bin="$1/build/bin/main"   # older builds name it 'main'
    [ -x "$bin" ] || return 1
    printf '%s' "$bin"
}

# Echo the file of a model; fail if that model is not installed.
model_file() {  # $1 = whisper.cpp directory  $2 = model name
    local f="$1/models/ggml-$2.bin"
    [ -f "$f" ] || return 1
    printf '%s' "$f"
}

# Echo the first model of a candidate list that is installed; fail if none is.
first_installed_model() {  # $1 = whisper.cpp dir  $2 = space-separated names
    local m
    for m in $2; do
        [ -f "$1/models/ggml-$m.bin" ] || continue
        printf '%s' "$m"
        return 0
    done
    return 1
}

# Echo the best installed model; fail if none is installed. Every script that
# picks a model on its own uses this, so their defaults cannot drift apart.
best_model() {  # $1 = whisper.cpp directory
    first_installed_model "$1" "$MODEL_PREFERENCE"
}

# Fill VAD_ARGS with whisper's Voice Activity Detection flags, so non-speech
# never reaches the model; fail (with VAD_ARGS empty) if the model is missing.
vad_args() {  # $1 = whisper.cpp directory
    local model="$1/models/ggml-silero-v6.2.0.bin"
    VAD_ARGS=()
    [ -f "$model" ] || return 1
    VAD_ARGS=(--vad -vm "$model")
}

# Echo the mean volume of an audio file in dB, or fail if it can't be read.
# ffmpeg reports all-zero audio as "-inf", which is echoed unchanged.
mean_volume() {  # $1 = audio file
    local mean
    mean="$(ffmpeg -hide_banner -i "$1" -af volumedetect -f null - 2>&1 \
            | sed -n 's/.*mean_volume: *\(-inf\|-\{0,1\}[0-9.]*\) dB.*/\1/p')"
    [ -n "$mean" ] || return 1
    printf '%s' "$mean"
}

# True if a mean_volume reading is below a dB threshold. "-inf" (a dead or
# muted device) is the quietest reading there is, so it is always below.
db_below() {  # $1 = reading  $2 = threshold
    [ "$1" = "-inf" ] && return 0
    awk -v m="$1" -v t="$2" 'BEGIN{exit !(m < t)}'
}

# Echo the 1-based index picked from a numbered menu: the typed reply when it is
# a number inside the menu, the default otherwise (empty reply, typo, out of
# range). Every numbered menu validates through here; the two menus that also
# accept a non-numeric answer (the language code, yes/no) use their own 'case'.
pick_index() {  # $1 = reply  $2 = number of items  $3 = default index (1-based)
    local n
    if [ -n "$1" ] && [ "$1" -ge 1 ] 2>/dev/null && [ "$1" -le "$2" ] 2>/dev/null; then
        # In range, so it is an integer — but it may be signed ("+3") or
        # zero-prefixed ("08"). Normalize before the caller indexes with it:
        # bash arithmetic reads a leading zero as octal, and "$(( 08 ))" is a
        # fatal "value too great for base", not a fallback to the default.
        n="${1#+}"
        printf '%s' "$(( 10#$n ))"
    else
        printf '%s' "$3"
    fi
}

# Echo the bytes of RAM currently available, or nothing if it can't be read.
available_ram() {
    awk '/MemAvailable/ {printf "%d", $2*1024; found=1}
         END {exit !found}' /proc/meminfo 2>/dev/null
}

# Signal a process and every descendant. Signalling a shell alone is not enough
# when it is blocked waiting on a slow child (whisper): the child keeps running
# and the shell cannot handle its trap until that child returns.
kill_tree() {  # $1 = signal name  $2 = pid
    local child
    for child in $(pgrep -P "$2" 2>/dev/null || true); do
        kill_tree "$1" "$child"
    done
    kill "-$1" "$2" 2>/dev/null || true
    return 0
}

# Convert an .srt into lines of "seconds<TAB>label<TAB>text", shifting the
# timestamps by a chunk start. Segments that are only a non-speech marker like
# [BLANK_AUDIO] or (music) are dropped — whisper emits those on silence/music.
srt_to_tsv() {  # $1 = srt  $2 = label  $3 = start offset in seconds (default 0)
    awk -v label="$2" -v base="${3:-0}" '
        function flush() {
            if (buf != "" && buf !~ /^\[.*\]$/ && buf !~ /^\(.*\)$/)
                printf "%d\t%s\t%s\n", base + start, label, buf
            buf = ""
        }
        /-->/ {
            split($1, t, "[:,]")
            start = t[1]*3600 + t[2]*60 + t[3]
            intext = 1; buf = ""; next
        }
        !intext { next }                                 # subtitle index lines
        /^[[:space:]]*$/ { flush(); intext = 0; next }   # blank line ends the block
        {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            buf = (buf == "" ? $0 : buf " " $0)
        }
        END { if (intext) flush() }
    ' "$1"
}

# Turn tsv lines on stdin into the "[HH:MM:SS] [WHO] text" transcript lines.
fmt_tsv() {
    awk -F'\t' '{ printf "[%02d:%02d:%02d] %-6s %s\n",
                  $1/3600, ($1%3600)/60, $1%60, "[" $2 "]", $3 }'
}
