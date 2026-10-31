import Foundation

// The page's dialogs drawn by the native window (lane S): the page keeps every
// decision and every act, and hands the native window only the question.
//
//   page → native   { type: 'dialog', name, open, seq, data }
//   native → page   window.tdDialog.run(name, action, arg)
//
// A dialog is drawn natively only when its name is in NativeScreens.registered
// (the page reads that list), so a page in any other window keeps drawing its own.
// The page side is src/renderer/native-dialogs.ts.

/// One open (or just closed) dialog, as the page described it.
public struct DialogRequest: Equatable, Sendable {
    public let name: String
    public let open: Bool
    /// The page's count for this message: a newer one replaces an older one.
    public let seq: Int
    /// Which opening: the same while the dialog is up and only updated, new when it opens again.
    public let opening: Int
    /// `data`, as JSON, decoded by the dialog that draws it.
    public let data: Data

    public init(name: String, open: Bool, seq: Int, opening: Int? = nil, data: Data = Data("{}".utf8)) {
        self.name = name; self.open = open; self.seq = seq; self.opening = opening ?? seq; self.data = data
    }

    public func decode<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(T.self, from: data)
    }

    static func parse(_ dict: [String: Any]) -> DialogRequest? {
        guard let name = (dict["name"] as? String)?.nonEmpty, let open = dict["open"] as? Bool else { return nil }
        let seq = (dict["seq"] as? NSNumber)?.intValue ?? 0
        let opening = (dict["opening"] as? NSNumber)?.intValue
        var data = Data("{}".utf8)
        if let payload = dict["data"], JSONSerialization.isValidJSONObject(payload),
           let encoded = try? JSONSerialization.data(withJSONObject: payload) {
            data = encoded
        }
        return DialogRequest(name: name, open: open, seq: seq, opening: opening, data: data)
    }
}

/// The answer to a dialog: `window.tdDialog.run(name, action, arg)`.
public struct DialogCommand: Equatable, Sendable {
    public let name: String
    public let action: String
    /// JSON for the argument, or nil for none.
    public let argument: String?

    public init(_ name: String, _ action: String, argument: [String: Any]? = nil) {
        self.name = name
        self.action = action
        if let argument, JSONSerialization.isValidJSONObject(argument),
           let data = try? JSONSerialization.data(withJSONObject: argument, options: [.sortedKeys]) {
            self.argument = String(decoding: data, as: UTF8.self)
        } else {
            self.argument = nil
        }
    }

    public init(_ name: String, _ action: String, text: String) {
        self.name = name
        self.action = action
        self.argument = PageCommand.javaScriptString(text)
    }

    public static func == (a: DialogCommand, b: DialogCommand) -> Bool {
        a.name == b.name && a.action == b.action && a.argument == b.argument
    }

    public var script: String {
        let head = "window.tdDialog && window.tdDialog.run(\(PageCommand.javaScriptString(name)), \(PageCommand.javaScriptString(action))"
        guard let argument else { return head + ")" }
        // JSON is JavaScript, except that U+2028/2029 end a line in older engines.
        let safe = argument.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return head + ", " + safe + ")"
    }
}

// MARK: Close session (CloseSessionConfirm.tsx)

public enum CloseSubject: String, Decodable, Sendable {
    case session, project, machine, server

    /// GROUP_NOUN
    public var groupNoun: String { self == .server ? "terminals" : "sessions" }
}

/// What the close-confirm is asked, as the page computed it.
public struct CloseConfirmRequest: Decodable, Equatable, Sendable {
    public let title: String
    public let status: String
    public let count: Int
    public let subject: CloseSubject
    /// The provider can resume a conversation (PROVIDER_OPTIONS' canResume).
    public let canResume: Bool
    /// B1, B2 … browser windows attached to this session: they stay open, detached.
    public let attachedWindows: [Int]

    enum CodingKeys: String, CodingKey { case title, status, count, subject, canResume, attachedWindows }

    public init(title: String, status: String, count: Int = 1, subject: CloseSubject = .project,
                canResume: Bool = false, attachedWindows: [Int] = []) {
        self.title = title; self.status = status; self.count = count; self.subject = subject
        self.canResume = canResume; self.attachedWindows = attachedWindows
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(title: (try? c.decode(String.self, forKey: .title)) ?? "",
                  status: (try? c.decode(String.self, forKey: .status)) ?? "idle",
                  count: max(1, (try? c.decode(Int.self, forKey: .count)) ?? 1),
                  subject: (try? c.decode(CloseSubject.self, forKey: .subject)) ?? .project,
                  canResume: (try? c.decode(Bool.self, forKey: .canResume)) ?? false,
                  attachedWindows: (try? c.decode([Int].self, forKey: .attachedWindows)) ?? [])
    }

    public var isGroup: Bool { count > 1 }

    /// The dialog's title.
    public var heading: String { isGroup ? "Delete these \(subject.groupNoun)?" : "Delete this session?" }

    /// The destructive button: "Delete", "Delete sessions", "Delete terminals".
    public var confirmLabel: String { isGroup ? "Delete \(subject.groupNoun)" : "Delete" }

