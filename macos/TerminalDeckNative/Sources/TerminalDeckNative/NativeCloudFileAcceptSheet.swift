import AppKit
import TerminalDeckBackend
import TerminalDeckNativeCore

/// One boot file from the Cloud that waits on this Mac because it can run a command or let tools run (lean scope
/// item 8; lane F decides which files those are and says what in them can run). Nothing of it is written until the
/// person accepts it in this Mac's own window.
struct NativeCloudFileAcceptRequest: Sendable, Equatable {
    /// Lane F's id of the waiting file.
    let id: String
    /// Where the file would be written on this Mac, as the person should read it.
    let path: String
    /// What in it can run, one plain line each, in lane F's words.
    let runs: [String]
    /// The name the sending device gives itself (shown as a quoted claim), if lane F knows it.
    let from: String?
    /// This Mac already has a different file there: accepting replaces it and keeps this Mac's version as another version.
    let replaces: Bool
    /// Security review M3: the file itself, from the EXACT bytes `accept` writes (lane F's `review(id)`): the header,
    /// every line that can run a command or pull in a file, the start of a script. Each line is the other device's
    /// text: shown only inside the box, numbered, with control characters written out.
    let shown: [CloudBootFilesShownLine]
    /// How many lines the whole file has.
    let totalLines: Int
    /// S12: false for another version of a plain file (it does not run anything): the sheet then says so.
    let canRun: Bool
    init(id: String, path: String, runs: [String], from: String? = nil, replaces: Bool = false, shown: [CloudBootFilesShownLine] = [],
         totalLines: Int = 0, canRun: Bool = true) {
        self.id = id
        self.path = path
        self.runs = runs
        self.from = from
        self.replaces = replaces
        self.shown = shown
        self.totalLines = totalLines
        self.canRun = canRun
    }
}

