import AppKit
import SwiftUI
import Speech
import AVFoundation
import Combine
import UniformTypeIdentifiers

// MARK: - Text utilities

func normWord(_ s: String) -> String {
    var out = ""
    for sc in s.lowercased().unicodeScalars {
        if sc == "\u{2019}" { out.unicodeScalars.append("'") }   // curly → straight apostrophe
        else if CharacterSet.alphanumerics.contains(sc) || sc == "'" { out.unicodeScalars.append(sc) }
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
struct Row: Identifiable {
    let id: Int; let range: Range<Int>; let newPara: Bool
    var heading = false   // markdown heading — rendered bigger and bold
}

/// Strip inline markdown so the syntax is neither shown nor expected
/// to be spoken: emphasis/code markers go, [label](url) keeps the label,
/// list dashes become bullets.
func stripInlineMarkdown(_ line: String) -> String {
    var t = line
    t = t.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
    for marker in ["**", "__", "*", "`"] { t = t.replacingOccurrences(of: marker, with: "") }
    if t.hasPrefix("- ") { t = "• " + t.dropFirst(2) }
    if t.hasPrefix("> ") { t = String(t.dropFirst(2)) }
    return t
}

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
    @Published var autoScroll = false      // steady pace instead of voice tracking
    @Published var autoPaused = false
    @Published var wpm: Double = 140       // auto-scroll speed, words per minute
    @Published var libraryDir: URL = PrompterModel.defaultScriptsDir
    @Published var sourceURL: URL?   // external file the script came from; saves write back to it
    @Published var panelIsKey = true // live-mode shortcuts only work while the note is key
    var sourceBaseline: String?      // file content at last load/save — detects external edits
    var libraryBaseline: String?     // library file content at last load/save — same check
    var alertsEnabled = true         // selftest runs headless; treat alerts as "cancel"

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
    private var consecutiveErrors = 0
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
        autoScroll = d.bool(forKey: "autoScroll")
        wpm = d.object(forKey: "wpm") as? Double ?? 140
        if let path = d.string(forKey: "libraryDir") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                libraryDir = URL(fileURLWithPath: path, isDirectory: true)
            }   // folder gone → stay on the default library
        }
        if let path = d.string(forKey: "sourceURL") {
            if FileManager.default.fileExists(atPath: path) {
                let url = URL(fileURLWithPath: path)
                sourceURL = url
                // (can't read self.script before super.init — re-read defaults)
                let r = Self.resolveRestoredScript(persisted: d.string(forKey: "script") ?? "",
                                                   baseline: d.string(forKey: "sourceBaseline"),
                                                   disk: Self.readScriptFile(url))
                script = r.script
                sourceBaseline = r.baseline
                if r.keptEdits {
                    status = "Note has edits not saved to “\(url.lastPathComponent)” — ⌘S to save"
                }
            } else {
                status = "⚠️ Original file moved or deleted — script kept, saves go to the library"
            }
        }
        super.init()
        refreshSavedNames()
        if sourceURL == nil, d.string(forKey: "sourceURL") == nil,
           !scriptName.trimmingCharacters(in: .whitespaces).isEmpty {
            // same relaunch policy as source files: a .txt edited while the
            // app was quit is adopted when the note is clean, and typed note
            // edits are kept (and flagged) so goLive/⌘S prompt instead of
            // clobbering — but only for notes that owned their library file
            // at last quit (RTF imports and orphaned source files carry a
            // name without a baseline; a colliding .txt is not ours to adopt)
            let r = Self.resolveRestoredLibraryScript(persisted: script,
                                                      hadBaseline: d.object(forKey: "libraryBaseline") != nil,
                                                      baseline: d.string(forKey: "libraryBaseline"),
                                                      disk: loadScript(scriptName))
            script = r.script
            libraryBaseline = r.baseline
            if r.warnDiffers {
                status = "Note differs from library script “\(scriptName)” — ⌘S to review"
            } else if r.keptEdits {
                status = "Note has edits not saved to “\(scriptName)” — ⌘S to save"
            }
        }
        rebuild()
        // don't lose direct edits on quit — persist shortly after typing stops
        persistSub = $script
            .debounce(for: .seconds(0.5), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.persist() }
    }

    /// Relaunch policy for a script opened from a file. The file is the
    /// source of truth only while note and file agree: a defaults copy
    /// staled behind the file adopts the disk version, but edits typed on
    /// the note (persisted != baseline) are never silently discarded.
    static func resolveRestoredScript(persisted: String, baseline: String?, disk: String?)
        -> (script: String, baseline: String?, keptEdits: Bool) {
        if let disk = disk, disk == persisted {
            return (disk, disk, false)   // note and file agree — no edits to warn about
        }
        if let base = baseline, persisted != base {
            return (persisted, base, true)   // note is ahead of the file
        }
        if let disk = disk { return (disk, disk, false) }
        return (persisted, baseline, false)
    }

    /// Relaunch policy for a library-named note. A persisted baseline means
    /// the note owned the file at last quit, so the source-file policy above
    /// applies. No baseline (RTF import, orphaned source file) means a
    /// same-named library file was never ours: keep the note untouched and
    /// just flag the mismatch so goLive/⌘S prompt instead of clobbering.
    static func resolveRestoredLibraryScript(persisted: String, hadBaseline: Bool,
                                             baseline: String?, disk: String?)
        -> (script: String, baseline: String?, warnDiffers: Bool, keptEdits: Bool) {
        guard hadBaseline else {
            return (persisted, nil, disk != nil && disk != persisted, false)
        }
        let r = resolveRestoredScript(persisted: persisted, baseline: baseline, disk: disk)
        return (r.script, r.baseline, false, r.keptEdits)
    }

    static let sample = """
    Hey everyone, welcome back to the channel!

    Today I want to show you something I have been really excited about. We are going to build a tiny app together, and by the end of this video you will be able to ship your own version in under an hour.

    Before we dive in, a quick note. Everything I show today is free and open source, and the link to the full code is in the description below.
    """

    // selftest must not clobber real settings — decided before init() runs,
    // so the rebuild()/persist() during init is already a no-op under --selftest
    var persistEnabled = !CommandLine.arguments.contains("--selftest")

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
        d.set(autoScroll, forKey: "autoScroll")
        d.set(wpm, forKey: "wpm")
        d.set(libraryDir.path, forKey: "libraryDir")
        if let u = sourceURL { d.set(u.path, forKey: "sourceURL") }
        else { d.removeObject(forKey: "sourceURL") }
        if let b = sourceBaseline { d.set(b, forKey: "sourceBaseline") }
        else { d.removeObject(forKey: "sourceBaseline") }
        if let b = libraryBaseline { d.set(b, forKey: "libraryBaseline") }
        else { d.removeObject(forKey: "libraryBaseline") }
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

    // display name → actual file URL, so names with sanitized characters
    // (":" or "/") still load and delete the right file
    private var savedURLs: [String: URL] = [:]

    /// The default filesystem is case-insensitive — "talk" and "Talk.txt" are
    /// the same file, so lookups must target the existing on-disk name.
    private func savedURL(_ name: String) -> URL? {
        savedURLs[name] ?? savedURLs.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func refreshSavedNames() {
        // .TXT counts too; folders named *.txt don't (a first-key collision on
        // a case-sensitive volume keeps one entry rather than crashing)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: libraryDir, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        savedURLs = Dictionary(urls
            .filter { $0.pathExtension.lowercased() == "txt"
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { ($0.deletingPathExtension().lastPathComponent, $0) },
            uniquingKeysWith: { a, _ in a })
        savedNames = savedURLs.keys
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

    @discardableResult
    func saveScript(_ name: String, text: String) -> Bool {
        try? FileManager.default.createDirectory(at: libraryDir, withIntermediateDirectories: true)
        let url = savedURL(name) ?? scriptURL(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            refreshSavedNames()
            return true
        } catch {
            refreshSavedNames()
            return false
        }
    }

    /// Pick a single text file anywhere on disk and use it as the script
    /// right away. Saves write back to that file until a library script
    /// takes over.
    /// True when what's on the note isn't safely stored anywhere.
    var noteHasUnsavedChanges: Bool {
        let text = script.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return false }
        if let base = sourceBaseline, sourceURL != nil { return script != base }
        let n = scriptName.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return true }
        return loadScript(n) != script
    }

    func openScriptFile() {
        // the current script would have no way back once replaced — ask
        if noteHasUnsavedChanges {
            let a = NSAlert()
            a.messageText = "Replace the current script?"
            a.informativeText = "The note has changes that aren't saved anywhere yet."
            a.addButton(withTitle: "Replace")
            a.addButton(withTitle: "Cancel")
            guard alertsEnabled, a.runModal() == .alertFirstButtonReturn else { return }
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = Self.openableTypes
        panel.message = "Choose a text, Markdown, RTF or Word file to use as your script."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let text = Self.readScriptFile(url) else {
            flash("⚠️ Couldn't read “\(url.lastPathComponent)”")
            return
        }
        script = text
        scriptName = url.deletingPathExtension().lastPathComponent
        // RTF/HTML are import-only (writing plain text back would corrupt them)
        let importOnly = Self.isRichTextFile(url)
        sourceURL = importOnly ? nil : url
        sourceBaseline = importOnly ? nil : text
        libraryBaseline = nil      // an existing library script of this name is not ours yet
        wordSaveApproved = false   // re-ask before overwriting a Word file
        rebuild()
        persist()
        editing = false
        enterEdit()    // land in the edit interface — stops the mic if we were live
        flash(importOnly ? "Opened “\(url.lastPathComponent)” — saves go to the library"
                         : "Opened “\(url.lastPathComponent)”")
    }

    /// Overwriting a Word file flattens its styling — ask once per opened doc.
    var wordSaveApproved = false

    static let wordTypes: [UTType] = [
        UTType("org.openxmlformats.wordprocessingml.document"),   // .docx
        UTType("com.microsoft.word.doc"),                         // legacy .doc
    ].compactMap { $0 }

    static let openableTypes: [UTType] =
        [.plainText, .rtf, UTType("net.daring-fireball.markdown")].compactMap { $0 } + wordTypes

    static func isWordFile(_ url: URL) -> Bool {
        ["docx", "doc"].contains(url.pathExtension.lowercased())
    }

    static func isRichTextFile(_ url: URL) -> Bool {
        ["rtf", "rtfd", "html", "htm"].contains(url.pathExtension.lowercased())
    }

    /// Read a script file: Word/RTF via AppKit's importer (so markup never
    /// lands on the note as raw text), text files with encoding detection;
    /// line endings normalized to \n.
    static func readScriptFile(_ url: URL) -> String? {
        var text: String?
        if isWordFile(url) || isRichTextFile(url) {
            text = ((try? NSAttributedString(
                url: url, options: [:], documentAttributes: nil))?.string)
                .map(sanitizeWordImport)
        } else {
            var enc = String.Encoding.utf8
            text = (try? String(contentsOf: url, usedEncoding: &enc))
                ?? (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        }
        return text?
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Word text arrives with artifacts that read as garbage on the note:
    /// list bullets as middle dots or symbol-font private-use glyphs,
    /// image placeholders, non-breaking spaces, vertical-tab line breaks.
    static func sanitizeWordImport(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for sc in s.unicodeScalars {
            switch sc.value {
            case 0xFFFC: continue                      // image/object placeholder
            case 0xE000...0xF8FF: out += "•"           // symbol-font bullets
            case 0x00A0: out += " "                    // non-breaking space
            case 0x000B, 0x2028, 0x2029: out += "\n"   // soft/para breaks
            case 0x0009: out += " "                    // list-indent tabs
            default: out.unicodeScalars.append(sc)
            }
        }
        // Word's plain middle-dot bullets → real bullets
        return out
            .components(separatedBy: "\n")
            .map { line -> String in
                let t = line.drop(while: { $0 == " " })
                return t.hasPrefix("· ") ? "• " + t.dropFirst(2)
                     : t == "·" ? "•" : line
            }
            .joined(separator: "\n")
    }

    /// The file changed on disk since we last read or wrote it.
    private func sourceChangedExternally(_ url: URL) -> Bool {
        guard let base = sourceBaseline,
              let disk = Self.readScriptFile(url) else { return false }
        return disk != base && disk != script
    }

    /// Write the script back to the file it was opened from.
    private func saveToSource(_ url: URL) {
        if sourceChangedExternally(url) {
            let a = NSAlert()
            a.messageText = "“\(url.lastPathComponent)” changed outside Sticky Prompter"
            a.informativeText = "Saving will overwrite those outside changes with the note's version."
            a.addButton(withTitle: "Overwrite")
            a.addButton(withTitle: "Cancel")
            guard alertsEnabled, a.runModal() == .alertFirstButtonReturn else {
                flash("⚠️ Not saved — “\(url.lastPathComponent)” changed on disk")
                return
            }
        }
        if Self.isWordFile(url) {
            if !wordSaveApproved {
                let a = NSAlert()
                a.messageText = "Save over the Word document?"
                a.informativeText = "Sticky Prompter writes plain text — the document's original fonts, images and layout won't be kept."
                a.addButton(withTitle: "Save")
                a.addButton(withTitle: "Cancel")
                guard alertsEnabled, a.runModal() == .alertFirstButtonReturn else { return }
                wordSaveApproved = true
            }
            // the Word exporter gains a trailing newline on read-back —
            // normalize the note first so note, baseline and disk agree
            if !script.hasSuffix("\n") { script += "\n" }
            if writeWordFile(url) {
                sourceBaseline = Self.readScriptFile(url) ?? script
                persist()   // keep the relaunch baseline in step with the file
                flash("Saved “\(url.lastPathComponent)”")
            } else {
                flash("⚠️ Couldn't save “\(url.lastPathComponent)”")
            }
            return
        }
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            sourceBaseline = script
            persist()   // keep the relaunch baseline in step with the file
            flash("Saved “\(url.lastPathComponent)”")
        } catch {
            flash("⚠️ Couldn't save “\(url.lastPathComponent)”")
        }
    }

    /// Modal "name your script" prompt. Nil when cancelled or left blank.
    private func promptScriptName() -> String? {
        guard alertsEnabled else { return nil }
        let a = NSAlert()
        a.messageText = "Name your script"
        a.informativeText = "It's saved in the library as a .txt file."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 230, height: 24))
        field.placeholderString = "Script name"
        a.accessoryView = field
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let n = field.stringValue.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? nil : n
    }

    private func confirmReplaceLibraryScript(_ n: String) -> Bool {
        let a = NSAlert()
        a.messageText = "Replace the script “\(n)”?"
        a.informativeText = "A script with this name is already in the library."
        a.addButton(withTitle: "Replace")
        a.addButton(withTitle: "Cancel")
        return alertsEnabled && a.runModal() == .alertFirstButtonReturn
    }

    /// One-click / ⌘S save of what's on the note. Scripts opened from a file
    /// save back to that file; otherwise the library. No name yet → ask for one.
    func saveCurrentScript() {
        if let u = sourceURL { saveToSource(u); return }
        let n = scriptName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else {
            guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                flash("Nothing to save yet")
                return
            }
            if live { enterEdit() }   // stop the mic before a modal prompt
            guard let newName = promptScriptName() else { return }
            if savedNames.contains(where: { $0.caseInsensitiveCompare(newName) == .orderedSame }),
               !confirmReplaceLibraryScript(newName) { return }
            if saveScript(newName, text: script) {
                scriptName = newName
                libraryBaseline = script
                persist()
                flash("Saved “\(newName)”")
            } else {
                flash("⚠️ Couldn't save “\(newName)” — check the library folder")
            }
            return
        }
        // same never-clobber rule as source files: a library .txt edited
        // outside the app isn't silently overwritten
        if let disk = loadScript(n), disk != script, disk != libraryBaseline {
            let a = NSAlert()
            a.messageText = "“\(n)” changed outside Sticky Prompter"
            a.informativeText = "Saving will overwrite those outside changes with the note's version."
            a.addButton(withTitle: "Overwrite")
            a.addButton(withTitle: "Cancel")
            guard alertsEnabled, a.runModal() == .alertFirstButtonReturn else {
                flash("⚠️ Not saved — “\(n)” changed on disk")
                return
            }
        }
        if saveScript(n, text: script) {
            libraryBaseline = script
            flash("Saved “\(n)”")
        } else {
            flash("⚠️ Couldn't save “\(n)” — check the library folder")
        }
    }

    /// The Scripts sheet's copy of the never-clobber rule: a library .txt
    /// edited outside the app since the draft was loaded isn't silently
    /// overwritten. `snapshot` covers a draft loaded from a library row;
    /// `libraryBaseline` covers a draft seeded from the owned note.
    func confirmSheetOverwrite(_ name: String, draft: String, snapshot: String) -> Bool {
        guard let disk = loadScript(name), disk != draft, disk != snapshot, disk != libraryBaseline
        else { return true }
        let a = NSAlert()
        a.messageText = "“\(name)” changed outside Sticky Prompter"
        a.informativeText = "Saving will overwrite those outside changes with the sheet's version."
        a.addButton(withTitle: "Overwrite")
        a.addButton(withTitle: "Cancel")
        return alertsEnabled && a.runModal() == .alertFirstButtonReturn
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
        try? String(contentsOf: savedURL(name) ?? scriptURL(name), encoding: .utf8)
    }

    @discardableResult
    func deleteScript(_ name: String) -> Bool {
        // move to Trash rather than deleting outright
        do {
            try FileManager.default.trashItem(at: savedURL(name) ?? scriptURL(name), resultingItemURL: nil)
            refreshSavedNames()
            return true
        } catch {
            refreshSavedNames()
            return false
        }
    }

    /// A trashed library file must also detach a note that owns it, or the
    /// next ⌘S/goLive quietly recreates the file. Names compare
    /// case-insensitively like every other library lookup — the save paths
    /// can leave scriptName in a different case than the on-disk name.
    /// Both sides trim too: scriptURL trims when writing, so a persisted
    /// scriptName with stray whitespace still names the same file.
    func detachIfOwnsScript(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let owned = scriptName.trimmingCharacters(in: .whitespaces)
        guard trimmed.caseInsensitiveCompare(owned) == .orderedSame else { return }
        scriptName = ""
        libraryBaseline = nil
        persist()
    }

    /// The Scripts sheet may skip the Replace prompt only for a draft the note
    /// owns in the library — not one merely named after an opened/imported file.
    var ownsLibraryScript: Bool { sourceURL == nil && libraryBaseline != nil }

    /// Markdown scripts get headings and syntax stripping in live mode
    var isMarkdown: Bool {
        ["md", "markdown"].contains(sourceURL?.pathExtension.lowercased() ?? "")
    }

    func rebuild(resetPos: Bool = true) {
        tokens = []
        rows = []
        var rid = 0
        let md = isMarkdown
        for rawLine in script.components(separatedBy: "\n") {
            var line = rawLine
            var heading = false
            if md {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") {
                    heading = true
                    line = String(trimmed.drop(while: { $0 == "#" }))
                }
                line = stripInlineMarkdown(line)
            }
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
                    rows.append(Row(id: rid, range: start..<tokens.count, newPara: newPara, heading: heading))
                    rid += 1
                    start = tokens.count
                    newPara = false
                }
            }
            if tokens.count > start {
                rows.append(Row(id: rid, range: start..<tokens.count, newPara: newPara, heading: heading))
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
        guard !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            flash("Type or open a script first")
            return
        }
        if let u = sourceURL {
            // silent background sync: never prompt mid-go-live, never write
            // over external edits, never flatten an unapproved Word doc
            if sourceChangedExternally(u) {
                flash("⚠️ “\(u.lastPathComponent)” changed on disk — ⌘S to review")
            } else if Self.isWordFile(u) {
                if wordSaveApproved, script != sourceBaseline {
                    // same trailing-newline normalization as saveToSource
                    if !script.hasSuffix("\n") { script += "\n" }
                    if writeWordFile(u) { sourceBaseline = Self.readScriptFile(u) ?? script }
                }
            } else if script != sourceBaseline {
                if (try? script.write(to: u, atomically: true, encoding: .utf8)) != nil {
                    sourceBaseline = script
                }
            }
        } else {
            let n = scriptName.trimmingCharacters(in: .whitespaces)
            if !n.isEmpty {
                // keep the library file in sync — but never over external edits
                if let disk = loadScript(n), disk != script, disk != libraryBaseline {
                    flash("⚠️ “\(n)” changed on disk — ⌘S to review")
                } else if saveScript(n, text: script) {
                    libraryBaseline = script
                }
            }
        }
        rebuild()   // reading starts from the first word; click a word to jump
        live = true
        // going live means "I'm about to read" — start following right away
        if autoScroll {
            startAutoScroll()
        } else if autoListen && !listening {
            startListening()
        }
    }

    var autoListen = true   // selftest runs headless: no real mic there

    // MARK: auto-scroll (steady pace instead of voice tracking)
    // Advances line by line: the whole current row is highlighted, and each
    // row gets time proportional to its word count so the pace stays at the
    // chosen words-per-minute.

    private var autoTimer: Timer?

    var currentAutoRow: Range<Int>? {
        rows.first(where: { $0.range.contains(pos) })?.range
    }

    /// One line hop. Separated from the timer so the selftest can drive it.
    func autoTick() {
        guard live, autoScroll, !autoPaused else { return }
        if let r = currentAutoRow, r.upperBound < tokens.count {
            pos = r.upperBound
            anchor = pos
            rescheduleAutoTimer()
        } else {
            pos = tokens.count
            anchor = pos
            autoTimer?.invalidate()
            autoPaused = true
            flash("🎉 End of script")
        }
    }

    /// Going live never starts the clock — the user sets the speed first
    /// and hits play.
    func startAutoScroll() {
        autoPaused = true
        autoTimer?.invalidate()
    }

    func toggleAutoPlay() {
        autoPaused.toggle()
        if !autoPaused && pos >= tokens.count { jump(to: 0) }   // replay from the top
        rescheduleAutoTimer()
    }

    func rescheduleAutoTimer() {
        autoTimer?.invalidate()
        guard live, autoScroll, !autoPaused else { return }
        let rowLen = max(1, currentAutoRow?.count ?? 1)
        autoTimer = Timer.scheduledTimer(withTimeInterval: Double(rowLen) * 60.0 / max(40, wpm),
                                         repeats: false) { [weak self] _ in
            self?.autoTick()
        }
    }

    func stopAutoScroll() {
        autoTimer?.invalidate()
        autoTimer = nil
        autoPaused = false
    }

    @discardableResult
    func writeWordFile(_ url: URL) -> Bool {
        let attr = NSAttributedString(string: script,
                                      attributes: [.font: NSFont.systemFont(ofSize: 12)])
        // match the extension: docx bytes in a .doc file read as corrupt elsewhere
        let type: NSAttributedString.DocumentType =
            url.pathExtension.lowercased() == "doc" ? .docFormat : .officeOpenXML
        guard let data = try? attr.data(
                from: NSRange(location: 0, length: attr.length),
                documentAttributes: [.documentType: type]),
              (try? data.write(to: url, options: .atomic)) != nil else { return false }
        return true
    }

    func enterEdit() {
        if listening { stopListening() }
        stopAutoScroll()
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
    private var announcedEnd = false

    func handleTranscript(_ words: [String], isFinal: Bool) {
        pos = anchor
        pending = []
        for w in words { consume(w) }
        if isFinal { anchor = pos }
        if pos >= tokens.count && !tokens.isEmpty {
            if !announcedEnd { announcedEnd = true; flash("🎉 End of script") }
        } else {
            announcedEnd = false
            if listening { status = "…" + words.suffix(6).joined(separator: " ") }
        }
    }

    func jump(to i: Int) {
        pos = max(0, min(i, tokens.count))
        anchor = pos
        pending = []
        if listening { restartRecognition() } // drop the in-flight utterance
        if autoScroll { rescheduleAutoTimer() } // new row, new line timing
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
        consecutiveErrors = 0
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
                    self.consecutiveErrors = 0
                    let words = r.bestTranscription.segments.map { $0.substring }
                    self.handleTranscript(words, isFinal: r.isFinal)
                    self.scheduleSilenceRollover()
                    if r.isFinal { self.restartRecognition() }
                } else if error != nil {
                    // an immediately-failing recognizer (offline, throttled)
                    // would otherwise spin in a restart loop
                    self.consecutiveErrors += 1
                    if self.consecutiveErrors >= 4 {
                        self.stopListening()
                        self.status = "⚠️ Speech recognition unavailable — try the mic again later"
                    } else {
                        self.restartRecognition()
                    }
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
    var scriptEmpty: Bool { m.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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
                        // auto-scroll highlights the whole current line and keeps
                        // past lines fully readable; voice mode tracks per word
                        let lineMode = m.autoScroll
                        let isCurrentLine = lineMode && r.range.contains(m.pos)
                        WrapWords(lineSpacing: m.fontSize * 0.35) {
                            ForEach(Array(r.range), id: \.self) { i in
                                Text(m.tokens[i].text + " ")
                                    .font(.system(size: r.heading ? m.fontSize * 1.2 : m.fontSize,
                                                  weight: r.heading ? .bold : .medium, design: .rounded))
                                    .foregroundColor(lineMode ? (isCurrentLine ? hiFG : mainColor)
                                                     : i < m.pos ? mainColor.opacity(0.32)
                                                     : i == m.pos ? hiFG : mainColor)
                                    .background((lineMode ? isCurrentLine : i == m.pos) ? hiBG : .clear)
                                    .onTapGesture(count: 2) { m.enterEdit() }
                                    .onTapGesture { m.jump(to: i) }   // click a word = read from here
                            }
                        }
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
        ZStack {
            if m.script.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 30, weight: .light))
                    Text("Type your script")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("or press ⌘O to open a file — then Go Live")
                        .font(.system(size: 12, design: .rounded))
                }
                .foregroundColor(mainColor.opacity(0.35))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        HStack(spacing: 7) {
            Text(!m.status.isEmpty ? m.status
                 : m.scriptName.isEmpty ? "STICKY PROMPTER" : m.scriptName.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(0.8)
                .lineLimit(1)
                .layoutPriority(1)   // don't let the controls squeeze the name to one letter
                .foregroundColor(mainColor.opacity(0.55))
            Spacer(minLength: 6)
            HStack(spacing: 1) {
                ctl("textformat.size.smaller", help: "Smaller text") { m.fontSize = max(13, m.fontSize - 2); m.persist() }
                ctl("textformat.size.larger", help: "Bigger text") { m.fontSize = min(48, m.fontSize + 2); m.persist() }
            }
            ColorPicker("", selection: bgBinding)
                .labelsHidden()
                .frame(width: 26)
                .help("Background color")
            Slider(value: Binding(get: { m.bgOpacity }, set: { m.bgOpacity = $0; m.persist() }), in: 0.05...1)
                .controlSize(.mini)
                .frame(width: 68)
                .help("Background transparency")
            Divider().frame(height: 14).opacity(0.4)
            ctl(m.autoScroll ? "timer" : "mic",
                help: m.autoScroll ? "Auto-scroll at a steady pace — click to switch to voice tracking"
                                   : "Voice tracking — click to switch to steady auto-scroll") {
                m.autoScroll.toggle()
                m.persist()
            }
            HStack(spacing: 1) {
                ctl("square.and.arrow.down", help: "Save script (⌘S)") { m.saveCurrentScript() }
                ctl("folder", help: "Open a file as the script (⌘O) — library lives in File ▸ Scripts (⌘L)") { m.openScriptFile() }
            }
            Button { m.goLive() } label: {
                Label("Go Live", systemImage: "play.fill")
                    .font(.system(size: 11.5, weight: .bold))
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(LinearGradient(colors: [hiBG, hiBG.opacity(0.8)],
                                                 startPoint: .top, endPoint: .bottom))
                    )
                    .foregroundColor(hiFG)
                    .shadow(color: hiBG.opacity(scriptEmpty ? 0 : 0.35), radius: 3, y: 1)
                    .opacity(scriptEmpty ? 0.45 : 1)
            }
            .buttonStyle(.plain)
            .disabled(scriptEmpty)
            .help(scriptEmpty ? "Type or open a script first" : "Start prompting (Esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(mainColor.opacity(0.08)).frame(height: 1)
        }
    }

    func ctl(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        CtlButton(symbol: symbol, help: help, color: mainColor, action: action)
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            if m.autoScroll {
                HStack(spacing: 8) {
                    CtlButton(symbol: m.autoPaused ? "play.fill" : "pause.fill",
                              help: m.autoPaused ? "Start scrolling" : "Pause",
                              color: mainColor) {
                        m.toggleAutoPlay()
                    }
                    Slider(value: Binding(get: { m.wpm },
                                          set: { m.wpm = $0; m.persist(); m.rescheduleAutoTimer() }),
                           in: 60...260)
                        .controlSize(.mini)
                        .frame(width: 110)
                        .help("Auto-scroll speed")
                    Text("\(Int(m.wpm)) wpm")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(mainColor.opacity(0.65))
                        .monospacedDigit()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule(style: .continuous).fill(.thinMaterial))
                .padding(.leading, 10)
            }
            let hint = !m.status.isEmpty ? m.status
                     : !m.listening && !m.autoScroll ? (m.panelIsKey ? "esc = edit"
                                     : m.clickThrough ? "click-through on — control via the menu bar note icon"
                                                      : "click the note, then esc = edit")
                     : ""
            if !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(mainColor.opacity(0.65))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule(style: .continuous).fill(.thinMaterial))
                    .padding(.leading, 10)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(mainColor.opacity(0.12))
                    Capsule().fill(hiBG)
                        .frame(width: max(4, g.size.width * m.progress))
                        .animation(.easeOut(duration: 0.25), value: m.progress)
                }
            }
            .frame(height: 4)
            .padding(.horizontal, 10)
        }
        .padding(.bottom, 8)
    }
}