    /// closeWarning, with the resume sentence when the conversation is kept.
    public var warning: (headline: String, detail: String) {
        let w = Self.closeWarning(status: status, count: count, subject: subject)
        let detail = canResume
            ? "\(w.detail) The conversation itself is kept — a new session in this folder can continue it."
            : w.detail
        return (w.headline, detail)
    }

    /// AttachedWindowsLine: "B1 stays open, detached." / "B1, B2 and B3 stay open, detached."
    public var attachedLine: String? {
        guard !attachedWindows.isEmpty else { return nil }
        let slots = attachedWindows.map { "B\($0)" }
        let named = slots.count == 1 ? slots[0] : slots.dropLast().joined(separator: ", ") + " and " + slots.last!
        return "\(named) \(slots.count == 1 ? "stays" : "stay") open, detached."
    }

    /// closeWarning() in CloseSessionConfirm.tsx, word for word.
    public static func closeWarning(status: String, count: Int = 1, subject: CloseSubject = .project) -> (headline: String, detail: String) {
        if subject == .machine && count > 1 {
            return ("This deletes \(count) sessions on that machine.",
                    "Every one of them stops where it is, on that machine, and anything they have not written to disk goes with them. The machine itself stays connected — New session brings it straight back.")
        }
        if subject == .machine {
            return ("This ends the session on that machine.",
                    "The agent stops there and its terminal goes, with its scrollback. The machine itself stays connected.")
        }
        if subject == .server && count > 1 {
            return ("This deletes \(count) terminals on that server.",
                    "Each of them stops where it is, and anything half-typed goes with it. Nothing else on the server is touched — whatever it was running before, it is still running now.")
        }
        if subject == .server {
            return ("This deletes the terminal on that server.",
                    "Whatever is running inside it stops, and the terminal goes with its scrollback. Nothing else on the server is touched — it keeps running exactly as it was, and you can open another terminal whenever you like.")
        }
        if count > 1 {
            return ("This deletes \(count) sessions in that project.",
                    "Every one of them stops where it is. Anything they have not already written to disk goes with them.")
        }
        switch status {
        case "input":
            return ("This session asked you something.",
                    "It is blocked until it gets an answer. Deleting it now discards the question and whatever it was about to do.")
        case "working":
            return ("This session is still working.",
                    "Deleting it stops the agent part-way through. Anything it has not already written to disk goes with it.")
        case "exited":
            return ("This session has already ended.",
                    "Deleting takes the row out of the sidebar. Its scrollback goes with it.")
        default:
            return ("Deleting this session ends it.",
                    "The agent stops and the terminal goes, with its scrollback and anything half-typed in it. It cannot be reopened where it left off.")
        }
    }
}

// MARK: Switch account (SwitchAccountConfirm.tsx)

/// What the switch-account confirm shows, worded by the page (session-switch.ts).
public struct SwitchAccountRequest: Decodable, Equatable, Sendable {
    public let title: String
    public let fromName: String
    public let toName: String
    /// The plan has been worked out (otherwise: still working, or nothing could be).
    public let planned: Bool
    public let refusal: String?
    public let tag: String?
    /// The ⓘ note: what switching does to the conversation, and what it keeps.
    public let note: String
    public let busy: Bool
    public let problem: String?
    public let canDefer: Bool

    enum CodingKeys: String, CodingKey { case title, fromName, toName, planned, refusal, tag, note, busy, problem, canDefer }

    public init(title: String = "", fromName: String = "", toName: String = "", planned: Bool = false, refusal: String? = nil,
                tag: String? = nil, note: String = "", busy: Bool = false, problem: String? = nil, canDefer: Bool = false) {
        self.title = title; self.fromName = fromName; self.toName = toName; self.planned = planned; self.refusal = refusal
        self.tag = tag; self.note = note; self.busy = busy; self.problem = problem; self.canDefer = canDefer
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ k: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil }
        func flag(_ k: CodingKeys) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? false }
        self.init(title: text(.title) ?? "", fromName: text(.fromName) ?? "", toName: text(.toName) ?? "",
                  planned: flag(.planned), refusal: text(.refusal), tag: text(.tag), note: text(.note) ?? "",
                  busy: flag(.busy), problem: text(.problem), canDefer: flag(.canDefer))
    }

    /// Switching is possible: a plan, no refusal.
    public var canSwitch: Bool { planned && refusal == nil }
    /// "Switch now" (and "Switch at my next message") are offered.
    public var offersSwitch: Bool { canSwitch && problem == nil }
    public var heading: String { "Switch to \(toName)?" }
    public var dismissLabel: String { offersSwitch ? "Cancel" : "Close" }
    public var confirmLabel: String { busy ? "Switching…" : "Switch now" }
    /// While nothing is planned yet, or nothing could be.
    public var pendingLine: String? {
        guard !planned, problem == nil else { return nil }
        return busy ? "Working out what this would do…" : "Nothing could be worked out about this switch."
    }
}
