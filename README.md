# call-transcriber

**Record any conversation on Linux and get a text transcript of everything that
was said — you on the microphone, everyone else through your PC's audio.**

Work calls, remote interviews, tabletop RPG sessions, study groups, podcasts:
if the other people reach you through your speakers or headset, this records
both sides as **two separate tracks** and merges them into one time-ordered
transcript with speaker labels:

```
[00:03:10] [ME]   Can you walk me through what happened during the outage?
[00:03:18] [THEM] Sure — it started around 2am, right after the deploy.
```

Everything runs **locally and offline** with
[whisper.cpp](https://github.com/ggerganov/whisper.cpp): after the install,
**no internet, no account, no upload**. Nothing about your calls leaves the
machine — which is the whole point when the recording is a job interview, a
client call, or a private game night. Recordings and transcripts are written
private to your user (`sessions/` is `0700`, the files inside `0600`), so they
stay unreadable to anyone else with an account on the same machine.

---

## What can I use it for?

Anything where the other voices come out of your computer:

- **Work calls and meetings** — Zoom, Meet, Teams, Slack huddles, Discord.
  Get a written record and a summary instead of taking notes while talking.
- **Remote interviews** — as the interviewer (a transcript to quote from) or
  as the candidate (a record of what was actually agreed).
- **Tabletop RPG sessions** — the original use case. Three hours of play
  become a recap you can read before the next session.
- **Study groups, lessons, webinars** — searchable text of an hour of talking.
- **Podcasts and co-op recordings** — rough transcript for show notes.
- **A single audio file you already have** — `./transcribe.sh recording.mp3`
  works on any format ffmpeg can read (see [section 4](#4-re-transcribe-a-session)).

> **In-person conversations** work too, but only the microphone track will have
> anything on it, so everyone ends up labeled `[ME]`. The two-track split only
> separates speakers when the other side arrives as *PC audio*.

---

## How it works

1. `./start.sh` records **two separate tracks** while you talk:
   your **microphone** (the `[ME]` track) and your **PC audio** — everything
   your computer plays, i.e. the other participants (the `[THEM]` track).
   Recording itself is very light on the CPU; it won't slow down the call.
2. While you talk, a **live draft** of the transcript scrolls in the terminal,
   about 30 seconds behind — handy to re-read a name, a number, or what was
   just said. It uses a small fast model, so it's rough; the accurate
   transcript comes at the end. It runs on half your cores at low priority, so
   the call always gets the CPU first, and on a machine too slow to keep up it
   skips ahead (saying so) rather than drifting further and further behind.
3. When you press **Ctrl+C**, both tracks are transcribed locally and merged
   into a single time-ordered `transcript.txt`.

Recording the two tracks separately (instead of mixing them) gives much better
transcription quality — whisper struggles when two voices overlap in the same
audio — and it's what lets the transcript say who was talking.

The default language is **auto-detect**; whisper's multilingual models cover
English and ~100 other languages (see [Options](#options)).

---

## Requirements

- **Ubuntu 24.04** (or derivative) with **PipeWire** (default on Ubuntu 24.04).
- Runs on **CPU** (no NVIDIA GPU required). With an NVIDIA GPU and the CUDA
  toolkit installed, `install.sh` builds GPU-accelerated automatically:
  transcription gets ~10-20x faster and the live draft can use the big
  `medium` model instead of `base`.
- ~2 GB free space for the model + build.

---

## 1. Install (once)

```bash
git clone git@github.com:Spuppateddu/call-transcriber.git
cd call-transcriber
./install.sh
```

`install.sh` does everything:
1. installs system dependencies (ffmpeg, pulseaudio-utils, build tools);
2. downloads and builds whisper.cpp;
3. **detects your CPU/RAM, recommends a model, and lets you choose** which to download.

If you pick a big model (`small` or larger), `install.sh` also downloads the
small `base` model (~140 MB) — that one powers the live draft during recording.
It also downloads a tiny VAD (voice activity detection) model that skips
non-speech: without it, the long silences on your mic track while the other
person talks make whisper hallucinate repeated sentences.

### Which model?

Transcription happens **after** the call (not in real time), so you can afford
a bigger, more accurate model than a "live" tool could. Rough guide for a
3-hour recording:

| Model      | Accuracy | Transcription time (typical 8-core CPU) |
|------------|----------|------------------------------------------|
| `base`     | decent   | ~10 min                                  |
| `small`    | good     | ~30 min                                  |
| `medium`   | great    | ~1–2 h (**recommended** on 4+ cores, 12+ GB RAM) |
| `large-v3` | best     | can take longer than the recording itself |

> ⚠️ Do not use the `.en` models (e.g. `small.en`): those are **English only**
> and can't auto-detect anything.

You can skip the menu and force a model (handy to download a second one):

```bash
MODEL=medium ./install.sh
```

`start.sh` and `transcribe.sh` both auto-pick the best *practical* model you have
installed, in the order `medium` → `small` → `large-v3` → `base`: `large-v3` is
ranked below the others on purpose, since it can outlast the recording itself.
Override anytime with `MODEL=...`.

The installer builds a **pinned release** of whisper.cpp (currently `v1.9.1`), so
a re-install can't silently swap in different upstream *code*. A git tag is only a
movable label, so the exact **commit** is pinned too and verified after checkout —
if the tag ever moves upstream, the install stops instead of compiling and running
something that was never tested here.

The **model weights are the exception**: they come from whisper.cpp's own
`download-ggml-model.sh` over HTTPS with no checksum, so they are not pinned the
way the source is. It's the one upstream input here that rests on transport
security alone.

```bash
WHISPER_REF=v1.9.0 ./install.sh                  # another release (commit check off)
WHISPER_REF=v1.9.0 WHISPER_SHA=<sha> ./install.sh # ...with the check kept on
WHISPER_SHA= ./install.sh                        # skip the check entirely
```

---

## 2. Audio devices: you pick them when you start

`start.sh` **lists your audio devices and asks which two to record**, so you
never depend on the system default being the right one (it often isn't — a
webcam mic tends to grab it):

- **Microphone** → your voice, the `[ME]` track. Choose from the real inputs.
- **PC audio** → everyone else, the `[THEM]` track. Choose the *monitor* of the
  output you actually **listen through**: if the other voices come out of your
  headset, pick the headset's monitor, not the speakers'.

The current system defaults are pre-selected, so pressing Enter twice keeps the
usual behaviour. Your choice is saved in `config.env` with the other answers; if
that device is not connected the next time (USB mic unplugged, headset off),
the script says so and asks again instead of recording silence.

You can also preset them and skip the questions:

```bash
pactl list short sources            # see the exact names
MIC_SRC=alsa_input.usb-Blue_Microphones_Yeti_Stereo_Microphone_REV8-00.analog-stereo \
PC_SRC=alsa_output.pci-0000_00_1f.3.analog-stereo.monitor ./start.sh
```

---

## 3. Record

```bash
./start.sh
```

The first time, it **asks a few questions** (microphone, PC audio, language,
model, live draft on/off) and lists every valid answer — just press **Enter**
at each to take the default, so there's nothing to memorize. At the end it
offers to **remember your answers** in a `config.env` file. On every later run
it then **shows your saved setup and asks whether to keep it or change it** —
keep to start recording right away, or change to answer the questions again.
Delete `config.env` to wipe it entirely. The environment variables below still
work and override the saved answers.

> `config.env` is *sourced*, so whatever is in it runs as you. `start.sh` writes
> it `0600` and refuses to read it back if it is not owned by you and closed to
> everyone else. That check is aimed at the one file here that travels — copied
> between machines, restored from a backup, written by hand — so keep the mode if
> you move it. It is **not** a defense against a writable checkout: anyone who can
> write `config.env` in this directory can equally rewrite `lib.sh`, which every
> script sources unconditionally. Keep the clone itself private.

- A timer shows that recording is running. Talk normally.
- Every ~30 seconds, the **live draft** prints what was just said, with the
  same `[ME]` / `[THEM]` labels as the final transcript. It's a quick
  low-quality draft to jog your memory — don't worry if it garbles words.
- Press **Ctrl+C** when you're done: transcription starts automatically
  (this part uses the CPU heavily — fine to leave it running and walk away).

Files are saved in `sessions/<date_time>/`:

```
sessions/2026-07-14_21-00-00/
├── transcript.txt   ← the merged transcript (feed this to your LLM)
├── live.txt         ← the live draft (rough; superseded by transcript.txt)
├── mic.wav          ← your voice (backup)
├── pc.wav           ← PC audio: everyone else (backup)
├── mic.srt          ← per-track subtitles with timestamps
└── pc.srt
```

### Options

```bash
MIC_SRC=... PC_SRC=... ./start.sh # preset the devices (pactl list short sources)
LANG_CODE=en ./start.sh          # force a language (default: auto-detect)
MODEL=small ./start.sh           # force a model for the final transcription
AUTO_TRANSCRIBE=0 ./start.sh     # record only, transcribe later (see below)
LIVE=0 ./start.sh                # no live draft, just the timer
LIVE_CHUNK=20 ./start.sh         # live draft updates every 20 s instead of 30
LIVE_MODEL=base ./start.sh       # force the model used for the live draft
LIVE_THREADS=2 ./start.sh        # cores for the live draft (default: half of them)
```

Any of these can also be kept in `config.env` so they apply to every run — use
the same `: ${VAR:=value}` form `start.sh` writes, so a value you pass on the
command line still wins over the saved one.

---

## 4. (Re-)transcribe a session

The `.wav` backups are kept, so you can always redo the transcript — for
example with a bigger model, or if you recorded with `AUTO_TRANSCRIBE=0`:

```bash
./transcribe.sh sessions/2026-07-14_21-00-00
MODEL=medium ./transcribe.sh sessions/2026-07-14_21-00-00   # higher quality
```

It also works on a single audio file (any format ffmpeg can read) — useful for
a recording made elsewhere, e.g. a voice memo or a downloaded meeting file:

```bash
./transcribe.sh some-recording.mp3    # creates some-recording.txt
```

---

## 5. Summarize the transcript

A raw transcript of a 2-hour call is long. The companion skill
**[`summarize-transcript`](https://github.com/Spuppateddu/skills/tree/main/summarize-transcript)**
turns it into a readable summary with a **local LLM** (llama.cpp), so the
recording never leaves your machine:

```bash
git clone git@github.com:Spuppateddu/skills.git ~/code/skills
bash ~/code/skills/summarize-transcript/scripts/summarize.sh \
    sessions/2026-07-14_21-00-00/transcript.txt
# -> sessions/2026-07-14_21-00-00/transcript-summary.txt
```

It's an [Agent Skill](https://agentskills.io), so once the
[skills repo](https://github.com/Spuppateddu/skills) is installed your coding
agent (Claude Code, Codex, Cursor, opencode…) triggers it on its own when you
say *"summarize this transcript"* — see that repo's README for the one-command
install. The script also runs standalone, as above.

Prefer a cloud model instead? Just upload `transcript.txt` to your favorite
LLM. The file starts with a comment explaining the `[ME]` / `[THEM]` labels, so
the model has the context it needs.

---

## Troubleshooting

- **"whisper-cli not found"** → run `./install.sh` first.
- **"config.env is not private — ignoring it"** → the file is executed when
  read, so it is only trusted when it belongs to you and nobody else can touch
  it. Restore that with `chmod 600 config.env` (and `chown` it to yourself if it
  came from another account), or just delete it and answer the questions again.
- **"the microphone/PC-audio track sounds silent"** → the wrong device was
  picked. Start again, answer `n` at *Use this setup?* and choose another one.
- **The other voices are missing** → the `[THEM]` device must be the monitor of
  the output the call actually plays through. Check the output setting inside
  the app (Zoom/Meet/Discord have their own), then pick the matching monitor
  when `start.sh` asks.
- **Junk lines in the transcript** (e.g. "Thanks for watching!") → whisper
  hallucinates on music and hold tones. Ignore those lines — an LLM summary
  won't care — or keep background music out of the recorded output.
- **Transcription too slow** → use a smaller model:
  `MODEL=small ./transcribe.sh sessions/<dir>`.
- **"transcribing them one at a time"** → normal: the two tracks usually run in
  parallel, but two copies of a big model would not fit in RAM on this machine,
  so they run in sequence (each with all your cores) instead of risking an
  out-of-memory kill halfway through.
- **"could not convert mic.raw to .wav"** → the disk filled up. Your audio is
  **not** lost: the `.raw` file is intact and the message prints the exact
  `ffmpeg` command to finish the conversion once you free some space.
- **Wrong language in the transcript** → auto-detect guessed badly; name the
  language explicitly with `LANG_CODE=en` (or `it`, `es`, `fr`, …).
- **Live draft lines look garbled** → normal: the draft uses a small fast
  model. The final `transcript.txt` is made with the big one.
- **No live draft lines appear** → either nobody spoke (silent chunks are
  skipped) or no fast model is installed — get one with `MODEL=base ./install.sh`.

---

## Recording other people

Laws on recording a conversation differ by country and by context (one-party
vs all-party consent). Check what applies where you are, and tell the other
participants — for interviews and work calls, asking first is both the legal
and the decent thing to do.

---

## License

MIT — see [LICENSE](./LICENSE).
