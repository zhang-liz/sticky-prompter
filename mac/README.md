# Sticky Prompter (native macOS app)

The native macOS version of Sticky Prompter — a voice-controlled sticky-note teleprompter with **true adjustable transparency** that floats on top of any active window (Zoom, Meet, FaceTime, OBS, full-screen apps included).

Advantages over the web version:

- **Real transparency** — opacity slider makes the note as see-through as you like; text stays crisp
- **Always on top of everything**, including full-screen apps and all Spaces
- **Invisible in screen shares & recordings** by default (`NSWindow.sharingType = .none`) — toggle from the menu bar icon
- **On-device / Apple speech recognition** — nothing leaves your Mac beyond Apple's recognizer
- **Click-through mode** — the note ignores your mouse entirely (toggle from the 📝 menu bar icon)

## Build & run

```bash
cd mac
./build.sh            # build only
./build.sh install    # build + install to /Applications
```

Requires Xcode Command Line Tools (`xcode-select --install` if missing). The build produces a universal binary (Apple Silicon + Intel). The first time you hit the mic button, macOS will ask for **Microphone** and **Speech Recognition** permissions — allow both.

## Controls

The script starts at the very top of the window — park the note right under your camera. All controls live in the bar at the bottom:

| Control | Action |
|---|---|
| 🎤 | voice tracking on/off |
| ↺ | restart from top |
| A- / A+ | text size |
| color swatch | background color (text auto-adjusts light/dark for readability) |
| ✏️ | scripts — edit, save to library, load, delete |
| slider | background transparency |

Keyboard (when the note is focused): `space` mic, `←`/`→` nudge a word, `↑`/`↓` jump ~a line, `R` restart, `E` edit.

Drag the note anywhere by its background. Resize from any edge. Position, script, and settings persist across launches.

**Menu bar icon (📝):** click-through mode, hide/show from screen recordings, re-show the note, quit.

## Script library

The ✏️ editor has a saved-scripts sidebar. Give a script a name and hit **Save to library**; click any saved name to load it; the trash icon moves it to the Trash. Scripts are plain `.txt` files in `~/Library/Application Support/Sticky Prompter/Scripts/`, so you can also drop files there yourself or edit them in any text editor. The note's footer shows the name of the loaded script.

## How the tracking works

One spoken word only advances the highlight if it matches the *next* script word (with fuzzy matching for mis-transcriptions on words of 4+ letters); intentionally skipping ahead requires two consecutive spoken words matching two consecutive script words within a 12-word lookahead. Each utterance is re-evaluated from its start as the recognizer revises its transcription, recognition is biased toward the script's own vocabulary, and after a pause the position is sealed and a fresh recognition task starts.

Verify the matcher without a mic:

```bash
./StickyPrompter.app/Contents/MacOS/StickyPrompter --selftest
```
