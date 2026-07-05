# Two-Mode UI (Edit / Live) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single-mode UI with an Edit mode (normal window chrome, direct text editing) and a Live mode (chrome-free text-only note), plus persist the menu-bar toggles.

**Architecture:** Everything lives in `mac/main.swift` (existing single-file pattern — keep it). `PrompterModel` gains a `live: Bool` published flag and a position-preserving `rebuild`. `ContentView` renders two layouts switched on `m.live`. `AppDelegate` observes `model.$live` via Combine and flips the NSPanel chrome (traffic lights, title bar, miniaturizable). Menu-bar toggles round-trip through `UserDefaults`.

**Tech Stack:** Swift / AppKit / SwiftUI, no dependencies. Tests = built-in `--selftest` headless runner.

## Global Constraints

- Single file `mac/main.swift`; follow its existing style (MARK sections, no comments-noise).
- macOS availability: use `if #available(macOS 13.0, *)` guards for 13+ APIs (existing pattern).
- `--selftest` must print `ALL PASS` and exit 0.
- App launches in Edit mode; mode is never persisted.
- Build: `cd mac && ./build.sh` must succeed (universal binary).
- Commits: small, atomic, concise messages, author Liz Zhang (repo default), no co-author trailers (repo convention).

---

### Task 1: Model — `live` flag + position-preserving rebuild + selftest coverage

**Files:**
- Modify: `mac/main.swift` (PrompterModel ~lines 51–120, `rebuild()` ~163–206, `runSelfTest()` ~707)

**Interfaces:**
- Produces: `m.live: Bool` (published, default `false`), `m.goLive()`, `m.enterEdit()`, `rebuild(resetPos: Bool = true)`.

- [ ] **Step 1: Add failing selftest cases** — in `runSelfTest()` before the final `print`, add:

```swift
// rebuild(resetPos: false) clamps instead of resetting
m.jump(to: 30)
m.script = "Hey everyone, welcome back."
m.rebuild(resetPos: false)
expect("edit clamps pos", m.pos, 4)          // 4 tokens now
m.script = PrompterModel.sample
m.rebuild()
expect("plain rebuild resets", m.pos, 0)
// goLive commits + keeps clamped position; enterEdit stops listening
m.jump(to: 5)
m.goLive()
expect("goLive keeps pos", m.pos, 5)
if m.live != true { fails += 1; print("FAIL goLive sets live") } else { print("PASS goLive sets live") }
m.enterEdit()
if m.live != false { fails += 1; print("FAIL enterEdit clears live") } else { print("PASS enterEdit clears live") }
```

- [ ] **Step 2: Run selftest, verify it fails to compile** (no `rebuild(resetPos:)`, no `goLive`): `cd mac && swiftc -parse main.swift` → errors expected.

- [ ] **Step 3: Implement** — in `PrompterModel`:
  - Add `@Published var live = false` next to `editing`.
  - Change signature `func rebuild(resetPos: Bool = true)`; at the end replace `pos = 0; anchor = 0` with:

```swift
if resetPos { pos = 0 } else { pos = min(pos, tokens.count) }
anchor = pos
```

  - Add:

```swift
func goLive() {
    if !scriptName.trimmingCharacters(in: .whitespaces).isEmpty {
        saveScript(scriptName, text: script)   // keep library file in sync
    }
    rebuild(resetPos: false)
    live = true
}

func enterEdit() {
    if listening { stopListening() }
    live = false
}
```

- [ ] **Step 4: Build + run selftest**: `cd mac && ./build.sh && ./StickyPrompter.app/Contents/MacOS/StickyPrompter --selftest` → `ALL PASS`.

- [ ] **Step 5: Commit** `git commit -m "Model: live/edit mode state, position-preserving rebuild"`.

### Task 2: Persist menu-bar toggles

**Files:**
- Modify: `mac/main.swift` (`PrompterModel.init` ~83, `persist()` ~111, `AppDelegate` ~603–678)

**Interfaces:**
- Produces: `m.captureHidden: Bool` (published, default `true`), both toggles restored at launch.

- [ ] **Step 1: Model** — add `@Published var captureHidden = true`; in `init` load `clickThrough = d.bool(forKey: "clickThrough")`, `captureHidden = d.object(forKey: "captureHidden") as? Bool ?? true`; in `persist()` save both.