/// Wrapping word layout: like flowing text, but every word is its own view
/// so a click can target it.
struct WrapWords: Layout {
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW { x = 0; y += lineH + lineSpacing; lineH = 0 }
            x += s.width
            lineH = max(lineH, s.height)
        }
        return CGSize(width: maxW.isFinite ? maxW : x, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > bounds.width { x = 0; y += lineH + lineSpacing; lineH = 0 }
            v.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                    anchor: .topLeading, proposal: .unspecified)
            x += s.width
            lineH = max(lineH, s.height)
        }
    }
}

/// Icon button with a hover highlight, sized for comfortable clicking.
struct CtlButton: View {
    let symbol: String
    let help: String
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(color.opacity(hovering ? 0.12 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundColor(color.opacity(hovering ? 0.95 : 0.7))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help)
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
    @State private var snapshot = ""     // editor contents at last load/save
    @State private var loadedName = ""   // library script the draft came from

    var nameOK: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Saving under a name the user didn't just load overwrites that script.
    /// Case-insensitive: on the default filesystem "talk" IS Talk.txt.
    func confirmOverwrite() -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard n.caseInsensitiveCompare(loadedName) != .orderedSame,
              let existing = m.savedNames.first(where: { $0.caseInsensitiveCompare(n) == .orderedSame })
        else { return true }
        let a = NSAlert()
        a.messageText = "Replace the script “\(existing)”?"
        a.informativeText = "A script with this name is already in the library."
        a.addButton(withTitle: "Replace")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    /// Using a library script stops saves from going to an opened file.
    func confirmDetachSource() -> Bool {
        guard let u = m.sourceURL else { return true }
        let a = NSAlert()
        a.messageText = "Stop saving to “\(u.lastPathComponent)”?"
        a.informativeText = "The note will switch to this library script; the file keeps its current contents."
        a.addButton(withTitle: "Switch")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

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
        VStack(alignment: .leading, spacing: 14) {
            Text("Scripts").font(.title3.weight(.semibold))
            HStack(alignment: .top, spacing: 14) {
                // saved-scripts library
                VStack(alignment: .leading, spacing: 8) {
                    Text("Library")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    if m.savedNames.isEmpty {
                        Text("No scripts here yet.\nName your script and hit\n“Save to Library”.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.top, 2)
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(m.savedNames, id: \.self) { n in
                                ScriptRow(name: n, selected: n.caseInsensitiveCompare(name) == .orderedSame) {
                                    guard confirmDiscard() else { return }
                                    guard let t = m.loadScript(n) else {
                                        // file gone or unreadable since the list was built
                                        m.refreshSavedNames()
                                        let a = NSAlert()
                                        a.messageText = "Couldn't read “\(n)”"
                                        a.informativeText = "The file may have been moved or deleted — the list has been refreshed."
                                        a.runModal()
                                        return
                                    }
                                    draft = t; name = n; snapshot = t; loadedName = n
                                } onDelete: {
                                    guard m.deleteScript(n) else {
                                        // the sheet covers the edit-bar status line, so
                                        // a flash would be invisible — alert instead
                                        let a = NSAlert()
                                        a.messageText = "Couldn't move “\(n)” to Trash"
                                        a.informativeText = "Check the library folder's permissions — some volumes don't support the Trash."
                                        a.runModal()
                                        return
                                    }
                                    if name.caseInsensitiveCompare(n) == .orderedSame { name = "" }
                                    // note's own file just got trashed — detach it
                                    // so goLive/⌘S don't quietly recreate the file
                                    m.detachIfOwnsScript(named: n)
                                }
                            }
                        }
                    }
                    Spacer()
                    Divider()
                    // one folder control: the label is the menu
                    Menu {
                        Button("Change Library Folder…") { m.chooseLibraryFolder() }
                        if !m.usingDefaultLibrary {
                            Button("Use Default Folder") { m.setLibraryDir(PrompterModel.defaultScriptsDir) }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "folder")
                            Text(m.usingDefaultLibrary ? "Default library" : m.libraryDir.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.system(size: 10.5))
                    }
                    .menuStyle(.borderlessButton)
                    .foregroundColor(.secondary)
                    .fixedSize()
                    .help("This folder's .txt files are the library — click to change it\n\(m.libraryDir.path)")
                }
                .frame(width: 185)

                Divider()

                // editor
                VStack(spacing: 10) {
                    TextField("Script name (used when saving)", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                    TextEditor(text: $draft)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.separator, lineWidth: 1)
                        )
                        .frame(minWidth: 400, minHeight: 320)
                    HStack(spacing: 8) {
                        Button {
                            if confirmDiscard() { draft = ""; name = ""; snapshot = ""; loadedName = "" }
                        } label: {
                            Label("New", systemImage: "plus")
                        }
                        .help("Start a blank script")
                        Button {
                            guard confirmDiscard() else { return }
                            // close the sheet before running the open panel —
                            // state set while both modals unwind gets dropped
                            m.editing = false
                            DispatchQueue.main.async { m.openScriptFile() }
                        } label: {
                            Label("Open File…", systemImage: "folder").fixedSize()
                        }
                        .help("Use a text, Markdown or Word file from anywhere as the script")
                        Button {
                            // confirmOverwrite skips the prompt for the loaded name, so
                            // the disk-vs-baseline check must still run — same never-clobber
                            // rule as ⌘S on the note. Trim once and use the trimmed name
                            // everywhere: scriptURL trims when writing, so an untrimmed
                            // name here would drift from the on-disk name
                            let n = name.trimmingCharacters(in: .whitespaces)
                            guard confirmOverwrite(),
                                  m.confirmSheetOverwrite(n, draft: draft, snapshot: snapshot) else { return }
                            if m.saveScript(n, text: draft) {
                                snapshot = draft
                                loadedName = n
                                // saved over the note's own script — keep the note
                                // and its baseline in step, or the next ⌘S/goLive
                                // claims the change came from outside the app
                                if m.ownsLibraryScript,
                                   m.scriptName.caseInsensitiveCompare(loadedName) == .orderedSame {
                                    m.script = draft
                                    m.libraryBaseline = draft
                                    m.rebuild()
                                    m.persist()
                                }
                            } else {
                                let a = NSAlert()
                                a.messageText = "Couldn't save “\(n)”"
                                a.informativeText = "Check that the library folder still exists and is writable."
                                a.runModal()
                            }
                        } label: {
                            Label("Save to Library", systemImage: "square.and.arrow.down").fixedSize()
                        }
                        .keyboardShortcut("s", modifiers: .command)   // ⌘S saves here too
                        .disabled(!nameOK)
                        Spacer()
                        Button("Cancel") {
                            guard confirmDiscard() else { return }
                            m.editing = false
                        }
                        .keyboardShortcut(.cancelAction)   // Esc dismisses the sheet
                        Button("Use Script") {
                            // trimmed name throughout — scriptName must match the
                            // on-disk name (scriptURL trims) or a later trash of
                            // that row won't detach the note
                            let n = name.trimmingCharacters(in: .whitespaces)
                            guard confirmDetachSource(),
                                  nameOK ? confirmOverwrite() : true,
                                  nameOK ? m.confirmSheetOverwrite(n, draft: draft, snapshot: snapshot) : true
                            else { return }
                            if nameOK, !m.saveScript(n, text: draft) {
                                // same failure surface as Save to Library — don't
                                // close the sheet or claim ownership of a library
                                // file that was never written
                                let a = NSAlert()
                                a.messageText = "Couldn't save “\(n)”"
                                a.informativeText = "Check that the library folder still exists and is writable."
                                a.runModal()
                                return
                            }
                            m.scriptName = nameOK ? n : ""
                            m.script = draft
                            m.sourceURL = nil   // library owns the script again
                            m.sourceBaseline = nil
                            m.libraryBaseline = nameOK ? draft : nil
                            m.rebuild()
                            m.persist()
                            m.editing = false
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 700, minHeight: 440)
        .onAppear {
            m.refreshSavedNames()   // pick up files added/removed in Finder
            draft = m.script; name = m.scriptName; snapshot = m.script
            // only a library-owned draft may skip the overwrite prompt —
            // file opens/imports set scriptName without owning that library entry
            loadedName = m.ownsLibraryScript ? m.scriptName : ""
        }
    }
}

/// Library row: full-row hover highlight, trash appears on hover.
struct ScriptRow: View {
    let name: String
    let selected: Bool
    let onLoad: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    init(name: String, selected: Bool, onLoad: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.name = name
        self.selected = selected
        self.onLoad = onLoad
        self.onDelete = onDelete
    }

    var body: some View {
        HStack(spacing: 5) {
            Button(action: onLoad) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .foregroundColor(selected ? .accentColor : .secondary)
                    Text(name).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Load “\(name)”")
            if hovering {
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Move “\(name)” to Trash")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 7)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.16)
                     : hovering ? Color.primary.opacity(0.06) : .clear)
        )
        .onHover { hovering = $0 }
    }
}

// MARK: - App delegate / window

/// NSPanel closes itself on Escape by default (cancelOperation) — which
/// reads as the app quitting. Esc must always mean "toggle edit/live".
final class PrompterPanel: NSPanel {
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        super.keyDown(with: event)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let model = PrompterModel()
    var panel: NSPanel!
    var statusItem: NSStatusItem!
    var subs = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let p = PrompterPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 460),   // ≥ contentMinSize width
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.onEscape = { [weak self] in
            guard let self = self, !self.model.editing else { return }
            if self.model.live { self.model.enterEdit() } else { self.model.goLive() }
        }
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false   // clicking the note must grab keyboard focus (Esc)
        p.isReleasedWhenClosed = false   // we keep a strong ref; closing only hides
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // invisible in screen recordings & screen shares (persisted preference)
        p.sharingType = model.captureHidden ? .none : .readOnly
        p.contentView = NSHostingView(rootView: ContentView(m: model))
        p.contentMinSize = NSSize(width: 420, height: 220)   // keep the edit bar readable
        p.setFrameAutosaveName("StickyPrompterWindow")
        if p.frame.origin == .zero {
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                p.setFrameOrigin(NSPoint(x: f.maxX - 440, y: f.maxY - 500))
            }
        }
        p.makeKeyAndOrderFront(nil)
        panel = p

        setupMainMenu()
        setupStatusItem()
        setupKeys()
        model.$live
            .receive(on: DispatchQueue.main)
            .sink { [weak self] live in self?.applyMode(live: live) }
            .store(in: &subs)
        // the status menu is the only control surface with click-through on —
        // its mic item must show whether the mic is actually listening
        model.$listening
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in
                self?.statusItem?.menu?.item(withTag: 3)?.state = on ? .on : .off
            }
            .store(in: &subs)
        applyMode(live: model.live)
        // live-mode shortcuts only reach us while the note is the key window —
        // let the UI say so instead of silently typing spaces into Zoom
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: p, queue: .main) { [weak self] _ in
            self?.model.panelIsKey = true
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: p, queue: .main) { [weak self] _ in
            self?.model.panelIsKey = false
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Without a main menu, none of the standard edit shortcuts reach the
    /// text editor — a first-time user can't even paste their script in.
    func setupMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About Sticky Prompter",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Sticky Prompter", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Sticky Prompter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "File")
        let openItem = NSMenuItem(title: "Open Script File…", action: #selector(openFromMenu), keyEquivalent: "o")
        openItem.target = self
        file.addItem(openItem)
        let saveItem = NSMenuItem(title: "Save Script", action: #selector(saveFromMenu), keyEquivalent: "s")
        saveItem.target = self
        file.addItem(saveItem)
        file.addItem(.separator())
        let libItem = NSMenuItem(title: "Scripts Library…", action: #selector(libraryFromMenu), keyEquivalent: "l")
        libItem.target = self
        file.addItem(libItem)
        fileItem.submenu = file

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

    // the Scripts sheet owns open/save while it's up — ⌘O/⌘S from the main
    // menu would bypass its draft and its discard confirmations
    @objc func openFromMenu() {
        guard !model.editing else { return }
        model.openScriptFile()
    }
    @objc func saveFromMenu() {
        guard !model.editing else { return }
        model.saveCurrentScript()
    }
    @objc func libraryFromMenu() {
        guard !model.editing else { return }
        if model.live { model.enterEdit() }
        model.editing = true
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(openFromMenu) || menuItem.action == #selector(saveFromMenu)
            || menuItem.action == #selector(toggleMode) || menuItem.action == #selector(toggleMicFromMenu)
            || menuItem.action == #selector(restartFromMenu) || menuItem.action == #selector(libraryFromMenu) {
            return !model.editing
        }
        return true
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
        // no keyEquivalents here: a closed status menu never dispatches them,
        // so the hints would advertise shortcuts that don't work (or collide
        // with real ones — the live-mode keys are unmodified space/r/e)
        let mode = NSMenuItem(title: "Edit script", action: #selector(toggleMode), keyEquivalent: "")
        mode.target = self
        mode.tag = 2
        menu.addItem(mode)
        let mic = NSMenuItem(title: "Voice tracking", action: #selector(toggleMicFromMenu), keyEquivalent: "")
        mic.target = self
        mic.tag = 3
        mic.state = model.listening ? .on : .off
        menu.addItem(mic)
        let restart = NSMenuItem(title: "Restart from top", action: #selector(restartFromMenu), keyEquivalent: "")
        restart.target = self
        menu.addItem(restart)
        menu.addItem(.separator())
        let ct = NSMenuItem(title: "Click-through (ignore mouse)", action: #selector(toggleClickThrough), keyEquivalent: "")
        ct.target = self
        ct.tag = 1
        ct.state = model.clickThrough ? .on : .off
        menu.addItem(ct)
        let hide = NSMenuItem(title: "Hide from screen sharing & recording", action: #selector(toggleCaptureHidden), keyEquivalent: "")
        hide.target = self
        hide.state = model.captureHidden ? .on : .off
        menu.addItem(hide)
        let show = NSMenuItem(title: "Show note", action: #selector(showNote), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Sticky Prompter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @objc func toggleClickThrough(_ sender: NSMenuItem) {
        model.clickThrough.toggle()
        // only live mode ignores the mouse — edit mode must stay clickable
        panel.ignoresMouseEvents = model.clickThrough && model.live
        sender.state = model.clickThrough ? .on : .off
        if model.clickThrough {
            model.flash(model.live ? "Click-through on — control me from the menu bar note icon"
                                   : "Click-through on — takes effect in live mode")
        }
        model.persist()
    }

    @objc func toggleCaptureHidden(_ sender: NSMenuItem) {
        model.captureHidden.toggle()
        panel.sharingType = model.captureHidden ? .none : .readOnly
        sender.state = model.captureHidden ? .on : .off
        model.persist()
    }

    @objc func showNote() {
        NSApp.unhide(nil)   // after ⌘H, orderFront alone leaves the window hidden
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        panel.makeKeyAndOrderFront(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showNote() }
        return false
    }

    // same rule as open/save: while the Scripts sheet is up it owns the note —
    // goLive here would commit the note's stale text behind the sheet's draft
    @objc func toggleMode() {
        guard !model.editing else { return }
        if model.live { model.enterEdit() } else { model.goLive() }
        showNote()   // deminiaturize too — live mode in the Dock is useless
    }

    @objc func toggleMicFromMenu() {
        guard !model.editing else { return }
        guard !model.autoScroll else {
            model.flash("Auto-scroll mode — switch to voice tracking on the note")
            return
        }
        showNote()   // a hot mic with the note hidden is a dead end
        if !model.live {
            model.goLive()   // tracking needs committed tokens; goLive auto-starts the mic
            return           // (empty script: goLive already said why it refused)
        }
        model.toggleMic()
    }

    @objc func restartFromMenu() {
        guard !model.editing else { return }
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
        }
        p.makeKeyAndOrderFront(nil)
        // click-through only ever applies in live mode; the setting itself
        // survives mode switches and relaunches
        p.ignoresMouseEvents = live && model.clickThrough
        // the note must be able to take keyboard focus on click in BOTH modes,
        // otherwise Esc/arrow keys silently stop working the moment another
        // window becomes key ("Esc sometimes doesn't exit live mode")
        p.becomesKeyOnlyIfNeeded = false
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
            // Esc toggles the mode: edit commits and goes live (even while
            // typing), live drops back to edit
            if ev.keyCode == 53 {
                self.model.live ? self.model.enterEdit() : self.model.goLive()
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
    m.persistEnabled = false    // never touch the user's saved script/settings
    m.sourceURL = nil           // ignore any source file restored from defaults
    m.sourceBaseline = nil
    m.libraryBaseline = nil
    m.alertsEnabled = false     // headless: every confirmation counts as Cancel
    m.autoListen = false        // headless: goLive must not touch the mic
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
    // goLive commits and always starts from the first word
    m.scriptName = ""   // avoid writing a library file from the selftest
    m.jump(to: 5)
    m.goLive()
    expect("goLive starts from the top", m.pos, 0)
    func expectBool(_ name: String, _ got: Bool, _ want: Bool) {
        let ok = got == want
        if !ok { fails += 1 }
        print("\(ok ? "PASS" : "FAIL") \(name)")
    }
    expectBool("goLive sets live", m.live, true)
    m.enterEdit()
    expectBool("enterEdit clears live", m.live, false)
    // the mic belongs to live mode only — every exit must shut it off
    m.goLive()
    m.listening = true   // simulate a hot mic (no real recognizer headless)
    m.enterEdit()
    expectBool("enterEdit stops the mic", m.listening, false)
    // auto-scroll mode: starts paused, line hops, mic never starts
    m.autoScroll = true
    m.goLive()
    expectBool("auto goLive never touches the mic", m.listening, false)
    expectBool("auto goLive starts paused", m.autoPaused, true)
    m.autoTick()
    expect("paused tick holds", m.pos, 0)
    m.toggleAutoPlay()
    expectBool("play starts scrolling", m.autoPaused, false)
    m.autoTick()
    expect("tick hops a full line", m.pos, 7)   // sample row 0 = 7 words
    m.autoTick()
    expectBool("second hop lands on a row start", m.currentAutoRow?.lowerBound == m.pos, true)
    m.enterEdit()
    m.autoScroll = false
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
    // unnamed save asks for a name (headless: prompt counts as Cancel — no write, no sheet)
    let namesBefore = m.savedNames
    m.saveCurrentScript()
    expectBool("unnamed save prompts, cancel writes nothing", m.savedNames == namesBefore && m.editing == false, true)
    // an empty unnamed note has nothing to name
    let body = m.script
    m.script = "   "
    m.saveCurrentScript()
    expectBool("empty unnamed save does nothing", m.editing == false && m.savedNames == namesBefore, true)
    // unnamed save while live drops back to edit before the name prompt
    m.script = body
    m.goLive()
    m.saveCurrentScript()
    expectBool("unnamed live save leaves live mode", m.live, false)
    // script opened from an external file saves back in place
    let ext = tmp.appendingPathComponent("external.txt")
    try? "original".write(to: ext, atomically: true, encoding: .utf8)
    m.sourceURL = ext
    m.script = "edited body"
    m.saveCurrentScript()
    expectBool("source file save-back", (try? String(contentsOf: ext, encoding: .utf8)) == "edited body", true)
    m.script = "live body"
    m.goLive()
    expectBool("goLive syncs source file", (try? String(contentsOf: ext, encoding: .utf8)) == "live body", true)
    m.enterEdit()
    m.sourceURL = nil
    // file reading: legacy encoding + CR line endings normalize to \n
    let legacy = tmp.appendingPathComponent("legacy.txt")
    try? Data([0x63, 0x61, 0x66, 0xE9, 0x0D, 0x68, 0x69]).write(to: legacy)   // "café\rhi" in latin-1
    expectBool("legacy txt read", PrompterModel.readScriptFile(legacy) == "café\nhi", true)
    // Word import (docx generated with textutil)
    let txtSrc = tmp.appendingPathComponent("w.txt")
    let docx = tmp.appendingPathComponent("w.docx")
    try? "word doc body".write(to: txtSrc, atomically: true, encoding: .utf8)
    let conv = Process()
    conv.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
    conv.arguments = ["-convert", "docx", txtSrc.path, "-output", docx.path]
    try? conv.run(); conv.waitUntilExit()
    expectBool("docx import", PrompterModel.readScriptFile(docx)?.contains("word doc body") == true, true)
    // Word artifacts cleaned up on import
    expectBool("word import sanitized",
               PrompterModel.sanitizeWordImport("·\tItem\u{00A0}one\u{000B}\u{E000} two\u{FFFC}") == "• Item one\n• two", true)
    expectBool("curly apostrophe normalized", normWord("don’t") == "don't", true)
    // Word write-back round-trips through the docx exporter
    m.sourceURL = docx
    m.sourceBaseline = PrompterModel.readScriptFile(docx)   // as openScriptFile would
    m.wordSaveApproved = true
    m.script = "rewritten body"
    m.saveCurrentScript()
    expectBool("docx write-back", PrompterModel.readScriptFile(docx)?.contains("rewritten body") == true, true)
    // goLive doesn't rewrite an approved Word doc when nothing changed (mtime churn)
    m.script = PrompterModel.readScriptFile(docx) ?? "rewritten body"
    m.sourceBaseline = m.script
    let mtBefore = (try? FileManager.default.attributesOfItem(atPath: docx.path)[.modificationDate]) as? Date
    m.goLive()
    let mtAfter = (try? FileManager.default.attributesOfItem(atPath: docx.path)[.modificationDate]) as? Date
    expectBool("goLive skips unchanged Word doc", mtBefore != nil && mtBefore == mtAfter, true)
    // Word save must not poison its own baseline: a note without a trailing
    // newline reads back from the exporter with one — after ⌘S note, baseline
    // and disk agree, so a second ⌘S takes the quiet no-alert path
    m.script = "no trailing newline"
    m.saveCurrentScript()
    expectBool("docx save aligns note, baseline and disk",
               PrompterModel.readScriptFile(docx) == m.script && m.script == m.sourceBaseline, true)
    m.saveCurrentScript()   // a poisoned baseline would alert (headless = cancel) and skip the write
    expectBool("second docx save stays clean",
               PrompterModel.readScriptFile(docx) == m.script && m.script == m.sourceBaseline, true)
    m.enterEdit()
    m.sourceURL = nil
    // legacy .doc write-back stays real .doc bytes (not mislabeled docx)
    let doc = tmp.appendingPathComponent("w.doc")
    let conv2 = Process()
    conv2.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
    conv2.arguments = ["-convert", "doc", txtSrc.path, "-output", doc.path]
    try? conv2.run(); conv2.waitUntilExit()
    m.sourceURL = doc
    m.sourceBaseline = PrompterModel.readScriptFile(doc)
    m.script = "doc rewritten body"
    m.saveCurrentScript()
    expectBool("doc write-back", PrompterModel.readScriptFile(doc)?.contains("doc rewritten body") == true, true)
    let docBytes = (try? Data(contentsOf: doc)) ?? Data()
    expectBool("doc write-back is Word 97 format", docBytes.starts(with: [0xD0, 0xCF, 0x11, 0xE0]), true)
    m.sourceURL = nil
    m.sourceBaseline = nil
    // markdown: headings styled, syntax stripped, speech still matches
    let mdFile = tmp.appendingPathComponent("t.md")
    try? "x".write(to: mdFile, atomically: true, encoding: .utf8)
    m.sourceURL = mdFile
    m.script = "# Big Title\nSay **hello** to [world](http://x)."
    m.rebuild()
    expectBool("md heading flagged", m.rows.first?.heading == true, true)
    expectBool("md syntax stripped",
               !m.tokens.contains { $0.text.contains("**") || $0.text.contains("#") || $0.text.contains("](") }, true)
    m.handleTranscript(["big", "title", "say", "hello", "to", "world"], isFinal: true)
    expectBool("md speech matches", m.pos == m.tokens.count, true)
    m.sourceURL = nil
    // goLive refuses an empty script
    m.script = "   "
    m.goLive()
    expectBool("goLive blocks empty script", m.live, false)
    // external edits are never clobbered
    let shared = tmp.appendingPathComponent("shared.txt")
    try? "mine".write(to: shared, atomically: true, encoding: .utf8)
    m.sourceURL = shared
    m.sourceBaseline = "mine"
    m.script = "my edits"
    try? "theirs".write(to: shared, atomically: true, encoding: .utf8)   // change behind the app's back
    m.goLive()
    expectBool("goLive keeps external edits", (try? String(contentsOf: shared, encoding: .utf8)) == "theirs", true)
    m.enterEdit()
    m.saveCurrentScript()   // alert suppressed → cancel
    expectBool("save keeps external edits without consent", (try? String(contentsOf: shared, encoding: .utf8)) == "theirs", true)
    m.sourceURL = nil
    m.sourceBaseline = nil
    // library scripts get the same never-clobber rule
    m.scriptName = "Lib"
    m.script = "lib v1"
    m.saveCurrentScript()
    expectBool("library save sets baseline", m.loadScript("Lib") == "lib v1", true)
    try? "lib theirs".write(to: tmp.appendingPathComponent("Lib.txt"), atomically: true, encoding: .utf8)
    m.script = "lib mine"
    m.goLive()
    expectBool("goLive keeps external library edits", m.loadScript("Lib") == "lib theirs", true)
    m.enterEdit()
    m.saveCurrentScript()   // alert suppressed → cancel
    expectBool("library save keeps external edits without consent", m.loadScript("Lib") == "lib theirs", true)
    m.scriptName = ""
    m.libraryBaseline = nil
    // relaunch policy: typed note edits survive; disk still wins when in sync
    let rKeep = PrompterModel.resolveRestoredScript(persisted: "typed edits", baseline: "old", disk: "old")
    expectBool("relaunch keeps unsaved note edits", rKeep.script == "typed edits" && rKeep.keptEdits, true)
    let rDisk = PrompterModel.resolveRestoredScript(persisted: "same", baseline: "same", disk: "newer on disk")
    expectBool("relaunch adopts file changed on disk", rDisk.script == "newer on disk" && !rDisk.keptEdits, true)
    expectBool("relaunch without baseline adopts disk",
               PrompterModel.resolveRestoredScript(persisted: "stale", baseline: nil, disk: "disk").script == "disk", true)
    // note and file already agree → no false "unsaved edits" warning
    let rSame = PrompterModel.resolveRestoredScript(persisted: "same", baseline: "old", disk: "same")
    expectBool("relaunch matching disk clears stale baseline",
               rSame.baseline == "same" && !rSame.keptEdits, true)
    // library scripts use the same policy: a clean note adopts a .txt
    // edited in another app while Sticky Prompter was quit
    let rLib = PrompterModel.resolveRestoredScript(persisted: "old", baseline: "old", disk: "external v2")
    expectBool("library relaunch adopts external edits",
               rLib.script == "external v2" && rLib.baseline == "external v2" && !rLib.keptEdits, true)
    // a note that never owned a library file (RTF import / orphaned source)
    // must not adopt a colliding library .txt at relaunch — flag, don't clobber
    let rImport = PrompterModel.resolveRestoredLibraryScript(
        persisted: "rtf import edits", hadBaseline: false, baseline: nil, disk: "old lib")
    expectBool("relaunch keeps import over colliding library file",
               rImport.script == "rtf import edits" && rImport.baseline == nil && rImport.warnDiffers, true)
    let rOwned = PrompterModel.resolveRestoredLibraryScript(
        persisted: "old", hadBaseline: true, baseline: "old", disk: "external v2")
    expectBool("owned library relaunch still adopts external edits",
               rOwned.script == "external v2" && !rOwned.warnDiffers, true)
    // headless: the replace-script confirmation counts as cancel
    m.script = "unsaved stuff"
    m.openScriptFile()
    expectBool("headless open cancels instead of replacing", m.script == "unsaved stuff", true)
    // library names with sanitized characters map to the right file
    try? "colon body".write(to: tmp.appendingPathComponent("a:b.txt"), atomically: true, encoding: .utf8)
    m.refreshSavedNames()
    expectBool("colon name loads right file", m.loadScript("a:b") == "colon body", true)
    // deleting a script reports success — a failed Trash must not detach the note
    expectBool("delete missing script returns false", m.deleteScript("no-such-script"), false)
    expectBool("delete existing script returns true", m.deleteScript("Quick"), true)
    expectBool("deleted script leaves the list", m.savedNames.contains("Quick"), false)
    // library names resolve case-insensitively — the default filesystem is,
    // so "case test" and "Case Test.txt" are the same file
    m.saveScript("Case Test", text: "case v1")
    expectBool("case-insensitive load", m.loadScript("case test") == "case v1", true)
    m.saveScript("case test", text: "case v2")
    expectBool("case-insensitive save targets the existing file", m.loadScript("Case Test") == "case v2", true)
    expectBool("case save doesn't duplicate the listing",
               m.savedNames.filter { $0.caseInsensitiveCompare("case test") == .orderedSame }.count == 1, true)
    expectBool("case-insensitive delete", m.deleteScript("CASE TEST"), true)
    // trashing the note's own file detaches the note even when the typed case
    // differs from the on-disk name — a stale attachment would let the next
    // ⌘S/goLive quietly recreate the file the user just trashed
    m.scriptName = "talk"
    m.libraryBaseline = "talk body"
    m.detachIfOwnsScript(named: "Talk")
    expectBool("trash detaches owning note case-insensitively",
               m.scriptName.isEmpty && m.libraryBaseline == nil, true)
    m.scriptName = "Other"
    m.libraryBaseline = "other body"
    m.detachIfOwnsScript(named: "Talk")
    expectBool("trash leaves unrelated note attached",
               m.scriptName == "Other" && m.libraryBaseline == "other body", true)
    // whitespace can't keep a note attached either — scriptURL trims, so a
    // scriptName saved with stray whitespace names the same on-disk file
    m.scriptName = "Talk "
    m.libraryBaseline = "talk body"
    m.detachIfOwnsScript(named: "Talk")
    expectBool("trash detaches owning note despite whitespace",
               m.scriptName.isEmpty && m.libraryBaseline == nil, true)
    m.scriptName = ""
    m.libraryBaseline = nil
    // the listing takes .TXT files but not folders named *.txt
    try? "upper body".write(to: tmp.appendingPathComponent("UPPER.TXT"), atomically: true, encoding: .utf8)
    try? FileManager.default.createDirectory(at: tmp.appendingPathComponent("folder.txt"), withIntermediateDirectories: true)
    m.refreshSavedNames()
    expectBool("uppercase .TXT listed", m.savedNames.contains("UPPER"), true)
    expectBool("uppercase .TXT loads", m.loadScript("UPPER") == "upper body", true)
    expectBool("txt-named folder not listed", m.savedNames.contains("folder"), false)
    // the Scripts sheet pre-trusts a name only when the note owns the library
    // script — file opens/imports must go through the Replace prompt
    m.scriptName = "Talk"
    m.libraryBaseline = "talk body"
    expectBool("library-owned note owns its script", m.ownsLibraryScript, true)
    m.sourceURL = shared          // opened file with a colliding name
    m.libraryBaseline = nil
    expectBool("opened file doesn't own library script", m.ownsLibraryScript, false)
    m.sourceURL = nil             // RTF import: no source, no baseline
    expectBool("import doesn't own library script", m.ownsLibraryScript, false)
    m.scriptName = ""
    // the Scripts sheet shares the never-clobber rule: a .txt edited outside
    // the app since the draft was loaded blocks a silent sheet save
    // (headless alert = cancel)
    m.saveScript("Sheet", text: "sheet v1")
    try? "sheet theirs".write(to: tmp.appendingPathComponent("Sheet.txt"), atomically: true, encoding: .utf8)
    expectBool("sheet save blocked by external edits",
               m.confirmSheetOverwrite("Sheet", draft: "sheet mine", snapshot: "sheet v1"), false)
    expectBool("sheet save allowed when disk matches snapshot",
               m.confirmSheetOverwrite("Sheet", draft: "sheet mine", snapshot: "sheet theirs"), true)
    expectBool("sheet save allowed when disk matches draft",
               m.confirmSheetOverwrite("Sheet", draft: "sheet theirs", snapshot: "sheet v1"), true)
    m.libraryBaseline = "sheet theirs"   // owned-note draft: baseline covers it
    expectBool("sheet save allowed when disk matches note baseline",
               m.confirmSheetOverwrite("Sheet", draft: "sheet mine", snapshot: "sheet v1"), true)
    m.libraryBaseline = nil
    expectBool("sheet save of a fresh name allowed",
               m.confirmSheetOverwrite("Brand New", draft: "x", snapshot: ""), true)
    m.deleteScript("Sheet")
    // failed saves report failure
    let lockedDir = tmp.appendingPathComponent("locked", isDirectory: true)
    try? FileManager.default.createDirectory(at: lockedDir, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: lockedDir.path)
    m.setLibraryDir(lockedDir)
    expectBool("failed save returns false", m.saveScript("x", text: "y"), false)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedDir.path)
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
