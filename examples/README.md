# Hark recipes

Small, copy-and-adapt `zsh` scripts that wrap the `hark` binary for common
workflows. They are **examples, not an installed part of Hark** — read one,
tweak it to taste, and drop it somewhere on your `PATH`.

| Script | What it does |
| --- | --- |
| [`hark-meeting`](hark-meeting) | Record a meeting (system + mic) interactively, then summarize the transcript with a fabric-ai pattern you pick from an `fzf` menu afterwards. |
| [`hark-note`](hark-note) | Quick spoken voice memo → timestamped audio + transcript. |
| [`hark-dictate`](hark-dictate) | Speak for a few seconds → text on your clipboard. |
| [`hark-meet.user.js`](hark-meet.user.js) | Browser userscript (Tampermonkey): auto-record Google Meet calls and mirror your Meet mic mute to the recording. |

## Install

```sh
# Make them executable and put them on your PATH (adjust the target dir):
chmod +x examples/hark-*
mkdir -p ~/.local/bin
cp examples/hark-meeting examples/hark-note examples/hark-dictate ~/.local/bin/
# ensure ~/.local/bin is on PATH (e.g. in ~/.zshrc):
#   export PATH="$HOME/.local/bin:$PATH"
```

Then:

```sh
hark-meeting "Team Sync"
hark-note "idea about the parser"
hark-dictate 15
```

### Browser userscript (Tampermonkey)

`hark-meet.user.js` installs differently — it runs in your browser, not on your
`PATH`. Install [Tampermonkey](https://www.tampermonkey.net/), then open the raw
[`hark-meet.user.js`](hark-meet.user.js) for a one-click install (it also
self-updates from that URL). It needs the remote-control agent running —
`brew services start hark` or `hark --remote-control 8473 -C ~/Recordings` — and
mirrors your Google Meet mic mute to the recording. See
[`docs/remote-control.md`](../docs/remote-control.md#reference-google-meet-userscript-tampermonkey).

## Prerequisites

- **`hark`** — built from this repo (`make build`) or installed on your `PATH`.
- **A transcription model** — the default `whisper` engine needs a local
  whisper.cpp model (`hark models download base.en`). Override per the usual
  `--engine`/`$HARK_ENGINE` / `hark config`.
- **`fabric-ai`** — only for `hark-meeting`'s summary step
  (<https://github.com/danielmiessler/fabric>), with a configured model.
- **`fzf`** — optional, for `hark-meeting`'s pattern picker (`brew install fzf`).
  Without it the summary just uses `summarize_meeting`.
- **macOS permissions** — microphone for all of them; the **System Audio
  Recording** permission for `hark-meeting` (it uses `--system`). See
  [`docs/permissions.md`](../docs/permissions.md).
- Acoustic speaker diarization (the `Speaker N` labels in `hark-meeting`) needs
  Apple Silicon; on Intel it falls back to deterministic You/Others attribution.

## Customizing

Each script reads a few environment variables (documented in its header
comment) — output directory, fabric pattern/model, capture length. For example:

```sh
HARK_MEETINGS_DIR=~/Meetings FABRIC_PATTERN=extract_recommendations \
  hark-meeting "1:1 with Sam"
```

For `hark-meeting`, `$FABRIC_PATTERN` doubles as an opt-out: set it and the
summary uses that pattern directly; leave it unset and the script asks which
pattern to use (via `fzf`, with the pattern's text in a preview pane) once the
recording is finished — so you can decide after hearing how the meeting actually
went. Pressing Esc there keeps `summarize_meeting`. To always skip the prompt,
export `FABRIC_PATTERN=summarize_meeting` in your shell profile.

Because `hark` itself honors `$HARK_*` and `hark config`, you can set the
engine, model, language, and more globally without touching the scripts.