- [ ] **Step 2: AppDelegate** — in `applicationDidFinishLaunching` after `panel = p`:

```swift
p.sharingType = model.captureHidden ? .none : .readOnly
p.ignoresMouseEvents = model.clickThrough
```

In `setupStatusItem()` set initial `ct.state = model.clickThrough ? .on : .off` and `hide.state = model.captureHidden ? .on : .off`. Rewrite the two toggle actions to go through the model + `persist()`:

```swift
@objc func toggleClickThrough(_ sender: NSMenuItem) {
    model.clickThrough.toggle()
    panel.ignoresMouseEvents = model.clickThrough
    sender.state = model.clickThrough ? .on : .off
    model.persist()
}

@objc func toggleCaptureHidden(_ sender: NSMenuItem) {
    model.captureHidden.toggle()
    panel.sharingType = model.captureHidden ? .none : .readOnly
    sender.state = model.captureHidden ? .on : .off
    model.persist()
}
```

- [ ] **Step 3: Build + selftest** (same commands, `ALL PASS`), manual: toggle both, relaunch, states restored.

- [ ] **Step 4: Commit** `git commit -m "Persist click-through and capture-hidden across launches"`.

### Task 3: ContentView — two layouts

**Files:**
- Modify: `mac/main.swift` (`ContentView` ~379–509)

**Interfaces:**
- Consumes: `m.live`, `m.goLive()`, `m.enterEdit()` from Task 1.
- Produces: edit layout (control strip top + `TextEditor`), live layout (script + progress only, double-click → `enterEdit`).

- [ ] **Step 1: Restructure `body`:**

```swift
var body: some View {
    VStack(spacing: 0) {
        if m.live {
            scriptView
            footer
        } else {
            editBar
            editor
        }
    }
    .background(bgColor)
    .sheet(isPresented: $m.editing) { EditorView(m: m) }
}
```

`scriptView` = the existing `ScrollViewReader` block, plus on the `ScrollView`:

```swift
.contentShape(Rectangle())
.onTapGesture(count: 2) { m.enterEdit() }
```

`editor` = direct editing surface:

```swift
var editor: some View {
    TextEditor(text: Binding(get: { m.script }, set: { m.script = $0 }))
        .font(.system(size: m.fontSize, weight: .medium, design: .rounded))
        .foregroundColor(mainColor)
        .modifier(ClearTextEditor())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
}

struct ClearTextEditor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 13.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}
```

`editBar` = current `header` controls, with the mic button removed from edit mode (tracking needs committed tokens) and a prominent Go Live button appended:

```swift
var editBar: some View {
    HStack(spacing: 8) {
        Text(m.scriptName.isEmpty ? "STICKY PROMPTER" : m.scriptName.uppercased())
            .font(.system(size: 10, weight: .bold)).kerning(1).lineLimit(1)
            .foregroundColor(mainColor.opacity(0.5))
        Spacer()
        ctl("textformat.size.smaller", help: "Smaller text") { m.fontSize = max(13, m.fontSize - 2); m.persist() }
        ctl("textformat.size.larger", help: "Bigger text") { m.fontSize = min(48, m.fontSize + 2); m.persist() }
        ColorPicker("", selection: bgBinding).labelsHidden().frame(width: 26).help("Background color")
        Slider(value: Binding(get: { m.bgOpacity }, set: { m.bgOpacity = $0; m.persist() }), in: 0.05...1)
            .frame(width: 64).help("Background transparency")
        ctl("books.vertical", help: "Script library — save, load, delete") { m.editing = true }
        Button { m.goLive() } label: {
            Label("Go Live", systemImage: "play.fill")
                .font(.system(size: 11, weight: .bold))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(hiBG).foregroundColor(hiFG).cornerRadius(6)
        }
        .buttonStyle(.plain).help("Start prompting (Esc)")
        .keyboardShortcut(.defaultAction)
    }
    .padding(.horizontal, 10).padding(.vertical, 6)
    .background(mainColor.opacity(0.06))
}
```

(`bgBinding` = the existing ColorPicker binding extracted to a computed property; mic/restart buttons live only in the old header, which is deleted — live mode is keyboard/menu-driven per spec, footer still shows status.)

