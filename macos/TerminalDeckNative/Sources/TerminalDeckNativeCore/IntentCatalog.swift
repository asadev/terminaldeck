import Foundation

// Siri / Shortcuts (lane R): projects, agents and the spoken phrases — the pure parts.

/// One project folder Terminal Deck knows (`projects:list`).
public struct IntentProject: Equatable, Hashable, Sendable, Identifiable {
    /// The folder's full path — also the sidebar heading's id.
    public let path: String
    /// The name the sidebar shows (its heading), else the folder's name.
    public let name: String
    public let lastOpenedAt: Double

    public var id: String { path }

    public init(path: String, name: String, lastOpenedAt: Double = 0) {
        self.path = path
        self.name = name
        self.lastOpenedAt = lastOpenedAt
    }
}

public enum IntentProjects {
    /// `projects:list` (`[{path, lastOpenedAt}]`), named the way the sidebar names
    /// them when it has said (`headings`: path → title), most recently opened first.
    public static func parse(_ value: Any, headings: [String: String] = [:]) -> [IntentProject] {
        var seen = Set<String>()
        var out: [IntentProject] = []
        for case let raw as [String: Any] in (value as? [Any]) ?? [] {
            guard let path = raw["path"] as? String, path.hasPrefix("/"), seen.insert(path).inserted else { continue }
            let heading = headings[path].flatMap { $0.isEmpty ? nil : $0 }
            out.append(IntentProject(path: path, name: heading ?? folderName(path),
                                     lastOpenedAt: (raw["lastOpenedAt"] as? NSNumber)?.doubleValue ?? 0))
        }
        return out.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    public static func folderName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty || name == "/" ? path : name
    }

    /// The projects a spoken name could mean, best first. "td native shell",
    /// "TD-Native-Shell" and "native shell" all find `td-native-shell`.
    public static func match(_ spoken: String, in projects: [IntentProject]) -> [IntentProject] {
        let wanted = normalized(spoken)
        guard !wanted.isEmpty else { return projects }
        let wantedWords = Set(wanted.split(separator: " "))
        let compactWanted = wanted.replacingOccurrences(of: " ", with: "")
        var scored: [(IntentProject, Int)] = []
        for project in projects {
            let name = normalized(project.name)
            let compactName = name.replacingOccurrences(of: " ", with: "")
            let folder = normalized(folderName(project.path))
            var score = 0
            if name == wanted || folder == wanted || compactName == compactWanted { score = 100 }
            else if name.hasPrefix(wanted) || compactName.hasPrefix(compactWanted) { score = 80 }
            else if name.contains(wanted) || compactName.contains(compactWanted) { score = 60 }
            else {
                let words = Set(name.split(separator: " ") + folder.split(separator: " "))
                let shared = wantedWords.intersection(words).count
                if shared > 0 { score = 20 + 30 * shared / max(1, wantedWords.count) }
            }
            if score > 0 { scored.append((project, score)) }
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.lastOpenedAt > $1.0.lastOpenedAt }.map(\.0)
    }

    /// Lower-case, accents folded, everything but letters and digits as single spaces.
    public static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let spaced = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : " " }
        return IntentSpeech.collapse(String(spaced))
    }

    /// `/Users/me/code/x` → `~/code/x`, for a subtitle.
    public static func displayPath(_ path: String, home: String) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }

    /// The sidebar's project headings: path → title (only real folders).
    public static func headings(from sidebar: SidebarState?) -> [String: String] {
        var out: [String: String] = [:]
        for project in sidebar?.projects ?? [] where project.id.hasPrefix("/") {
            out[project.id] = project.title
        }
        return out
    }
}

/// The agents a session can be started with — every one Terminal Deck offers
/// (src/shared/types.ts `BuiltinProviderId`), never one alone.
public enum IntentAgent: String, CaseIterable, Sendable {
    case claude, codex, gemini, shell

    /// The engine's provider id (`session:create`'s `provider`).
    public var providerId: String { rawValue }

    public var spokenName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .gemini: "Gemini CLI"
        case .shell: "a plain shell"
        }
    }

    /// What someone might say for it.
    public var synonyms: [String] {
        switch self {
        case .claude: ["claude", "claude code", "anthropic"]
        case .codex: ["codex", "openai", "open ai", "chatgpt", "gpt"]
        case .gemini: ["gemini", "gemini cli", "google"]
        case .shell: ["shell", "plain shell", "terminal", "zsh", "bash"]
        }
    }

    public static func parse(_ text: String) -> IntentAgent? {
        let wanted = IntentProjects.normalized(text)
        guard !wanted.isEmpty else { return nil }
        return allCases.first { $0.rawValue == wanted || $0.synonyms.contains(wanted) }
            ?? allCases.first { agent in agent.synonyms.contains { wanted.contains($0) } }
    }

    public static func fromProvider(_ id: String?) -> IntentAgent? {
        id.flatMap { IntentAgent(rawValue: $0) }
    }
}

/// The phrases Siri listens for, one list per intent — the same strings the
/// app's `TerminalDeckShortcuts` declares (App Shortcuts need them as literals
/// there; this copy is what the tests and `build-app.sh` check them against).
/// `${applicationName}` is the app's name, and every phrase must carry it.
public enum IntentPhrases {
    public static let applicationName = "${applicationName}"

    public static let askHoot = [
        "Ask ${applicationName}",
        "Ask Hoot in ${applicationName}",
        "Ask ${applicationName} a question",
        "Ask ${applicationName} something",
    ]
    public static let whatNeedsMe = [
        "What needs me in ${applicationName}",
        "What needs my attention in ${applicationName}",
        "What's waiting for me in ${applicationName}",
        "Check ${applicationName}",
    ]
    public static let addTask = [
        "Add a task in ${applicationName}",
        "Add a task to ${applicationName}",
        "New ${applicationName} task",
    ]
    public static let startSession = [
        "Start a session in ${project} with ${applicationName}",
        "Start a ${applicationName} session in ${project}",
        "Start a ${applicationName} session",
    ]
    public static let openProject = [
        "Open ${target} in ${applicationName}",
        "Show ${target} in ${applicationName}",
    ]
    public static let openApp = [
        "Show ${applicationName}",
        "Bring up ${applicationName}",
    ]
    public static let goalStatus = [
        "How is ${goal} going in ${applicationName}",
        "Goal status in ${applicationName}",
        "Check my goal in ${applicationName}",
    ]

    /// Intent type name → phrases, as the metadata names the intents.
    public static let byIntent: [String: [String]] = [
        "AskHootIntent": askHoot,
        "WhatNeedsMeIntent": whatNeedsMe,
        "AddTaskIntent": addTask,
        "StartSessionIntent": startSession,
        "OpenProjectIntent": openProject,
        "OpenTerminalDeckIntent": openApp,
        "GoalStatusIntent": goalStatus,
    ]

    /// The parameters a phrase may name: entities and enums only (Siri cannot
    /// fill free text from a phrase).
    public static let phraseParameters: Set<String> = ["project", "target", "goal"]

    /// `${name}` tokens in a phrase.
    public static func tokens(in phrase: String) -> [String] {
        var out: [String] = []
        var rest = Substring(phrase)
        while let open = rest.range(of: "${"), let close = rest[open.upperBound...].firstIndex(of: "}") {
            out.append(String(rest[open.upperBound..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return out
    }
}
