import AppKit
import Observation
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Every permission or approval request, on screen at once (Asad, 10 Oct: "all the permission
/// popups should directly come to screen not in notifications for all agents and sessions").
///
/// Two sources feed one queue; each answer goes back through the decision path that source
/// already uses, so nothing here decides or widens anything by itself:
///  - consent questions (Hoot's own asks, agents and AI apps asking before a change) →
///    `BackendDeckCoreSecurityConsentBroker.respond` (the same call the consent sheet, Hoot's chat
///    card and the phone make);
///  - a terminal session stopped on its CLI's own permission menu (Claude Code, Codex, Gemini,
///    background agents, tasks and routines all run as sessions) → the menu's own number key
///    typed into that session (`session:write`), exactly what pressing it in the session does.
/// The island drops down with the oldest request; the rest wait behind it ("2 more").
/// A request answered anywhere else disappears here too.
@MainActor @Observable
final class NativePermissionDesk {
    static let shared = NativePermissionDesk()

    enum Source: Equatable { case consent, session(String) }
    struct Option: Identifiable, Equatable {
        let id: String
        let label: String
        let primary: Bool
    }
    struct Item: Identifiable, Equatable {
        let id: String
        let source: Source
        let asker: String
        let what: String
        let options: [Option]
        let at: Date
    }

    private(set) var items: [Item] = []
    private(set) var busy: Set<String> = []
    private(set) var problem: String?

    /// Supplied by the composition (NativeCompositionINT2PhoneHoot) with the real owners.
    @ObservationIgnored var answerConsent: (@Sendable (String, Bool) async -> Bool)?
    /// Drop the island down / let it settle (NativeCompositionHootUI).
    @ObservationIgnored var present: (() -> Void)?
    @ObservationIgnored var cleared: (() -> Void)?
    @ObservationIgnored private var sessionStatus: [String: String] = [:]
    @ObservationIgnored private var reading: Set<String> = []

    private init() {}

    /// What the island shows: a session whose own tab is in front already has its prompt in view.
    var visible: [Item] {
        items.filter { item in
            guard case .session(let id) = item.source else { return true }
            return !(NSApp.isActive && AppModel.shared.currentScreen?.id == id)
        }
    }
    var current: Item? { visible.first }

    /// Whether the island can carry requests right now (it is on and running natively).
    var islandOn: Bool { present != nil && IslandController.shared.isShown }

    // MARK: Sources

    func addConsent(id: String, asker: String, what: String) {
        add(Item(id: "consent:" + id, source: .consent, asker: asker, what: what,
                 options: [.init(id: "allow", label: "Allow", primary: true), .init(id: "deny", label: "Deny", primary: false)], at: Date()))
    }
    func settled(consent id: String) { remove("consent:" + id) }

    /// The island's snapshot of every session (id, label, status). A session that turns to
    /// "input" is read once: only a real numbered permission menu becomes a request.
    func sessionsChanged(_ rows: [NativeRPCValue]) {
        var seen = Set<String>()
        for row in rows {
            guard let id = row["id"].string else { continue }
            seen.insert(id)
            let status = row["status"].string ?? "idle"
            let before = sessionStatus.updateValue(status, forKey: id)
            if status != "input" { remove("session:" + id); continue }
            if before != "input" { readMenu(session: id, label: row["label"].string ?? "A session") }
        }
        for id in sessionStatus.keys where !seen.contains(id) { sessionStatus[id] = nil; remove("session:" + id) }
    }

    private func readMenu(session id: String, label: String) {
        guard !reading.contains(id) else { return }
        reading.insert(id)
        Task {
            defer { reading.remove(id) }
            // The CLI draws its menu a moment after the hook says it is waiting.
            try? await Task.sleep(for: .milliseconds(350))
            guard sessionStatus[id] == "input",
                  let raw = try? await EngineBridge.shared.invoke("session:scrollback", [id]) as? String,
                  let menu = Self.permissionMenu(in: raw) else { return }
            add(Item(id: "session:" + id, source: .session(id), asker: label, what: menu.question,
                     options: menu.options, at: Date()))
        }
    }

    // MARK: Answers

    func answer(_ item: Item, _ option: Option) {
        guard !busy.contains(item.id) else { return }
        busy.insert(item.id)
        Task {
            defer { busy.remove(item.id) }
            var ok = false
            switch item.source {
            case .consent:
                ok = await answerConsent?(String(item.id.dropFirst("consent:".count)), option.id == "allow") ?? false
            case .session(let session):
                // #87: the screen is read again first; the key is typed only while the very same menu still waits.
                // A menu that moved on (or was never one) gets nothing typed into it.
                guard await stillAsks(item, session: session) else {
                    problem = "That question changed in the session. Open it to answer there."; remove(item.id); return
                }
                // The menu's own key, typed into the session: the same as pressing it there.
                EngineBridge.shared.send("session:write", [session, option.id])
                ok = true
            }
            if ok { remove(item.id); problem = nil }
            else { problem = "That request was already answered or has expired."; remove(item.id) }
        }
    }

    private func stillAsks(_ item: Item, session: String) async -> Bool {
        guard sessionStatus[session] == "input",
              let raw = try? await EngineBridge.shared.invoke("session:scrollback", [session]) as? String,
              let menu = Self.permissionMenu(in: raw) else { return false }
        return sessionStatus[session] == "input" && Self.sameMenu(menu, as: item)
    }
    nonisolated static func sameMenu(_ menu: Menu, as item: Item) -> Bool { menu.question == item.what && menu.options == item.options }

    func openSession(_ item: Item) {
        guard case .session(let id) = item.source else { return }
        IslandController.shared.collapse()
        AppModel.shared.select(id)
        NativeFront.onlyForPerson("island permission") { NSApp.activate() }
    }

    // MARK: Queue

    private func add(_ item: Item) {
        guard !items.contains(where: { $0.id == item.id }) else { return }
        items.append(item)
        if !visible.isEmpty { present?() }
    }
    private func remove(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        if visible.isEmpty { cleared?() }
    }

    // MARK: Reading a CLI's permission menu

    struct Menu: Equatable { let question: String; let options: [Option] }

    /// The last numbered menu on the screen ("1. Yes", "2. Yes, and don't ask again…", "3. No…"),
    /// with the line that asks above it. Nil when the session is waiting for anything else
    /// (a plain prompt, a free-text question): those stay in the session, nothing is guessed.
    /// #87: a numbered Yes/No list in an answer is not a menu. A CLI menu has its selection mark on one
    /// option (❯ 1. Yes) and is the last thing on the screen: no prompt line follows it.
    nonisolated static func permissionMenu(in raw: String) -> Menu? {
        let text = stripTerminalCodes(raw)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(60)
            .map { $0.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespaces) }
        let decorations = CharacterSet(charactersIn: "│┃|>❯›▶●○◯ ")
        let box = CharacterSet(charactersIn: "│┃| ")
        var options: [(Int, String, Int, Bool)] = []   // number, label, line index, selection mark
        for (index, line) in lines.enumerated() {
            let bare = line.trimmingCharacters(in: decorations)
            guard let dot = bare.firstIndex(of: "."), let number = Int(bare[..<dot]), (1...9).contains(number) else { continue }
            let label = bare[bare.index(after: dot)...].trimmingCharacters(in: decorations)
            guard !label.isEmpty, label.count <= 120 else { continue }
            let marked = line.trimmingCharacters(in: box).first.map { "❯›>▶●".contains($0) } ?? false
            if number == 1 { options = [] }
            if number == (options.last?.0 ?? 0) + 1 { options.append((number, label, index, marked)) }
        }
        guard options.count >= 2, let first = options.first, let last = options.last,
              options.contains(where: { $0.3 }),
              options.contains(where: { $0.1.lowercased().hasPrefix("no") || $0.1.lowercased().contains("deny") }),
              options.contains(where: { $0.1.lowercased().hasPrefix("yes") || $0.1.lowercased().contains("allow") }) else { return nil }
        // A prompt below the list means the CLI is waiting for a message, not on a menu.
        let below = lines[(last.2 + 1)...].map { $0.trimmingCharacters(in: box) }
        if below.contains(where: { ["❯", "›", ">"].contains($0) || $0.hasPrefix("❯ ") || $0.hasPrefix("› ") || $0.hasPrefix("> ") || $0.contains("? for shortcuts") }) { return nil }
        // What it wants: the few meaningful lines above the menu (the command, its purpose, the question).
        let above = lines[..<first.2].map { $0.trimmingCharacters(in: decorations) }
            .filter { !$0.isEmpty && !$0.allSatisfy { "─━═-_╭╮╰╯".contains($0) } }
        let question = above.suffix(3).joined(separator: " · ").isEmpty ? "It needs your permission." : above.suffix(3).joined(separator: " · ")
        return Menu(question: String(question.prefix(160)),
                    options: options.map { Option(id: String($0.0), label: $0.1, primary: $0.0 == 1) })
    }

    nonisolated static func stripTerminalCodes(_ raw: String) -> String {
        var out = ""; var iterator = raw.unicodeScalars.makeIterator()
        while let scalar = iterator.next() {
            if scalar == "\u{1B}" {
                guard let next = iterator.next() else { break }
                if next == "[" { while let c = iterator.next(), !(0x40...0x7E).contains(c.value) {} }
                else if next == "]" { while let c = iterator.next(), c != "\u{07}" && c != "\u{1B}" {} }
                continue
            }
            if scalar.value < 0x20 && scalar != "\n" && scalar != "\r" && scalar != "\t" { continue }
            out.unicodeScalars.append(scalar)
        }
        return out
    }
}

