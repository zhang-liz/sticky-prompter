# Sticky Prompter (native macOS app)

The native macOS version of Sticky Prompter — a voice-controlled sticky-note teleprompter with **true adjustable transparency** that floats on top of any active window (Zoom, Meet, FaceTime, OBS, full-screen apps included).

Advantages over the web version:

- **Real transparency** — opacity slider makes the note as see-through as you like; text stays crisp
- **Always on top of everything**, including full-screen apps and all Spaces
- **Invisible in screen shares & recordings** by default (`NSWindow.sharingType = .none`) — toggle from the menu bar icon
- **Apple speech recognition** — the same recognizer system dictation uses, biased toward your script's own vocabulary for better accuracy on names and jargon
- **Click-through mode** — the note ignores your mouse entirely (toggle from the <img src="../docs/icons/sticky-note.svg" width="15" height="15" alt=""> menu bar icon)

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
| <img src="../docs/icons/save.svg" width="15" height="15" alt=""> | save the script (`⌘S`) |
| <img src="../docs/icons/folder-open.svg" width="15" height="15" alt=""> | open a file as the script (`⌘O`) |
| <img src="../docs/icons/play.svg" width="15" height="15" alt=""> Go Live | switch to live mode (or press `Esc`) |

The script library lives in **File ▸ Scripts Library…** (`⌘L`).

**Live mode**: all buttons disappear — just your script and a thin progress bar. The current sentence pins to the top edge, right under your camera. Controls are the keyboard and the menu-bar icon:

- `space` mic on/off · `←`/`→` nudge a word · `↑`/`↓` jump ~a line · `R` restart
- **click any word** to read from there — the fastest way back in sync after a detour
- **double-click the text** (or press `E`) to go back to edit mode

Drag the note anywhere by its background. Resize from any edge. Position, script, colors, and all toggles persist across launches. Closing the note hides it — bring it back from the menu-bar icon or by reopening the app; quit from the menu-bar icon.

**Menu bar icon** (<img src="../docs/icons/sticky-note.svg" width="15" height="15" alt="">)**:** edit/live toggle, voice tracking, restart, click-through mode, hide/show from screen recordings, re-show the note, quit.

## Script library

The library (**File ▸ Scripts Library…**, `⌘L`) has a saved-scripts sidebar. Give a script a name and hit **Save to library**; click any saved name to load it; the trash icon moves it to the Trash. Scripts are plain `.txt` files in `~/Library/Application Support/Sticky Prompter/Scripts/`, so you can also drop files there yourself or edit them in any text editor. The note's footer shows the name of the loaded script.

`⌘S` saves the note back to wherever it came from. To keep that script and start another, use **Save Script As…** (`⇧⌘S`) for a copy under a new name, or **New Script** (`⌘N`) for a blank note with no save target, so the next `⌘S` asks for a name instead of rewriting the last one.

## Writing a script

Scripts are plain text. Two conventions:

- `# A heading` starts a section, shown bigger and bold
- `[anything in brackets]` is a stage direction: `[pause]`, `[smile]`, `[look at the camera]`. It shows on the note but is never expected to be spoken, so the highlight steps over it and it never biases the recognizer

## How the tracking works

One spoken word only advances the highlight if it matches the *next* script word (with fuzzy matching for mis-transcriptions on words of 4+ letters); intentionally skipping ahead requires two consecutive spoken words matching two consecutive script words within a 12-word lookahead. Each utterance is re-evaluated from its start as the recognizer revises its transcription, recognition is biased toward the script's own vocabulary, and after a pause the position is sealed and a fresh recognition task starts.

Verify the matcher without a mic:

```bash
./StickyPrompter.app/Contents/MacOS/StickyPrompter --selftest
```
