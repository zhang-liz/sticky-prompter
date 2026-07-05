# Sticky Prompter (native macOS app)

The native macOS version of Sticky Prompter — a voice-controlled sticky-note teleprompter with **true adjustable transparency** that floats on top of any active window (Zoom, Meet, FaceTime, OBS, full-screen apps included).

Advantages over the web version:

- **Real transparency** — opacity slider makes the note as see-through as you like; text stays crisp
- **Always on top of everything**, including full-screen apps and all Spaces
- **Invisible in screen shares & recordings** by default (`NSWindow.sharingType = .none`) — toggle from the menu bar icon
- **On-device / Apple speech recognition** — nothing leaves your Mac beyond Apple's recognizer
- **Click-through mode** — the note ignores your mouse entirely (toggle from the 📝 menu bar icon)

## Install

**Easiest:** [download StickyPrompter.dmg](https://github.com/zhang-liz/sticky-prompter/releases/latest/download/StickyPrompter.dmg) from the latest release, open it, and drag the app to **Applications**. On first launch, approve it under **System Settings → Privacy & Security → Open Anyway** (the app isn't notarized).

**Or build from source:**

```bash
cd mac
./build.sh            # build only
./build.sh install    # build + install to /Applications
```

Requires Xcode Command Line Tools (`xcode-select --install` if missing). The build produces a universal binary (Apple Silicon + Intel). The first time you hit the mic button, macOS will ask for **Microphone** and **Speech Recognition** permissions — allow both.

## Two modes

**Edit mode** (how the app opens): a normal window with close/minimize/zoom buttons. Type your script straight into the note. The top bar has:

| Control | Action |
|---|---|
| A- / A+ | text size |
| color swatch | background color (text auto-adjusts light/dark for readability) |
| slider | background transparency |
| 📚 | script library — save, load, delete named scripts |
| ▶ Go Live | switch to live mode (or press `Esc`) |

**Live mode**: all buttons disappear — just your script and a thin progress bar. The current sentence pins to the top edge, right under your camera. Controls are the keyboard and the menu-bar icon:

- `space` mic on/off · `←`/`→` nudge a word · `↑`/`↓` jump ~a line · `R` restart
- **double-click the text** (or press `E`) to go back to edit mode

Drag the note anywhere by its background. Resize from any edge. Position, script, colors, and all toggles persist across launches. Closing the note hides it — bring it back from the menu-bar icon or by reopening the app; quit from the menu-bar icon.

**Menu bar icon (📝):** edit/live toggle, voice tracking, restart, click-through mode, hide/show from screen recordings, re-show the note, quit.

## Script library

The 📚 library has a saved-scripts sidebar. Give a script a name and hit **Save to library**; click any saved name to load it; the trash icon moves it to the Trash. Scripts are plain `.txt` files in `~/Library/Application Support/Sticky Prompter/Scripts/`, so you can also drop files there yourself or edit them in any text editor. The note's footer shows the name of the loaded script.

## How the tracking works

One spoken word only advances the highlight if it matches the *next* script word (with fuzzy matching for mis-transcriptions on words of 4+ letters); intentionally skipping ahead requires two consecutive spoken words matching two consecutive script words within a 12-word lookahead. Each utterance is re-evaluated from its start as the recognizer revises its transcription, recognition is biased toward the script's own vocabulary, and after a pause the position is sealed and a fresh recognition task starts.

Verify the matcher without a mic:

```bash
./StickyPrompter.app/Contents/MacOS/StickyPrompter --selftest
```
