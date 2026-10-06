import AppKit
import SwiftUI
import TerminalDeckNativeCore

// The task text (task-text-field.tsx, inline-title.tsx, feed/mention.tsx): a plain
// string in which `[[file:<id>]]` stands for a file. Shown, each file is a small
// thumbnail (a picture) or glyph the height of the text, and "@Name" of someone on
// the task is a chip; edited, it is the same text with the same chips, where "@"
// opens a list of people and picking one writes "@Name " and puts them on the task.

extension NSAttributedString.Key {
    static let crmFileId = NSAttributedString.Key("td.crm.fileId")
}

/// Where files dropped or pasted on the popup go (use-file-drop.ts): onto the task, and
/// into the heading while it is being written. The popup sets it; every text box in it
/// hands its files over, and says when a file is being dragged over it.
struct TaskFileDoor {
    let attach: @MainActor ([URL]) -> Void
    var hover: @MainActor (Bool) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var taskFileDoor: TaskFileDoor? = nil
}

/// What a file token draws as.
struct InlineFile {
    let image: NSImage?
    let name: String
}

/// The rich text, display or editing.
struct TaskRichText: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool
    var font: NSFont = .systemFont(ofSize: 14)
    var color: NSColor = .labelColor
    var strike = false
    var placeholder: String = ""
    /// Files by id, for the chips.
    var fileOf: (String) -> InlineFile? = { _ in nil }
    /// People whose "@Name" is a chip.
    var mentionNames: [String] = []
    /// The caret is in an "@…" (flat start, query), or not.
    var onMentionTrigger: ((Int, String)?) -> Void = { _ in }
    var onEscape: (() -> Void)?
    var onSubmit: (() -> Void)?
    /// A click on text while not editing.
    var onClickText: (() -> Void)?
    var onClickFile: ((String) -> Void)?
    /// Arrow and Return keys while the mention list is open: true when taken.
    var onMentionKey: ((String) -> Bool)?
    var autoFocus = false
    /// Set to insert something at the caret (a picked "@Name ", a file); cleared after.
    @Binding var insertion: TaskTextInsertion?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextView {
        let view = RichTextView()
        view.coordinator = context.coordinator
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        context.coordinator.render(view, force: true)
        if autoFocus {
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.parent = self
        (view as? RichTextView)?.fileDoor = context.environment.taskFileDoor
        view.isEditable = editable
        view.isSelectable = true
        context.coordinator.render(view, force: false)
        if let insertion {
            context.coordinator.insert(insertion, into: view)
            DispatchQueue.main.async { self.insertion = nil }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 400
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let line = font.ascender - font.descender + font.leading
        return CGSize(width: width, height: max(ceil(used.height), ceil(line)))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TaskRichText
        private var rendered: String?

        init(_ parent: TaskRichText) { self.parent = parent }

        /// The attributed form of the storage text.
        func attributed(_ storage: String) -> NSAttributedString {
            let out = NSMutableAttributedString()
            let base: [NSAttributedString.Key: Any] = [
                .font: parent.font, .foregroundColor: parent.color,
                .strikethroughStyle: parent.strike ? NSUnderlineStyle.single.rawValue : 0,
            ]
            for part in CrmText.splitInlineFiles(storage) {
                switch part {
                case .text(let t):
                    let piece = NSMutableAttributedString(string: t, attributes: base)
                    if !parent.editable { styleMentions(piece) }
                    out.append(piece)
                case .file(let id):
                    out.append(chip(id))
                }
            }
            if out.length == 0 && !parent.placeholder.isEmpty && !parent.editable {
                out.append(NSAttributedString(string: parent.placeholder, attributes: [.font: parent.font, .foregroundColor: NSColor.placeholderTextColor]))
            }
            return out
        }

        private func styleMentions(_ s: NSMutableAttributedString) {
            let names = parent.mentionNames.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.sorted { $0.count > $1.count }
            guard !names.isEmpty else { return }
            let ns = s.string as NSString
            for name in names {
                var range = NSRange(location: 0, length: ns.length)
                while true {
                    let found = ns.range(of: "@" + name, options: [], range: range)
                    if found.location == NSNotFound { break }
                    let end = found.location + found.length
                    let boundary = end == ns.length || ",.!?;:) \n\t".contains(Character(ns.substring(with: NSRange(location: end, length: 1))))
                    if boundary {
                        s.addAttributes([.foregroundColor: NSColor.controlAccentColor,
                                         .font: NSFontManager.shared.convert(parent.font, toHaveTrait: .boldFontMask),
                                         .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.12)], range: found)
                    }
                    range = NSRange(location: end, length: ns.length - end)
                }
            }
        }

        private func chip(_ id: String) -> NSAttributedString {
            let size = parent.font.pointSize * 1.3
            let attachment = NSTextAttachment()
            let file = parent.fileOf(id)
            let image: NSImage = {
                if let picture = file?.image {
                    return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
                        picture.draw(in: rect)
                        return true
                    }
                }
                let symbol = file == nil ? "paperclip" : "doc.text"
                let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: file?.name ?? "Removed attachment") ?? NSImage()
                return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                    NSColor.secondaryLabelColor.withAlphaComponent(0.15).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
                    glyph.draw(in: rect.insetBy(dx: size * 0.2, dy: size * 0.2))
                    return true
                }
            }()
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: parent.font.descender, width: size, height: size)
            let s = NSMutableAttributedString(attachment: attachment)
            s.addAttribute(.crmFileId, value: id, range: NSRange(location: 0, length: s.length))
            let tip = file.map { $0.image != nil ? "\($0.name) — click for the big view" : $0.name } ?? "This file is no longer attached"
            s.addAttribute(.toolTip, value: tip, range: NSRange(location: 0, length: s.length))
            return s
        }

        /// The storage text back from the view: each chip as its token.
        func serialise(_ view: NSTextView) -> String {
            guard let storage = view.textStorage else { return view.string }
            var out = ""
            storage.enumerateAttribute(.crmFileId, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                let piece = (storage.string as NSString).substring(with: range)
                if let id = value as? String {
                    out += String(repeating: CrmText.fileToken(id), count: piece.filter { $0 == CrmText.chipChar }.count)
                } else {
                    out += piece.replacingOccurrences(of: String(CrmText.chipChar), with: "")
                }
            }
            return out
        }

        func render(_ view: NSTextView, force: Bool) {
            let key = "\(parent.text)|\(parent.editable)|\(parent.strike)|\(parent.mentionNames.joined(separator: ","))"
            if !force && key == rendered { return }
            // While editing, the view owns the text; only an outside change is drawn in.
            if parent.editable && !force && serialise(view) == parent.text && rendered?.hasPrefix(parent.text + "|") == true {
                rendered = key
                return
            }
            rendered = key
            let selection = view.selectedRange()
            view.textStorage?.setAttributedString(attributed(parent.text))
            view.typingAttributes = [.font: parent.font, .foregroundColor: parent.color]
            if parent.editable { view.setSelectedRange(NSRange(location: min(selection.location, view.string.utf16.count), length: 0)) }
        }

        func insert(_ insertion: TaskTextInsertion, into view: NSTextView) {
            switch insertion {
            case .mention(let start, let name):
                let caret = view.selectedRange().location
                let range = NSRange(location: start, length: max(0, caret - start))
                view.insertText("@\(name) ", replacementRange: range)
            case .file(let id):
                view.textStorage?.insert(chip(id), at: view.selectedRange().location)
                textDidChange(Notification(name: NSText.didChangeNotification, object: view))
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let value = serialise(view)
            rendered = "\(value)|\(parent.editable)|\(parent.strike)|\(parent.mentionNames.joined(separator: ","))"
            parent.text = value
            noteCaret(view)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, parent.editable else { return }
            noteCaret(view)
        }

        /// "@" at the start or after a space, then no space up to the caret.
        private func noteCaret(_ view: NSTextView) {
            let flat = view.string as NSString
            let caret = min(view.selectedRange().location, flat.length)
            let head = flat.substring(to: caret)
            guard let at = head.lastIndex(of: "@") else { return parent.onMentionTrigger(nil) }
            let i = head.distance(from: head.startIndex, to: at)
            if i > 0, !head[head.index(before: at)].isWhitespace { return parent.onMentionTrigger(nil) }
            let after = String(head[head.index(after: at)...])
            if after.contains(where: \.isWhitespace) { return parent.onMentionTrigger(nil) }
            parent.onMentionTrigger((NSString(string: String(head[..<at])).length, after))
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if let key = Self.keys[selector], parent.onMentionKey?(key) == true { return true }
            if selector == #selector(NSResponder.cancelOperation(_:)), let escape = parent.onEscape {
                escape()
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)), NSApp.currentEvent?.modifierFlags.contains(.command) == true,
               let submit = parent.onSubmit {
                submit()
                return true
            }
            return false
        }

        static let keys: [Selector: String] = [
            #selector(NSResponder.moveDown(_:)): "down", #selector(NSResponder.moveUp(_:)): "up",
            #selector(NSResponder.insertNewline(_:)): "enter", #selector(NSResponder.insertTab(_:)): "tab",
            #selector(NSResponder.cancelOperation(_:)): "escape",
        ]

        func textView(_ textView: NSTextView, clickedOn cell: any NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {
            if let id = textView.textStorage?.attribute(.crmFileId, at: charIndex, effectiveRange: nil) as? String {
                parent.onClickFile?(id)
            }
        }
    }

    /// The text view, which tells a click on plain text while not editing.
    final class RichTextView: NSTextView {
        weak var coordinator: Coordinator?
        /// Files pasted or dropped here go to the task, not into the text as a path.
        var fileDoor: TaskFileDoor? {
            didSet { if (oldValue == nil) != (fileDoor == nil) { updateDragTypeRegistration() } }
        }
        /// The clipboard a paste reads (the person's own; a check passes a private one).
        var board: NSPasteboard = .general

        /// Shown text takes no drop, so a dropped file reaches the popup; text being written
        /// takes it itself, at the point it is dropped.
        override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
            fileDoor != nil && !isEditable ? [] : super.acceptableDragTypes
        }

        override var isEditable: Bool {
            didSet { if oldValue != isEditable && fileDoor != nil { updateDragTypeRegistration() } }
        }

        private func takesFiles(_ sender: NSDraggingInfo) -> Bool {
            fileDoor != nil && isEditable && Self.hasFiles(on: sender.draggingPasteboard)
        }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            let op = super.draggingEntered(sender)
            guard takesFiles(sender) else { return op }
            fileDoor?.hover(true)
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            let op = super.draggingUpdated(sender)
            return takesFiles(sender) ? .copy : op
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            super.draggingExited(sender)
            if let sender, takesFiles(sender) { fileDoor?.hover(false) }
        }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            takesFiles(sender) ? true : super.prepareForDragOperation(sender)
        }

        /// A file dropped on the text being written lands where it was dropped (task-text-field.tsx handleDrop).
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            guard takesFiles(sender), let door = fileDoor, let urls = Self.files(on: sender.draggingPasteboard), !urls.isEmpty else {
                return super.performDragOperation(sender)
            }
            let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
            window?.makeFirstResponder(self)
            setSelectedRange(NSRange(location: min(max(0, index), (string as NSString).length), length: 0))
            door.hover(false)
            door.attach(urls)
            return true
        }

        /// A file or a picture on the clipboard is attached; anything else goes in as plain text.
        override func paste(_ sender: Any?) {
            if let fileDoor, let files = Self.files(on: board), !files.isEmpty {
                fileDoor.attach(files)
                return
            }
            pasteAsPlainText(sender)
        }

        /// Shown text takes a pasted file too, as the web's popup does with focus anywhere in it.
        override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
            if menuItem.action == #selector(paste(_:)), fileDoor != nil, Self.hasFiles(on: board) { return true }
            return super.validateMenuItem(menuItem)
        }

        /// A file or a picture is on this pasteboard (cheap: nothing is read or written).
        static func hasFiles(on board: NSPasteboard) -> Bool {
            board.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                || board.availableType(from: [.png, .tiff]) != nil
        }

        /// The clipboard's files, or its picture saved as "Screenshot yyyy-mm-dd HH.MM.png".
        static func files(on board: NSPasteboard) -> [URL]? {
            if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                return urls
            }
            let png = board.data(forType: .png)
                ?? board.data(forType: .tiff).flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
            guard let png else { return nil }
            let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: Date())
            let name = String(format: "Screenshot %04d-%02d-%02d %02d.%02d.png", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            guard (try? png.write(to: url)) != nil else { return nil }
            return [url]
        }

        override func mouseDown(with event: NSEvent) {
            if !isEditable, let coordinator, let click = coordinator.parent.onClickText {
                let point = convert(event.locationInWindow, from: nil)
                let index = characterIndexForInsertion(at: point)
                let onFile = index < (textStorage?.length ?? 0) && textStorage?.attribute(.crmFileId, at: index, effectiveRange: nil) != nil
                if !onFile {
                    click()
                    return
                }
            }
            super.mouseDown(with: event)
        }

        override func resetCursorRects() {
            if !isEditable && coordinator?.parent.onClickText != nil { addCursorRect(bounds, cursor: .iBeam) } else { super.resetCursorRects() }
        }
    }
}

