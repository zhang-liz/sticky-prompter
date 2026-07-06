<p align="center">
  <img src="docs/icon.png" width="128" alt="Sticky Prompter icon">
</p>

<h1 align="center">Sticky Prompter</h1>

<p align="center">
A voice-controlled sticky-note teleprompter that floats on top of any window.<br>
It listens as you speak and follows along with your script — no scrolling, no clicking.
</p>

<p align="center">
  <a href="https://github.com/zhang-liz/sticky-prompter/releases/latest"><img src="https://img.shields.io/github/v/release/zhang-liz/sticky-prompter?label=release&color=f7b733" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B%20·%20web-blue" alt="Platform: macOS 13+ and web">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="MIT license"></a>
</p>

<p align="center">
  <a href="https://github.com/zhang-liz/sticky-prompter/releases/latest/download/StickyPrompter.dmg"><b>⬇️&nbsp; Download for macOS</b></a>
  &nbsp;·&nbsp;
  <a href="https://zhang-liz.github.io/sticky-prompter/"><b>▶️&nbsp; Try it in your browser</b></a>
</p>

---

## Features

- <img src="docs/icons/mic.svg" width="16" height="16" alt=""> **Voice tracking** — read your script and the highlight follows you, word by word. Pause, ad-lib, or skip a sentence and it catches up.
- <img src="docs/icons/pin.svg" width="16" height="16" alt=""> **Always on top** — the note floats over Zoom, Meet, FaceTime, OBS, and full-screen apps. Park it right under your camera so your eyes stay near the lens.
- <img src="docs/icons/ghost.svg" width="16" height="16" alt=""> **Invisible in screen shares and recordings** (macOS app) — you see it, your audience doesn't.
- <img src="docs/icons/palette.svg" width="16" height="16" alt=""> **Any background color + transparency slider** — text auto-adjusts for readability.
- <img src="docs/icons/library.svg" width="16" height="16" alt=""> **Edit and live modes** — type your script directly on the note, then go live: every button disappears and only your words remain. Double-click to edit again.
- <img src="docs/icons/library.svg" width="16" height="16" alt=""> **Script library** — save scripts as plain text files, open `.txt`/`.md`/`.docx`, reload anytime.
- <img src="docs/icons/lock.svg" width="16" height="16" alt=""> **Private** — everything runs locally; speech recognition is Apple's (macOS) or the browser's (web). No accounts, no telemetry, no server.

## Install

### macOS

1. **[Download StickyPrompter.dmg](https://github.com/zhang-liz/sticky-prompter/releases/latest/download/StickyPrompter.dmg)** — universal binary (Apple Silicon + Intel), macOS 13+
2. Open the DMG and drag **Sticky Prompter** into **Applications**
3. On first launch macOS will block the app: go to **System Settings → Privacy & Security** and click **Open Anyway** (one time only)
4. When you first hit the mic button, allow **Microphone** and **Speech Recognition**

> [!NOTE]
> The "unverified developer" warning appears because the app isn't notarized — that requires a paid Apple Developer account. It's a one-time click, and the entire app is a single Swift file in this repo if you'd rather audit or build it yourself.

<details>
<summary><b>Build from source instead</b></summary>

<br>

Requires the Xcode Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/zhang-liz/sticky-prompter.git
cd sticky-prompter/mac
./build.sh install
```

That's it — launch **Sticky Prompter** from Spotlight. Details in [`mac/README.md`](mac/README.md).

</details>

### Web (any OS, nothing to install)

**[Open the web version →](https://zhang-liz.github.io/sticky-prompter/)** in Chrome or Edge, then use the pop-out button for an always-on-top floating note. It can't be hidden from screen shares or made transparent like the macOS app — see [`web/README.md`](web/README.md) for the full comparison.

<details>
<summary><b>Run it locally instead</b></summary>

<br>

It's a single HTML file with no build step and no dependencies:

```bash
git clone https://github.com/zhang-liz/sticky-prompter.git
cd sticky-prompter/web
python3 -m http.server 4173
```

Open **http://localhost:4173** in Chrome.

</details>

## Quick start

1. **Type or paste your script** straight onto the note (or press <kbd>⌘O</kbd> to open a `.txt`, `.md`, or `.docx` file)
2. Hit **Go Live** (or <kbd>Esc</kbd>) — the controls disappear and the mic starts listening
3. Start reading — the highlight follows your voice
4. Drag the note right under your camera; your audience never sees it

| Key (live mode) | Action |
|---|---|
| <kbd>←</kbd> / <kbd>→</kbd> | nudge back / forward a word |
| <kbd>↑</kbd> / <kbd>↓</kbd> | jump about a line |
| <kbd>R</kbd> | restart from the top |
| <kbd>E</kbd> or double-click | back to edit mode |
| <kbd>⌘S</kbd> | save the script |

## How the voice tracking works

The script is tokenized and matched word-by-word against the live transcription:

- a spoken word only advances the tracker if it matches the **next** script word (fuzzy matching handles mis-transcriptions on words of 4+ letters; short words must match exactly)
- **skipping ahead** requires two consecutive spoken words matching two consecutive script words within a 12-word lookahead
- each utterance is re-evaluated from its start as the recognizer revises itself, and the macOS app **biases recognition toward your script's vocabulary** for better accuracy on names and jargon

## Contributing

The codebase is deliberately tiny: the macOS app is one Swift file ([`mac/main.swift`](mac/main.swift)) with a shell build script, and the web version is one HTML file ([`web/index.html`](web/index.html)) with zero dependencies. Issues and pull requests are welcome.

Run the matcher test suite (no mic needed):

```bash
./StickyPrompter.app/Contents/MacOS/StickyPrompter --selftest
```

## License

[MIT](LICENSE) © Liz Zhang
