import AppKit
import SwiftUI
import Speech
import AVFoundation
import Combine

// MARK: - Text utilities

func normWord(_ s: String) -> String {
    var out = ""
    for sc in s.lowercased().unicodeScalars {
        if CharacterSet.alphanumerics.contains(sc) || sc == "'" { out.unicodeScalars.append(sc) }
    }
    return out
}

/// Fuzzy word match: exact for short words, edit-distance <= 1 / prefix for longer ones.
/// Short words must match exactly, otherwise fillers like "so" match "to" and jump the tracker.
func near(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    let la = a.count, lb = b.count
    if la < 4 || lb < 4 { return false }
    if abs(la - lb) > 1 { return false }
    if a.hasPrefix(b) || b.hasPrefix(a) { return true }
    let aa = Array(a), bb = Array(b)
    var i = 0, j = 0, edits = 0
    while i < la && j < lb {
        if aa[i] == bb[j] { i += 1; j += 1; continue }
        edits += 1
        if edits > 1 { return false }
        if la > lb { i += 1 }
        else if lb > la { j += 1 }
        else { i += 1; j += 1 }
    }
    return edits + (la - i) + (lb - j) <= 1
}

// MARK: - Model

struct Token { let text: String; let norm: String }
struct Para: Identifiable { let id: Int; let range: Range<Int> }

enum Theme: String { case dark, yellow }

final class PrompterModel: NSObject, ObservableObject {
    @Published var script: String
    @Published var pos = 0
    @Published var fontSize: Double
    @Published var bgOpacity: Double
    @Published var theme: Theme
    @Published var listening = false
    @Published var editing = false
    @Published var status = ""
    @Published var clickThrough = false

    var tokens: [Token] = []
    var paras: [Para] = []
    var vocab: [String] = []

    private var anchor = 0
    private var pending: [String] = []
    private let lookahead = 12
    private let pendingCap = 4

    // speech
    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var taskGen = 0   // stale-task guard: cancelled tasks still fire callbacks

    override init() {
        let d = UserDefaults.standard
        script = d.string(forKey: "script") ?? PrompterModel.sample
        fontSize = d.object(forKey: "fontSize") as? Double ?? 22
        bgOpacity = d.object(forKey: "bgOpacity") as? Double ?? 0.65
        theme = Theme(rawValue: d.string(forKey: "theme") ?? "dark") ?? .dark
        super.init()
        rebuild()
    }

    static let sample = """
    Hey everyone, welcome back to the channel!

    Today I want to show you something I have been really excited about. We are going to build a tiny app together, and by the end of this video you will be able to ship your own version in under an hour.

    Before we dive in, a quick note. Everything I show today is free and open source, and the link to the full code is in the description below.
    """

    func persist() {
        let d = UserDefaults.standard
        d.set(script, forKey: "script")
        d.set(fontSize, forKey: "fontSize")
        d.set(bgOpacity, forKey: "bgOpacity")
        d.set(theme.rawValue, forKey: "theme")
    }

    func rebuild() {
        tokens = []
        paras = []
        var pid = 0
        for line in script.components(separatedBy: "\n") {
            let words = line.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            if words.isEmpty { continue }
            let start = tokens.count
            for w in words {
                let n = normWord(w)
                if n.isEmpty, !tokens.isEmpty, tokens.count > start {
                    // punctuation-only fragment: glue to the previous word
                    let prev = tokens.removeLast()
                    tokens.append(Token(text: prev.text + " " + w, norm: prev.norm))
                } else {
                    tokens.append(Token(text: w, norm: n))
                }
            }
            if tokens.count > start {
                paras.append(Para(id: pid, range: start..<tokens.count))
                pid += 1
            }
        }
        // vocabulary biasing: prime the recognizer with the script's words,
        // longest (rarest) first — big accuracy win for names/jargon
        var seen = Set<String>()
        vocab = tokens.map { $0.norm }
            .filter { $0.count >= 3 && seen.insert($0).inserted }
            .sorted { $0.count > $1.count }
        if vocab.count > 100 { vocab = Array(vocab.prefix(100)) }
        pos = 0
        anchor = 0
        pending = []
        persist()
    }

    var currentParaID: Int {
        for p in paras where p.range.contains(min(pos, max(0, tokens.count - 1))) { return p.id }
        return paras.last?.id ?? 0
    }

    var progress: Double { tokens.isEmpty ? 0 : Double(pos) / Double(tokens.count) }

    // MARK: matching (same algorithm as the web version)
    // - one spoken word advances only if it matches the NEXT script word
    // - skipping ahead requires two consecutive spoken words matching two
    //   consecutive script words inside the lookahead window