enum TaskTextInsertion: Equatable {
    case mention(start: Int, name: String)
    case file(String)
}

/// An editor with its "@" list: the rich text, and under it the people who match.
struct TaskTextEditor: View {
    @Binding var text: String
    let team: [CrmPerson]
    var placeholder = ""
    var font: NSFont = .systemFont(ofSize: 14)
    var fileOf: (String) -> InlineFile? = { _ in nil }
    var onMention: (CrmPerson) -> Void = { _ in }
    var onEscape: (() -> Void)?
    var onSubmit: (() -> Void)?
    var autoFocus = true
    @Binding var insertion: TaskTextInsertion?
    @State private var trigger: (start: Int, query: String)?
    @State private var active = 0

    private var results: [CrmPerson] {
        guard let q = trigger?.query.lowercased() else { return [] }
        let hits = q.isEmpty ? team : team.filter { p in
            let n = p.name.lowercased()
            return n.contains(q) || n.split(whereSeparator: { $0.isWhitespace }).contains { $0.hasPrefix(q) }
        }
        return Array(hits.prefix(8))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TaskRichText(text: $text, editable: true, font: font, placeholder: placeholder, fileOf: fileOf,
                         onMentionTrigger: { t in
                             trigger = t.map { ($0.0, $0.1) }
                             active = 0
                         },
                         onEscape: {
                             if trigger != nil { trigger = nil } else { onEscape?() }
                         },
                         onSubmit: onSubmit,
                         onMentionKey: { key in handleKey(key) },
                         autoFocus: autoFocus,
                         insertion: $insertion)
            if text.isEmpty && !placeholder.isEmpty {
                Text(placeholder).font(Font(font)).foregroundStyle(.tertiary).allowsHitTesting(false)
            }
        }
        .popover(isPresented: Binding(get: { trigger != nil }, set: { if !$0 { trigger = nil } }), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                if results.isEmpty {
                    Text("No one matches “\(trigger?.query ?? "")”.").font(.caption).foregroundStyle(.secondary).padding(10)
                }
                ForEach(Array(results.enumerated()), id: \.element.id) { i, p in
                    Button { pick(p) } label: {
                        HStack(spacing: 8) {
                            PersonAvatar(person: p)
                            Text(p.name).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(i == active ? Color.secondary.opacity(0.12) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { if $0 { active = i } }
                }
            }
            .padding(.vertical, 4)
            .frame(width: 280)
            .accessibilityLabel("People")
        }
    }

    private func handleKey(_ key: String) -> Bool {
        guard trigger != nil else { return false }
        switch key {
        case "down":
            if !results.isEmpty { active = (active + 1) % results.count }
            return true
        case "up":
            if !results.isEmpty { active = (active - 1 + results.count) % results.count }
            return true
        case "enter", "tab":
            if results.indices.contains(active) {
                pick(results[active])
                return true
            }
            return false
        case "escape":
            trigger = nil
            return true
        default: return false
        }
    }

    private func pick(_ p: CrmPerson) {
        guard let t = trigger else { return }
        insertion = .mention(start: t.start, name: p.name)
        trigger = nil
        onMention(p)
    }
}

// MARK: - Paste with no text box to type in

/// The popup's paste door (use-file-drop.ts `onPaste` on the whole popup): a file or a
/// picture on the clipboard is attached to the task. It sits right after the window in
/// the responder chain while the popup is up, so anything that types takes a paste first;
/// with nothing to type in, Edit ▸ Paste (⌘V) reaches it.
@MainActor
final class TaskPasteDoor: NSResponder, NSMenuItemValidation {
    var attach: (@MainActor ([URL]) -> Void)?
    var board: NSPasteboard = .general