/// The accept sheet. Behind the same remote-input guard as the trust buttons (shown only through
/// `NativeCloudSheetGuard.present`): "Not now" is the default button and answers Return, "Accept this file" takes a
/// click, cannot hold the keyboard focus, is refused when the app's own remote input posted in the two seconds
/// before the press, and the sheet closes when remote control of this Mac starts or ends. No tool opens or answers it.
@MainActor
enum NativeCloudFileAcceptSheet {
    /// What the person chose. `keepMine` exists only where this Mac already has a different file at that place.
    enum Answer: Sendable, Equatable { case accept, keepMine, notNow }
    static let accept = NSApplication.ModalResponse.alertSecondButtonReturn
    /// "Keep this Mac's file": a refusal that also takes the other version off the waiting list.
    static let keepMine = NSApplication.ModalResponse.alertThirdButtonReturn
    static let title = "Accept this file from your Cloud?"
    static let lead = "This file came from one of your other devices. It can run a command or let tools run without asking, so nothing is written until you accept it here. Read what is listed below first. Accepting writes the file as text; it does not run it."
    /// S12: another version of a plain file, which does not run anything.
    static let versionTitle = "Use this version from your Cloud?"
    static let versionLead = "Another device has a different version of this file. Nothing is written until you choose here. Read the file in the box below first."
    static let replacesLine = "This Mac already has a different file at that place. If you accept, this Mac's file is kept as another version. If you keep this Mac's file, the other version is taken off this list."
    static let refused = "This Mac was just being controlled from another device, so the file was not accepted. Wait a moment and choose Accept yourself."
    /// Everything shown about the file is text another device chose. It is shown in a box of its own, in fixed
    /// type, one plain line per item: control, invisible and direction characters are written out as \u{XXXX},
    /// a line is cut at 300 characters and the list at 40 lines, so nothing in it can look like the sheet's own words.
    nonisolated static func plain(_ text: String, limit: Int = 300) -> String {
        var out = ""
        var count = 0
        for scalar in text.unicodeScalars {
            if count >= limit { out += "…"; break }
            let hidden = scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format
                || scalar.properties.generalCategory == .lineSeparator || scalar.properties.generalCategory == .paragraphSeparator
                || scalar.properties.isDefaultIgnorableCodePoint
            if hidden { out += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}" } else { out.unicodeScalars.append(scalar) }
            count += 1
        }
        return out
    }
    /// The box's text: the place first, then what can run, then the file itself (security review M3).
    nonisolated static func details(_ request: NativeCloudFileAcceptRequest) -> String {
        var lines = ["Written to:", "  " + plain(request.path), "", "What in it can run:"]
        let shown = request.runs.prefix(40)
        if shown.isEmpty { lines.append("  (not listed)") }
        for line in shown { lines.append("  " + plain(line)) }
        if request.runs.count > shown.count { lines.append("  … and \(request.runs.count - shown.count) more") }
        if let from = request.from { lines += ["", "From the device that calls itself: “" + BackendCloudTrustRows.plainName(from) + "”"] }
        lines += [""] + fileLines(request)
        return lines.joined(separator: "\n")
    }
    /// The file's own lines, exactly as they would be written, each after a line number and a bar so no line of the
    /// file can pass for the sheet's words. At most 400 lines (lane F already caps them), each cut at 500 characters.
    nonisolated static func fileLines(_ request: NativeCloudFileAcceptRequest) -> [String] {
        let total = max(request.totalLines, request.shown.count)
        var lines = ["The file itself, \(request.shown.count) of \(total) lines (the header and every line that can run are always shown):"]
        if request.shown.isEmpty { lines.append("  (nothing to show)") }
        for line in request.shown.prefix(400) {
            let number = String(line.number)
            lines.append(String(repeating: " ", count: max(0, 5 - number.count)) + number + " │ " + plain(line.text, limit: 500))
        }
        return lines
    }
    static func alert(_ request: NativeCloudFileAcceptRequest) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = request.canRun ? title : versionTitle
        let opening = request.canRun ? lead : versionLead
        alert.informativeText = request.replaces ? opening + "\n\n" + replacesLine : opening
        alert.accessoryView = box(details(request))
        let refuse = alert.addButton(withTitle: "Not now")
        refuse.keyEquivalent = "\r"
        alert.addButton(withTitle: "Accept this file")
        // Only where there is a file of this Mac's to keep. It changes no file; it needs a click, not a key.
        if request.replaces { alert.addButton(withTitle: "Keep this Mac’s file").keyEquivalent = "" }
        NativeCloudSheetGuard.harden(alert, accept: accept)
        return alert
    }
    /// A scrolling, selectable, fixed-width box: a long list never pushes the buttons off the screen.
    static func box(_ text: String) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 520, height: 280))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: scroll.bounds)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.textContainerInset = NSSize(width: 6, height: 6)
        // Long lines scroll sideways instead of wrapping, so a line of the file never looks like two.
        view.isHorizontallyResizable = true
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.string = text
        view.setAccessibilityLabel("The file's place, what in it can run, and the file itself")
        scroll.documentView = view
        return scroll
    }
    /// What a sheet's answer means. `accept` only on the person's own press of "Accept this file".
    nonisolated static func meaning(_ answer: NativeCloudSheetAnswer, replaces: Bool) -> Answer {
        if answer.taken { return .accept }
        if replaces, !answer.chose, answer.response == NSApplication.ModalResponse.alertThirdButtonReturn.rawValue { return .keepMine }
        return .notNow
    }
    /// `accept` only on the person's own press of "Accept this file" in this Mac's window. Without a window
    /// nothing is accepted.
    static func ask(_ request: NativeCloudFileAcceptRequest, model: NativeCloudAccount = .shared) async -> Answer {
        NativeFront.onlyForPerson("Cloud: accept a file") { NSApp?.activate() }
        guard let window = NSApp?.keyWindow ?? NSApp?.mainWindow else { return .notNow }
        let answer = await NativeCloudSheetGuard.shared.present(alert(request), on: window, accept: accept)
        if answer.chose, !answer.taken { model.say(refused) }
        return meaning(answer, replaces: request.replaces)
    }
}