    private func consume(_ raw: String) {
        let w = normWord(raw)
        if w.isEmpty { return }
        if pos < tokens.count, near(w, tokens[pos].norm) {
            pos += 1
            pending = []
            return
        }
        // one garbled/missed word while otherwise in sync: resync on the next
        // word — but only on a content word (4+ letters), otherwise fillers
        // like "to"/"the" skip over unspoken words
        if pending.isEmpty, pos + 1 < tokens.count, w.count >= 4, near(w, tokens[pos + 1].norm) {
            pos += 2
            return
        }
        pending.append(w)
        if pending.count > pendingCap { pending.removeFirst() }
        if pending.count >= 2 {
            let a = pending[pending.count - 2], b = pending[pending.count - 1]
            let end = min(pos + lookahead, tokens.count - 1)
            var j = pos
            while j < end {
                if near(a, tokens[j].norm) && near(b, tokens[j + 1].norm) {
                    pos = j + 2
                    pending = []
                    return
                }
                j += 1
            }
        }
    }

    /// Recompute the whole utterance from its anchor — the recognizer keeps
    /// revising earlier partial words, so incremental consumption drifts.
    func handleTranscript(_ words: [String], isFinal: Bool) {
        pos = anchor
        pending = []
        for w in words { consume(w) }
        if isFinal { anchor = pos }
        if pos >= tokens.count && !tokens.isEmpty { status = "🎉 End of script" }
        else if listening { status = "…" + words.suffix(6).joined(separator: " ") }
    }

    func jump(to i: Int) {
        pos = max(0, min(i, tokens.count))
        anchor = pos
        pending = []
        if listening { restartRecognition() } // drop the in-flight utterance
    }

    func nudge(_ delta: Int) { jump(to: pos + delta) }
    func restartFromTop() { jump(to: 0) }

    // MARK: speech

    func toggleMic() { listening ? stopListening() : startListening() }

    func startListening() {
        SFSpeechRecognizer.requestAuthorization { auth in
            DispatchQueue.main.async {
                guard auth == .authorized else { self.status = "⚠️ Speech recognition permission denied (System Settings → Privacy)"; return }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    DispatchQueue.main.async {
                        guard ok else { self.status = "⚠️ Microphone permission denied (System Settings → Privacy)"; return }
                        self.beginSession()
                    }
                }
            }
        }
    }

    private func beginSession() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let rec = recognizer, rec.isAvailable else { status = "⚠️ Speech recognizer unavailable"; return }
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { status = "⚠️ No microphone input found"; return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.request?.append(buf)
        }
        audioEngine.prepare()
        do { try audioEngine.start() } catch {
            status = "⚠️ Audio engine failed: \(error.localizedDescription)"
            return
        }
        listening = true
        anchor = pos
        pending = []
        status = "Listening…"
        startTask(rec)
    }

    private func startTask(_ rec: SFSpeechRecognizer) {
        taskGen += 1
        let gen = taskGen
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.contextualStrings = vocab   // bias recognition toward the script
        if #available(macOS 13.0, *) { req.addsPunctuation = false }
        // NOTE: server-based recognition is noticeably more accurate than
        // on-device, so we don't set requiresOnDeviceRecognition
        request = req
        task = rec.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, self.listening, gen == self.taskGen else { return }
                if let r = result {
                    let words = r.bestTranscription.segments.map { $0.substring }
                    self.handleTranscript(words, isFinal: r.isFinal)
                    self.scheduleSilenceRollover()
                    if r.isFinal { self.restartRecognition() }
                } else if error != nil {
                    self.restartRecognition()
                }
            }
        }
    }

    /// After a pause in speech, seal the utterance (anchor = pos) and start a
    /// fresh recognition task so the running transcript never grows unbounded.
    private func scheduleSilenceRollover() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            guard let self = self, self.listening else { return }
            self.restartRecognition()
        }
    }

    func restartRecognition() {
        guard listening, let rec = recognizer else { return }
        anchor = pos
        pending = []
        task?.cancel()   // its callback is ignored via the taskGen guard
        task = nil
        request?.endAudio()
        request = nil
        startTask(rec)
    }

    func stopListening() {
        listening = false
        silenceTimer?.invalidate()
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        anchor = pos
        pending = []
        status = ""
    }
}

// MARK: - Views

struct ContentView: View {
    @ObservedObject var m: PrompterModel

