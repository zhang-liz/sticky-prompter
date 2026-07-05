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
struct Row: Identifiable { let id: Int; let range: Range<Int>; let newPara: Bool }

/// Does this raw word end a sentence? (ignoring trailing quotes/brackets)
func endsSentence(_ raw: String) -> Bool {
    var s = raw
    while let last = s.last, "\"')]”’".contains(last) { s.removeLast() }
    guard let last = s.last else { return false }
    return ".!?…:".contains(last)
}

final class PrompterModel: NSObject, ObservableObject {
    @Published var script: String
    @Published var scriptName: String
    @Published var savedNames: [String] = []
    @Published var pos = 0
    @Published var fontSize: Double
    @Published var bgOpacity: Double
    @Published var bgR: Double
    @Published var bgG: Double
    @Published var bgB: Double
    @Published var listening = false
    @Published var editing = false
    @Published var live = false
    @Published var status = ""
    @Published var clickThrough = false
    @Published var captureHidden = true
    @Published var libraryDir: URL = PrompterModel.defaultScriptsDir

    var tokens: [Token] = []
    var rows: [Row] = []
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
    private var persistSub: AnyCancellable?

    override init() {
        let d = UserDefaults.standard
        script = d.string(forKey: "script") ?? ""   // first launch: start blank
        scriptName = d.string(forKey: "scriptName") ?? ""
        fontSize = d.object(forKey: "fontSize") as? Double ?? 22
        bgOpacity = d.object(forKey: "bgOpacity") as? Double ?? 0.65
        if let r = d.object(forKey: "bgR") as? Double,
           let g = d.object(forKey: "bgG") as? Double,
           let b = d.object(forKey: "bgB") as? Double {
            bgR = r; bgG = g; bgB = b
        } else if d.string(forKey: "theme") == "yellow" {   // migrate old theme setting
            bgR = 1.0; bgG = 0.94; bgB = 0.55
        } else {
            bgR = 0.07; bgG = 0.07; bgB = 0.10
        }
        clickThrough = d.bool(forKey: "clickThrough")
        captureHidden = d.object(forKey: "captureHidden") as? Bool ?? true
        if let path = d.string(forKey: "libraryDir") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                libraryDir = URL(fileURLWithPath: path, isDirectory: true)
            }   // folder gone → stay on the default library
        }
        super.init()
        rebuild()
        refreshSavedNames()
        // don't lose direct edits on quit — persist shortly after typing stops
        persistSub = $script
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.persist() }
    }

    static let sample = """
    Hey everyone, welcome back to the channel!

    Today I want to show you something I have been really excited about. We are going to build a tiny app together, and by the end of this video you will be able to ship your own version in under an hour.

    Before we dive in, a quick note. Everything I show today is free and open source, and the link to the full code is in the description below.
    """

    var persistEnabled = true   // selftest must not clobber real settings

    func persist() {
        guard persistEnabled else { return }
        let d = UserDefaults.standard
        d.set(script, forKey: "script")
        d.set(scriptName, forKey: "scriptName")
        d.set(fontSize, forKey: "fontSize")
        d.set(bgOpacity, forKey: "bgOpacity")
        d.set(bgR, forKey: "bgR")
        d.set(bgG, forKey: "bgG")
        d.set(bgB, forKey: "bgB")
        d.set(clickThrough, forKey: "clickThrough")
        d.set(captureHidden, forKey: "captureHidden")
        d.set(libraryDir.path, forKey: "libraryDir")
    }

    // MARK: script library (plain .txt files, user-accessible)

    static let defaultScriptsDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sticky Prompter/Scripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    var usingDefaultLibrary: Bool { libraryDir == Self.defaultScriptsDir }

    private func scriptURL(_ name: String) -> URL {
        let safe = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return libraryDir.appendingPathComponent(safe + ".txt")
    }

    func refreshSavedNames() {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: libraryDir, includingPropertiesForKeys: nil)) ?? []
        savedNames = urls
            .filter { $0.pathExtension == "txt" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func setLibraryDir(_ url: URL) {
        libraryDir = url
        persist()
        refreshSavedNames()
    }

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = libraryDir
        panel.prompt = "Use Folder"
        panel.message = "Scripts are the .txt files in this folder; saves go here too."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            setLibraryDir(url)
        }
    }

    func saveScript(_ name: String, text: String) {
        try? FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        try? text.write(to: scriptURL(name), atomically: true, encoding: .utf8)
        refreshSavedNames()
    }

    /// One-click / ⌘S save of what's on the note. No name yet → the library
    /// sheet opens so the user can give it one.
    func saveCurrentScript() {
        let n = scriptName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { editing = true; return }
        saveScript(n, text: script)
        flash("Saved “\(n)”")
    }

    private var statusClear: Timer?
    func flash(_ msg: String) {
        status = msg
        statusClear?.invalidate()
        statusClear = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { [weak self] _ in
            if self?.status == msg { self?.status = "" }
        }
    }

    func loadScript(_ name: String) -> String? {
        try? String(contentsOf: scriptURL(name), encoding: .utf8)
    }

    func deleteScript(_ name: String) {
        // move to Trash rather than deleting outright
        try? FileManager.default.trashItem(at: scriptURL(name), resultingItemURL: nil)
        refreshSavedNames()
    }

    func rebuild(resetPos: Bool = true) {
        tokens = []
        rows = []
        var rid = 0
        for line in script.components(separatedBy: "\n") {
            let words = line.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            if words.isEmpty { continue }
            var start = tokens.count
            var newPara = rid > 0
            for w in words {
                let n = normWord(w)
                if n.isEmpty, tokens.count > start {
                    // punctuation-only fragment: glue to the previous word
                    let prev = tokens.removeLast()
                    tokens.append(Token(text: prev.text + " " + w, norm: prev.norm))
                } else {
                    tokens.append(Token(text: w, norm: n))
                }
                // close the row at sentence-final punctuation so scrolling can
                // pin the sentence being read to the top edge of the window
                if endsSentence(w), tokens.count > start {
                    rows.append(Row(id: rid, range: start..<tokens.count, newPara: newPara))
                    rid += 1
                    start = tokens.count
                    newPara = false
                }
            }
            if tokens.count > start {
                rows.append(Row(id: rid, range: start..<tokens.count, newPara: newPara))
                rid += 1
            }
        }
        // vocabulary biasing: prime the recognizer with the script's words,
        // longest (rarest) first — big accuracy win for names/jargon
        var seen = Set<String>()
        vocab = tokens.map { $0.norm }
            .filter { $0.count >= 3 && seen.insert($0).inserted }
            .sorted { $0.count > $1.count }
        if vocab.count > 100 { vocab = Array(vocab.prefix(100)) }
        pos = resetPos ? 0 : min(pos, tokens.count)
        anchor = pos
        pending = []
        persist()
    }

    // MARK: edit / live mode

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

    var currentRowID: Int {
        for r in rows where r.range.contains(min(pos, max(0, tokens.count - 1))) { return r.id }
        return rows.last?.id ?? 0
    }

    var progress: Double { tokens.isEmpty ? 0 : Double(pos) / Double(tokens.count) }

    // MARK: matching (same algorithm as the web version)
    // - one spoken word advances only if it matches the NEXT script word
    // - skipping ahead requires two consecutive spoken words matching two
    //   consecutive script words inside the lookahead window

    private func consume(_ raw: String) {
        let w = normWord(raw)
        if w.isEmpty { return }
        // hop over untracked tokens (punctuation-only, e.g. a lone "—")
        while pos < tokens.count, tokens[pos].norm.isEmpty { pos += 1 }
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

    // text/highlight colors adapt to the chosen background's brightness
    var luminance: Double { 0.299 * m.bgR + 0.587 * m.bgG + 0.114 * m.bgB }
    var isLightBG: Bool { luminance > 0.55 }
    var mainColor: Color { isLightBG ? Color(red: 0.15, green: 0.12, blue: 0.05) : Color(white: 0.96) }
    var bgColor: Color { Color(red: m.bgR, green: m.bgG, blue: m.bgB).opacity(m.bgOpacity) }
    var hiBG: Color { isLightBG ? Color(red: 1.0, green: 0.47, blue: 0.16) : Color(red: 0.97, green: 0.79, blue: 0.28) }
    var hiFG: Color { isLightBG ? .white : Color(red: 0.13, green: 0.10, blue: 0.0) }

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

    // live mode: the sentence being read sits at the very top,
    // as close to the camera as possible
    var scriptView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: m.fontSize * 0.3) {
                    ForEach(m.rows) { r in
                        Text(attributed(r))
                            .font(.system(size: m.fontSize, weight: .medium, design: .rounded))
                            .lineSpacing(m.fontSize * 0.35)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, r.newPara ? m.fontSize * 0.55 : 0)
                            .id(r.id)
                    }
                    Color.clear.frame(height: 340)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { m.enterEdit() }
            .onChange(of: m.pos) { _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(m.currentRowID, anchor: UnitPoint(x: 0, y: 0.02))
                }
            }
        }
    }

    // edit mode: type straight into the note
    var editor: some View {
        ZStack(alignment: .topLeading) {
            if m.script.isEmpty {
                Text("Type your script here, then Go Live.")
                    .font(.system(size: m.fontSize, weight: .medium, design: .rounded))
                    .foregroundColor(mainColor.opacity(0.35))
                    .padding(.horizontal, 17)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $m.script)
                .font(.system(size: m.fontSize, weight: .medium, design: .rounded))
                .foregroundColor(mainColor)
                .modifier(ClearTextEditor())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .onExitCommand { m.goLive() }   // Esc commits and goes live
        }
    }

    func attributed(_ r: Row) -> AttributedString {
        var out = AttributedString()
        for i in r.range {
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

    var bgBinding: Binding<Color> {
        Binding(
            get: { Color(red: m.bgR, green: m.bgG, blue: m.bgB) },
            set: { c in
                let ns = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0.07, green: 0.07, blue: 0.10, alpha: 1)
                m.bgR = Double(ns.redComponent)
                m.bgG = Double(ns.greenComponent)
                m.bgB = Double(ns.blueComponent)
                m.persist()
            })
    }

    var editBar: some View {
        HStack(spacing: 8) {
            Text(!m.status.isEmpty ? m.status
                 : m.scriptName.isEmpty ? "STICKY PROMPTER" : m.scriptName.uppercased())
                .font(.system(size: 10, weight: .bold))
                .kerning(1)
                .lineLimit(1)
                .foregroundColor(mainColor.opacity(0.5))
            Spacer()
            ctl("textformat.size.smaller", help: "Smaller text") { m.fontSize = max(13, m.fontSize - 2); m.persist() }
            ctl("textformat.size.larger", help: "Bigger text") { m.fontSize = min(48, m.fontSize + 2); m.persist() }
            ColorPicker("", selection: bgBinding)
                .labelsHidden()
                .frame(width: 26)
                .help("Background color")
            Slider(value: Binding(get: { m.bgOpacity }, set: { m.bgOpacity = $0; m.persist() }), in: 0.05...1)
                .frame(width: 64)
                .help("Background transparency")
            ctl("square.and.arrow.down", help: "Save script (⌘S)") { m.saveCurrentScript() }
            ctl("books.vertical", help: "Script library — save, load, delete") { m.editing = true }
            Button { m.goLive() } label: {
                Label("Go Live", systemImage: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(hiBG)
                    .foregroundColor(hiFG)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
            .help("Start prompting (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
            if m.status.isEmpty && !m.listening {
                Text("space = mic · double-click = edit")
                    .font(.system(size: 10))
                    .foregroundColor(mainColor.opacity(0.4))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            }
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

struct ClearTextEditor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 13.0, *) {
            content.scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}

struct EditorView: View {
    @ObservedObject var m: PrompterModel
    @State private var draft = ""
    @State private var name = ""
    @State private var snapshot = ""   // editor contents at last load/save

    var nameOK: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    /// True when it's fine to replace the editor contents (nothing typed,
    /// or the user confirms discarding what's there).
    func confirmDiscard() -> Bool {
        guard draft != snapshot,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        let a = NSAlert()
        a.messageText = "Discard unsaved changes?"
        a.informativeText = "The editor has changes that aren't saved to the library."
        a.addButton(withTitle: "Discard")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scripts").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                // saved-scripts library
                VStack(alignment: .leading, spacing: 6) {
                    Text("SAVED")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)
                    if m.savedNames.isEmpty {
                        Text("No scripts here yet.\nName your script and hit\n“Save to library”.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(m.savedNames, id: \.self) { n in
                                HStack(spacing: 4) {
                                    Button {
                                        guard confirmDiscard() else { return }
                                        if let t = m.loadScript(n) { draft = t; name = n; snapshot = t }
                                    } label: {
                                        HStack(spacing: 5) {
                                            Image(systemName: "doc.text")
                                            Text(n).lineLimit(1)
                                            Spacer(minLength: 0)
                                        }
                                        .padding(.vertical, 3)
                                        .padding(.horizontal, 6)
                                        .background(n == name ? Color.accentColor.opacity(0.18) : Color.clear)
                                        .cornerRadius(5)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Load “\(n)”")
                                    Button {
                                        m.deleteScript(n)
                                        if name == n { name = "" }
                                    } label: {
                                        Image(systemName: "trash").font(.system(size: 10))
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundColor(.secondary)
                                    .help("Move “\(n)” to Trash")
                                }
                            }
                        }
                    }
                    Spacer()
                    Divider()
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                        Text(m.usingDefaultLibrary ? "Default library" : m.libraryDir.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .help(m.libraryDir.path)
                    HStack(spacing: 6) {
                        Button("Choose folder…") { m.chooseLibraryFolder() }
                        if !m.usingDefaultLibrary {
                            Button("Default") { m.setLibraryDir(PrompterModel.defaultScriptsDir) }
                                .help("Back to the built-in library folder")
                        }
                    }
                    .controlSize(.small)
                }
                .frame(width: 175)

                Divider()

                // editor
                VStack(spacing: 8) {
                    TextField("Script name (used when saving)", text: $name)
                        .textFieldStyle(.roundedBorder)
                    TextEditor(text: $draft)
                        .font(.system(size: 14))
                        .frame(minWidth: 380, minHeight: 300)
                    HStack {
                        Button("New") {
                            if confirmDiscard() { draft = ""; name = ""; snapshot = "" }
                        }
                        .help("Start a blank script")
                        Button("Save to library") { m.saveScript(name, text: draft); snapshot = draft }
                            .disabled(!nameOK)
                        Spacer()
                        Button("Cancel") { m.editing = false }
                        Button("Use script") {
                            if nameOK { m.saveScript(name, text: draft) }
                            m.scriptName = nameOK ? name : ""
                            m.script = draft
                            m.rebuild()
                            m.editing = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 400)
        .onAppear { draft = m.script; name = m.scriptName; snapshot = m.script }
    }
}

// MARK: - App delegate / window

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = PrompterModel()
    var panel: NSPanel!
    var statusItem: NSStatusItem!
    var subs = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
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
        // invisible in screen recordings & screen shares (persisted preference)
        p.sharingType = model.captureHidden ? .none : .readOnly
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
        model.$live
            .receive(on: DispatchQueue.main)
            .sink { [weak self] live in self?.applyMode(live: live) }
            .store(in: &subs)
        applyMode(live: model.live)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    // NEVER true: AppKit's last-window check ignores NSPanels, so it would
    // terminate the app mid-use whenever a helper window (sheet, IME palette)
    // closes. Closing the note hides it; quit lives in the menu-bar icon.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        model.persist()
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Sticky Prompter")
        let menu = NSMenu()
        let mode = NSMenuItem(title: "Edit script", action: #selector(toggleMode), keyEquivalent: "e")
        mode.target = self
        mode.tag = 2
        menu.addItem(mode)
        let mic = NSMenuItem(title: "Voice tracking on/off", action: #selector(toggleMicFromMenu), keyEquivalent: " ")
        mic.target = self
        menu.addItem(mic)
        let restart = NSMenuItem(title: "Restart from top", action: #selector(restartFromMenu), keyEquivalent: "r")
        restart.target = self
        menu.addItem(restart)
        menu.addItem(.separator())
        let ct = NSMenuItem(title: "Click-through (ignore mouse)", action: #selector(toggleClickThrough), keyEquivalent: "t")
        ct.target = self
        ct.tag = 1
        ct.state = model.clickThrough ? .on : .off
        menu.addItem(ct)
        let hide = NSMenuItem(title: "Hide from screen sharing & recording", action: #selector(toggleCaptureHidden), keyEquivalent: "h")
        hide.target = self
        hide.state = model.captureHidden ? .on : .off
        menu.addItem(hide)
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
        model.persist()
    }

    @objc func toggleCaptureHidden(_ sender: NSMenuItem) {
        model.captureHidden.toggle()
        panel.sharingType = model.captureHidden ? .none : .readOnly
        sender.state = model.captureHidden ? .on : .off
        model.persist()
    }

    @objc func showNote() {
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        panel.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showNote() }
        return false
    }

    @objc func toggleMode() {
        if model.live { model.enterEdit() } else { model.goLive() }
        panel.makeKeyAndOrderFront(nil)
    }

    @objc func toggleMicFromMenu() {
        if !model.live { model.goLive() }   // tracking needs committed tokens
        model.toggleMic()
    }

    @objc func restartFromMenu() {
        model.restartFromTop()
    }

    /// Edit mode = normal window (traffic lights, minimizable, takes keyboard).
    /// Live mode = bare floating note.
    func applyMode(live: Bool) {
        guard let p = panel else { return }
        // NOTE: styleMask must never be mutated after init — runtime changes
        // destabilize the panel (sheet presentation then closes it and the
        // app quits via "last window closed"). Buttons are hidden/shown instead.
        if !live {
            NSApp.activate(ignoringOtherApps: true)
            // click-through would make editing impossible
            if model.clickThrough {
                model.clickThrough = false
                model.persist()
            }
            p.makeKeyAndOrderFront(nil)
        }
        p.ignoresMouseEvents = live && model.clickThrough
        p.becomesKeyOnlyIfNeeded = live
        for b: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            p.standardWindowButton(b)?.isHidden = live
        }
        statusItem?.menu?.item(withTag: 1)?.state = model.clickThrough ? .on : .off
        statusItem?.menu?.item(withTag: 2)?.title = live ? "Edit script" : "Go live"
    }

    func setupKeys() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] ev in
            guard let self = self, !self.model.editing else { return ev }
            // only shortcuts aimed at the note itself (not the color panel etc.)
            guard ev.window === self.panel else { return ev }
            // Esc in edit mode commits and goes live, even while typing
            if ev.keyCode == 53, !self.model.live {
                self.model.goLive()
                return nil
            }
            // ⌘S saves the current script, even while typing
            if ev.modifierFlags.contains(.command),
               ev.charactersIgnoringModifiers?.lowercased() == "s" {
                self.model.saveCurrentScript()
                return nil
            }
            if let fr = self.panel.firstResponder, fr is NSTextView { return ev }
            guard self.model.live else { return ev }
            switch ev.charactersIgnoringModifiers?.lowercased() {
            case " ": self.model.toggleMic(); return nil
            case "r": self.model.restartFromTop(); return nil
            case "e": self.model.enterEdit(); return nil
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

// MARK: - self test (headless matcher verification: run with --selftest)

func runSelfTest() {
    let m = PrompterModel()
    m.persistEnabled = false   // never touch the user's saved script/settings
    m.script = PrompterModel.sample
    m.rebuild()
    var fails = 0
    func expect(_ name: String, _ got: Int, _ want: Int) {
        let ok = got == want
        if !ok { fails += 1 }
        print("\(ok ? "PASS" : "FAIL") \(name): pos=\(got) want=\(want)")
    }
    // word-by-word
    m.handleTranscript(["hey"], isFinal: false)
    expect("one word", m.pos, 1)
    m.handleTranscript(["hey", "everyone", "welcome"], isFinal: false)
    expect("interim recompute", m.pos, 3)
    // stray common word must not jump ahead
    m.handleTranscript(["hey", "everyone", "welcome", "to"], isFinal: false)
    expect("no filler jump", m.pos, 3)
    m.handleTranscript(["hey", "everyone", "welcome", "back", "to", "the", "channel"], isFinal: true)
    expect("sentence 1", m.pos, 7)
    // ad-lib doesn't move it
    m.handleTranscript(["um", "you", "know", "like", "honestly"], isFinal: true)
    expect("ad-lib parked", m.pos, 7)
    // one garbled word resyncs on the next word ("today" garbled, "i" heard)
    m.handleTranscript(["toady", "i", "want"], isFinal: true)
    expect("garbled resync", m.pos, 10)
    // fuzzy match on longer words
    m.handleTranscript(["show", "you", "somthing"], isFinal: true)
    expect("fuzzy longer word", m.pos, 14)
    // deliberate skip via two consecutive words ("really excited" = 17,18)
    m.handleTranscript(["really", "excited", "about"], isFinal: true)
    expect("bigram skip", m.pos, 20)
    // jump resets cleanly
    m.jump(to: 30)
    m.handleTranscript(["end", "of", "this", "video"], isFinal: false)
    expect("resume after jump", m.pos, 36)
    // rebuild(resetPos: false) clamps instead of resetting
    m.jump(to: 30)
    m.script = "Hey everyone, welcome back."
    m.rebuild(resetPos: false)
    expect("edit clamps pos", m.pos, 4)
    m.script = PrompterModel.sample
    m.rebuild()
    expect("plain rebuild resets", m.pos, 0)
    // goLive commits + keeps clamped position; enterEdit stops listening
    m.scriptName = ""   // avoid writing a library file from the selftest
    m.jump(to: 5)
    m.goLive()
    expect("goLive keeps pos", m.pos, 5)
    func expectBool(_ name: String, _ got: Bool, _ want: Bool) {
        let ok = got == want
        if !ok { fails += 1 }
        print("\(ok ? "PASS" : "FAIL") \(name)")
    }
    expectBool("goLive sets live", m.live, true)
    m.enterEdit()
    expectBool("enterEdit clears live", m.live, false)
    // library round-trip in a user-chosen folder (persistEnabled=false keeps
    // the folder switch out of UserDefaults)
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("sticky-prompter-selftest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    m.setLibraryDir(tmp)
    expectBool("custom folder starts empty", m.savedNames.isEmpty, true)
    m.saveScript("Test Script", text: "hello world")
    expectBool("save lists script", m.savedNames == ["Test Script"], true)
    expectBool("load round-trips", m.loadScript("Test Script") == "hello world", true)
    // quick save (⌘S / toolbar button)
    m.script = "quick save body"
    m.scriptName = "Quick"
    m.saveCurrentScript()
    expectBool("quick save writes named script", m.loadScript("Quick") == "quick save body", true)
    m.editing = false
    m.scriptName = ""
    m.saveCurrentScript()
    expectBool("quick save without name opens library", m.editing, true)
    m.editing = false
    m.setLibraryDir(PrompterModel.defaultScriptsDir)
    try? FileManager.default.removeItem(at: tmp)
    print(fails == 0 ? "ALL PASS" : "\(fails) FAILURES")
    exit(fails == 0 ? 0 : 1)
}

// MARK: - main

if CommandLine.arguments.contains("--selftest") {
    runSelfTest()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
