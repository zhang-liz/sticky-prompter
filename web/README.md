# Sticky Prompter — web version

A full-screen browser teleprompter. Paste your script, pick a reading mode, and read — no install, no floating window, nothing leaves your machine.

## Try it now

**https://zhang-liz.github.io/sticky-prompter/** — deployed from this folder by GitHub Actions on every push to `main`.

## Or run it locally

```bash
cd web
python3 -m http.server 4173
```

Open **http://localhost:4173** in any modern browser. Voice mode additionally needs **Chrome or Edge** (Web Speech API); steady mode works everywhere.

## How to use

1. **Paste your script** into the text panel on the left.
2. Pick a **mode** in the top bar:
   - **Steady** — scrolls line by line at a speed you set (words-per-minute slider). Works in every browser.
   - **Voice** — follows along as you read aloud, highlighting where you are. Chrome/Edge only, asks for mic permission.
3. Hit **Start** (or <kbd>Space</kbd>). Click any word to jump there.

### Controls

| Control | What it does |
|---|---|
| **Steady / Voice** | choose auto-scroll or voice tracking |
| **Speed** | words per minute (steady mode) |
| **Flip ⇋ / ⥯** | mirror left–right (for a beam-splitter glass rig) and/or flip upside-down |
| **✎ Text** | show / hide the script panel for a clean full-screen read |
| **Size** | prompter font size |
| <kbd>Space</kbd> | start / pause |
| <kbd>Esc</kbd> | stop and return to the top |
| <kbd>↑</kbd> <kbd>↓</kbd> | nudge back / forward a few words |

Script and all settings persist in `localStorage`.

## Notes

- **Flip** is for physical teleprompter rigs: a beam-splitter glass needs the horizontal mirror so the reflection reads correctly; upside-down helps some mounts.
- Everything runs client-side. Voice mode uses the browser's own on-device/cloud speech recognition; nothing is sent anywhere by this app.
- For a floating, always-on-top, screen-share-invisible overlay, use the native macOS app in [`mac/`](../mac/).