    var mainColor: Color { m.theme == .dark ? Color(white: 0.96) : Color(red: 0.29, green: 0.24, blue: 0.06) }
    var bgColor: Color {
        m.theme == .dark
            ? Color(red: 0.07, green: 0.07, blue: 0.10).opacity(m.bgOpacity)
            : Color(red: 1.0, green: 0.94, blue: 0.55).opacity(m.bgOpacity)
    }
    var hiBG: Color { m.theme == .dark ? Color(red: 0.97, green: 0.79, blue: 0.28) : Color(red: 1.0, green: 0.47, blue: 0.16) }
    var hiFG: Color { m.theme == .dark ? Color(red: 0.13, green: 0.10, blue: 0.0) : .white }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: m.fontSize * 0.6) {
                        ForEach(m.paras) { p in
                            Text(attributed(p))
                                .font(.system(size: m.fontSize, weight: .medium, design: .rounded))
                                .lineSpacing(m.fontSize * 0.35)
                                .fixedSize(horizontal: false, vertical: true)
                                .id(p.id)
                        }
                        Color.clear.frame(height: 260)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: m.pos) { _ in
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(m.currentParaID, anchor: UnitPoint(x: 0, y: 0.3))
                    }
                }
            }
            footer
        }
        .background(bgColor)
        .sheet(isPresented: $m.editing) { EditorView(m: m) }
    }

    func attributed(_ p: Para) -> AttributedString {
        var out = AttributedString()
        for i in p.range {
            var run = AttributedString(m.tokens[i].text + " ")
            if i < m.pos {
                run.foregroundColor = mainColor.opacity(0.32)
            } else if i == m.pos {
                run.foregroundColor = hiFG
                run.backgroundColor = hiBG
            } else {
                run.foregroundColor = mainColor
            }
            out += run
        }
        return out
    }

    var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(m.listening ? Color.red : mainColor.opacity(0.25))
                .frame(width: 8, height: 8)
            Text("STICKY PROMPTER")
                .font(.system(size: 10, weight: .bold))
                .kerning(1)
                .foregroundColor(mainColor.opacity(0.5))
            Spacer()
            ctl(m.listening ? "mic.fill" : "mic", help: "Voice tracking on/off (space)") { m.toggleMic() }
                .foregroundColor(m.listening ? .red : mainColor.opacity(0.75))
            ctl("arrow.counterclockwise", help: "Restart from top (R)") { m.restartFromTop() }
            ctl("textformat.size.smaller", help: "Smaller text") { m.fontSize = max(13, m.fontSize - 2); m.persist() }
            ctl("textformat.size.larger", help: "Bigger text") { m.fontSize = min(48, m.fontSize + 2); m.persist() }
            ctl("circle.lefthalf.filled", help: "Theme") { m.theme = m.theme == .dark ? .yellow : .dark; m.persist() }
            ctl("pencil", help: "Edit script (E)") { m.editing = true }
            Slider(value: Binding(get: { m.bgOpacity }, set: { m.bgOpacity = $0; m.persist() }), in: 0.05...1)
                .frame(width: 64)
                .help("Background transparency")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .padding(.top, 14) // room for hidden titlebar / traffic lights
        .background(mainColor.opacity(0.06))
    }

    func ctl(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.plain)
        .foregroundColor(mainColor.opacity(0.75))
        .help(help)
    }

    var footer: some View {
        VStack(spacing: 0) {
            if !m.status.isEmpty {
                Text(m.status)
                    .font(.system(size: 10))
                    .foregroundColor(mainColor.opacity(0.5))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
            GeometryReader { g in
                Rectangle().fill(hiBG)
                    .frame(width: g.size.width * m.progress)
            }
            .frame(height: 3)
            .background(mainColor.opacity(0.12))
        }
    }
}

struct EditorView: View {
    @ObservedObject var m: PrompterModel
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit script").font(.headline)
            TextEditor(text: $draft)
                .font(.system(size: 14))
                .frame(minWidth: 440, minHeight: 300)
            HStack {
                Spacer()
                Button("Cancel") { m.editing = false }
                Button("Save & restart") {
                    m.script = draft
                    m.rebuild()
                    m.editing = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear { draft = m.script }
    }
}

// MARK: - App delegate / window

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PrompterModel()
    var panel: NSPanel!
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 460),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.contentView = NSHostingView(rootView: ContentView(m: model))
        p.setFrameAutosaveName("StickyPrompterWindow")
        if p.frame.origin == .zero {
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                p.setFrameOrigin(NSPoint(x: f.maxX - 440, y: f.maxY - 500))
            }
        }
        p.makeKeyAndOrderFront(nil)
        panel = p

        setupStatusItem()
        setupKeys()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Sticky Prompter")
        let menu = NSMenu()
        let ct = NSMenuItem(title: "Click-through (ignore mouse)", action: #selector(toggleClickThrough), keyEquivalent: "t")
        ct.target = self
        menu.addItem(ct)
        let show = NSMenuItem(title: "Show note", action: #selector(showNote), keyEquivalent: "s")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Sticky Prompter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc func toggleClickThrough(_ sender: NSMenuItem) {
        model.clickThrough.toggle()
        panel.ignoresMouseEvents = model.clickThrough
        sender.state = model.clickThrough ? .on : .off
    }

    @objc func showNote() {
        panel.makeKeyAndOrderFront(nil)
    }

    func setupKeys() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self = self, !self.model.editing else { return ev }
            if let fr = self.panel.firstResponder, fr is NSTextView { return ev }
            switch ev.charactersIgnoringModifiers?.lowercased() {
            case " ": self.model.toggleMic(); return nil
            case "r": self.model.restartFromTop(); return nil
            case "e": self.model.editing = true; return nil
            default: break
            }
            switch ev.keyCode {
            case 123: self.model.nudge(-1); return nil  // ←
            case 124: self.model.nudge(1); return nil   // →
            case 126: self.model.nudge(-8); return nil  // ↑
            case 125: self.model.nudge(8); return nil   // ↓
            default: return ev
            }
        }
    }
}

// MARK: - main

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