    @objc func paste(_ sender: Any?) {
        guard let files = TaskRichText.RichTextView.files(on: board), !files.isEmpty else { return }
        attach?(files)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(paste(_:)) && TaskRichText.RichTextView.hasFiles(on: board)
    }
}

/// Puts the paste door in place while the popup is on screen, and takes it out after.
/// A one-line box (or other plain text) in the popup that is being typed in takes ⌘V
/// for text; with a file or a picture on the clipboard the web attaches it instead, so
/// that ⌘V is caught here first.
struct TaskPasteDoorHost: NSViewRepresentable {
    let attach: @MainActor ([URL]) -> Void

    func makeNSView(context: Context) -> DoorView {
        let view = DoorView()
        view.door.attach = attach
        return view
    }

    func updateNSView(_ view: DoorView, context: Context) { view.door.attach = attach }

    static func dismantleNSView(_ view: DoorView, coordinator: ()) { view.uninstall() }

    final class DoorView: NSView {
        let door = TaskPasteDoor()
        private weak var host: NSWindow?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            uninstall()
            guard let window else { return }
            host = window
            door.nextResponder = window.nextResponder
            window.nextResponder = door
            // The popup is modal over the page, as the web's dialog takes the focus:
            // whatever was being typed in underneath stops taking keys.
            if window.firstResponder is NSText { window.makeFirstResponder(nil) }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                nonisolated(unsafe) let key = event
                let taken = MainActor.assumeIsolated { self?.take(key) ?? false }
                return taken ? nil : event
            }
        }

        /// ⌘V with a file or picture on the clipboard, typed in a plain box of the popup (or
        /// one of its popovers and sheets): attached, and the box gets nothing.
        func take(_ event: NSEvent) -> Bool {
            guard let host, let window = event.window,
                  window === host || window.parent === host || window.sheetParent === host,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "v",
                  let editor = window.firstResponder as? NSTextView, !(editor is TaskRichText.RichTextView),
                  TaskRichText.RichTextView.hasFiles(on: door.board),
                  let files = TaskRichText.RichTextView.files(on: door.board), !files.isEmpty else { return false }
            door.attach?(files)
            return true
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard let host else { return }
            var responder: NSResponder = host
            while let next = responder.nextResponder {
                if next === door {
                    responder.nextResponder = door.nextResponder
                    break
                }
                responder = next
            }
            door.nextResponder = nil
            self.host = nil
        }
    }
}