Live mode auto-starts the mic? No — spec keeps explicit control: `goLive()` does not start listening; space starts it. Footer status shows hint when idle in live mode: in `footer`, when `m.status.isEmpty && m.live && !m.listening`, show `"space = mic · double-click = edit"` at the same styling.

- [ ] **Step 2: Build + selftest** → `ALL PASS`.

- [ ] **Step 3: Manual check** — edit mode types directly; Go Live shows tracker; double-click returns.

- [ ] **Step 4: Commit** `git commit -m "UI: edit mode with direct text editing, chrome-free live mode"`.

### Task 4: AppDelegate — window chrome + keys + menu follow the mode

**Files:**
- Modify: `mac/main.swift` (`AppDelegate` ~603–703)

**Interfaces:**
- Consumes: `model.$live`.

- [ ] **Step 1: Chrome switching** — add `import Combine` already present; in `AppDelegate` add `var subs = Set<AnyCancellable>()`; in `applicationDidFinishLaunching` after `panel = p`:

```swift
model.$live
    .receive(on: DispatchQueue.main)
    .sink { [weak self] live in self?.applyMode(live: live) }
    .store(in: &subs)
applyMode(live: model.live)
```

```swift
func applyMode(live: Bool) {
    guard let p = panel else { return }
    if live {
        p.styleMask.remove(.miniaturizable)
        p.titleVisibility = .hidden
    } else {
        p.styleMask.insert([.titled, .miniaturizable])
        p.titleVisibility = .visible
        p.title = "Sticky Prompter"
        // click-through would make editing impossible
        if model.clickThrough { model.clickThrough = false; model.persist() }
        p.makeKeyAndOrderFront(nil)
    }
    p.ignoresMouseEvents = live && model.clickThrough
    p.becomesKeyOnlyIfNeeded = live
    for b: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
        p.standardWindowButton(b)?.isHidden = live
    }
    statusItem?.menu?.item(withTag: 1)?.state = model.clickThrough ? .on : .off
}
```

Remove the three `isHidden = true` lines from `applicationDidFinishLaunching` (now handled by `applyMode`). Tag the click-through menu item `ct.tag = 1`.

- [ ] **Step 2: Keys** — in `setupKeys()`:
  - Guard becomes: `guard let self = self, !self.model.editing else { return ev }`
  - Before the NSTextView first-responder early-return, intercept Esc so it works while the editor has focus:

```swift
if ev.keyCode == 53 { // Esc
    if !self.model.live { self.model.goLive(); return nil }
    return ev
}
```

  - Space/R/E/arrows: only act when `self.model.live` (in edit mode they must type into the editor). `case "e": self.model.enterEdit()` in live mode.

- [ ] **Step 3: Menu-bar item** — in `setupStatusItem()` add at the top of the menu:

```swift
let mode = NSMenuItem(title: "Edit script", action: #selector(toggleMode), keyEquivalent: "e")
mode.target = self
menu.addItem(mode)
menu.addItem(.separator())
```

```swift
@objc func toggleMode() {
    if model.live { model.enterEdit() } else { model.goLive() }
    panel.makeKeyAndOrderFront(nil)
}
```

- [ ] **Step 4: Build + selftest** → `ALL PASS`.

- [ ] **Step 5: Commit** `git commit -m "Window chrome, shortcuts and menu follow edit/live mode"`.

### Task 5: Thorough bug pass

**Files:**
- Modify: `mac/main.swift` (fixes as found), `README.md` + `mac/README.md` (controls/docs drift)

- [ ] **Step 1: Build + selftest** → `ALL PASS`.
- [ ] **Step 2: Systematic manual matrix** — install (`./build.sh install`), then walk: launch defaults; every edit-bar control; library save/load/delete incl. names with `/` and `:`; Go Live/double-click round-trips incl. mid-listen; Esc from editor focus; space/R/arrows in live; E in edit types "e" into text; empty script; 5k-word script; extreme colors (white/black) and 5% opacity; traffic lights (close quits, minimize, zoom); click-through on → live → back to edit auto-disables; capture-hidden + click-through survive relaunch; window frame survives relaunch; mode always starts edit.
- [ ] **Step 3: Fix each bug found** — one commit per logical fix, rerun selftest after each.
- [ ] **Step 4: Update docs** — README sections describing pen icon / controls / shortcuts to match the two-mode UI. Commit `git commit -m "Docs: two-mode UI"`.
