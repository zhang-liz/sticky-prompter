# Sticky Prompter — web version

The browser version of Sticky Prompter. It runs in Chrome and uses the Web Speech API for voice tracking and Document Picture-in-Picture for an always-on-top floating note.

No build step, no dependencies, and no data leaves your machine beyond the browser's own speech recognition.

## Try it now

**https://zhang-liz.github.io/sticky-prompter/** — deployed from this folder by GitHub Actions on every push to `main`.

## Or run it locally

```bash
cd web
python3 -m http.server 4173
```

Open **http://localhost:4173** in **Chrome** (or Edge). Chrome is required for the two key APIs:

- **Web Speech API** — free real-time speech recognition for voice tracking
- **Document Picture-in-Picture** — the always-on-top floating window

## How to use

1. Paste your script (or click *Load sample script*) → **Create sticky note**
2. Click the **pop-out button (⧉)** on the note — it becomes a mini window that stays on top of every app, including your video call. Park it right under your camera so your eyes stay near the lens.
3. Hit the **mic** and just read. Click any word to jump the tracker there.

### Controls

| Key | Action |
|---|---|
| `space` | mic on/off (or play/pause in auto-scroll mode) |
| `←` / `→` | nudge position by a word |
| `↑` / `↓` | jump ~a line back/forward |
| `R` | restart from top |
| `E` | edit script |

### Settings (gear icon)

- **Themes:** classic yellow sticky, pink, or dark glass
- **Handwritten or clean font**, text size, note width
- **Opacity** slider (applies to the on-page note; the pop-out window is always readable)
- **Auto-scroll mode** with speed slider — timed fallback for browsers without speech support
- **10 recognition languages**

Script and all settings persist in `localStorage`.

## Notes & limits

- The pop-out window is always-on-top but has an opaque background (Chrome doesn't allow transparent PiP windows). For a true see-through overlay, use the native macOS app in [`mac/`](../mac/).
- Chrome's speech recognition restarts automatically after silence; the app handles this so the mic stays hot until you turn it off.
