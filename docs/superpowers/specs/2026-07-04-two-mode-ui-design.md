# Two-mode UI (Edit / Live) + settings persistence + bug pass

**Date:** 2026-07-04
**Target:** mac app only (`mac/main.swift`)

## Problem

- Window buttons (close/minimize/zoom) are hidden by design; users read this as "broken" and can't close the window.
- Editing the script requires opening the pen-icon sheet; users expect to type directly on the note.
- Menu-bar toggles (click-through, hide-from-screen-sharing) reset on every launch.

## Design

Two explicit UI modes, replacing the current single mode + editor sheet.

### Edit mode (setup)

- Standard window chrome: visible title bar and close/minimize/zoom traffic lights.
- Script text is directly editable in the window via `TextEditor`, styled with the
  note's font/colors on the same translucent background.
- Full control strip visible: mic toggle, restart, font size ±, background color,
  transparency slider, pen icon (library sheet for save/load/delete), and a
  prominent **Go Live** button.
- App launches in edit mode (buttons discoverable on first run).

### Live mode (performing)

- All chrome hidden: no traffic lights, no title bar, no control strip.
  Only the script text and the thin progress bar are visible.
- Voice tracking keeps running; keyboard shortcuts still work
  (space = mic, R = restart, arrows = nudge, E = edit mode).
- **Double-click the text returns to edit mode** and auto-stops the mic.
  Backups: E key, 📝 menu-bar item.

### Mode transitions

- Edit → Live: commit the draft (rebuild tokens/rows), clamp the reading
  position to the new token count instead of resetting to 0.
- Live → Edit: stop listening, load current script into the editor.
- Window frame is unchanged by mode switches. Mode itself is not persisted;
  every launch starts in edit mode.

### Settings persistence

- Persist `clickThrough` and `sharingType` (hide-from-capture) in
  `UserDefaults`; restore at launch and sync menu-item checkmarks.
- Existing persisted settings (script, name, font size, opacity, color,
  window frame) unchanged.

### Library

- Pen-icon sheet is kept solely for library management (save/load/delete named
  scripts). Direct editing covers text changes; if the current script has a
  library name, committing an edit also rewrites its `.txt` file.

## Error handling

- Empty script after edit: keep tokens empty, show sample-free empty note;
  mic start still guarded by existing permission/status paths.
- Recognition/permission errors: unchanged existing status-line behavior.

## Testing

- `--selftest` matcher tests must keep passing.
- Manual pass over every control in both modes, keyboard shortcuts,
  library save/load/delete, mode transitions mid-listen, empty/huge scripts,
  extreme colors/transparency, click-through + capture-hidden toggles across
  relaunch.
- Fix all bugs found; retest after fixes.

## Out of scope

- Web version.
- Whisper transcription, App Store packaging, script quick-switcher.