/// The request card at the top of the open island: who asks, what in one line, the real buttons.
struct NativePermissionCard: View {
    let item: NativePermissionDesk.Item
    let more: Int
    @State private var desk = NativePermissionDesk.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                HootMark(size: 14, animated: false)
                Text(item.asker).font(.callout.weight(.semibold)).lineLimit(1)
                Text("· needs your permission").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if more > 0 { Text("\(more) more").font(.caption).foregroundStyle(.secondary) }
            }
            Text(item.what).font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true).help(item.what)
            // One row when the choices fit; otherwise one choice per line (CLI menus have long labels).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    openButton
                    Spacer(minLength: 0)
                    ForEach(item.options.reversed()) { option in choice(option) }
                }
                VStack(alignment: .trailing, spacing: 6) {
                    ForEach(item.options) { option in choice(option).frame(maxWidth: .infinity, alignment: .trailing) }
                    openButton
                }
            }
            .lineLimit(1)
            .disabled(desk.busy.contains(item.id))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quaternary.opacity(0.6)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.asker) needs your permission: \(item.what)")
    }
    @ViewBuilder private var openButton: some View {
        if case .session = item.source {
            Button("Open session") { desk.openSession(item) }.buttonStyle(.bordered)
        }
    }
    @ViewBuilder private func choice(_ option: NativePermissionDesk.Option) -> some View {
        if option.primary {
            Button(option.label) { desk.answer(item, option) }.buttonStyle(.borderedProminent).help(option.label)
        } else {
            Button(option.label) { desk.answer(item, option) }.buttonStyle(.bordered).help(option.label)
        }
    }
}
