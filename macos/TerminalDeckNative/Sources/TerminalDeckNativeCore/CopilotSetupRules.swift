import Foundation

// Hoot's setup flow and its permission question (lane B), as rules a test can ask:
//   - renderer/copilot/copilot-setup-model.ts — the four steps, their titles and buttons;
//   - renderer/copilot/CopilotSetup.tsx — the words on each step, the account list;
//   - shared/copilot-identity.ts — writing the "## Who you are" block (R's
//     `CopilotIdentity.read` in CopilotSettingsModel.swift reads it back);
//   - renderer/copilot/consent-model.ts — the countdown and the queue line.

// MARK: - The steps

public enum CopilotSetupStep: String, CaseIterable, Sendable {
    case name, you, folder, account

    /// `STEP_TITLE`.
    public var title: String {
        switch self {
        case .name: return "What should it be called?"
        case .you: return "What should it call you?"
        case .folder: return "Where should it work?"
        case .account: return "Which account should it run as?"
        }
    }

    public var index: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public var next: CopilotSetupStep { Self.allCases[min(index + 1, Self.allCases.count - 1)] }
    public var previous: CopilotSetupStep { Self.allCases[max(index - 1, 0)] }
    public var isLast: Bool { index == Self.allCases.count - 1 }
}

public enum CopilotSetupWords {
    public static func title(_ assistant: String = CopilotWords.assistant) -> String { "Set up \(assistant)" }
    public static let nameSays = "You will talk to it every day, so it is worth a name."
    public static let nameLabel = "Its name"
    public static let youSays = "It goes into its own instructions, so it reads it before it says a word."
    public static let callLabel = "It calls you"
    public static let callPlaceholder = "your name"
    public static let addressLabel = "How you want to be spoken to"
    public static let optional = "optional"
    public static let addressPlaceholder = "short answers, no preamble"
    public static let folderSays = "Point it at a folder you already keep an assistant in and it picks up whatever is there."
    public static let chooseFolder = "Choose a folder…"
    public static let useAppFolder = "Use this app’s folder"
    public static let accountSays = "It runs as one of your accounts. Leave this and it uses whatever your defaults already resolve to."
    public static let accountNote =
        "\(CopilotWords.assistant) has no login of its own — it runs as one of your accounts, " +
        "exactly like any other session, and choosing one here pins it to " +
        "\(CopilotWords.assistant)’s folder. That pin is the same one the New-session dialog " +
        "sets, so it takes effect the next time \(CopilotWords.assistant) starts and can be " +
        "changed later under Settings → Accounts."
    public static let readingAccounts = "Reading your accounts…"
    public static let noAccounts = "No accounts to choose from yet. Settings → Accounts is where they are added, and \(CopilotWords.assistant) will use your own install until then."
    public static let leaveToDefaults = "Leave it to my defaults"
    public static let saving = "Saving…"
    public static let back = "Back"

    /// `RENAME_TAKES_A_RESTART`.
    public static let renameTakesARestart =
        "It is running now. A session is handed its instructions when it starts, so this applies the " +
        "next time it starts — nothing about the conversation on screen changes."

    public static let pickFailed = "The folder could not be changed."
    public static let clearFailed = "That did not work."
    public static let unreadable = "Its instructions could not be read, so nothing was saved. Settings → \(CopilotWords.assistant) has the file itself."
    public static let unsaved = "Its instructions could not be saved."
    public static let unpinned = "Its name is saved. The account could not be pinned to its folder — set it in Settings → Accounts."
    public static let failed = "Nothing was saved — that did not work."

    /// The path line's tag: whose folder it is.
    public static func whose(_ folder: CopilotFolder?) -> String { folder?.isDefault == false ? "yours" : "this app’s" }

    /// `startLabel`.
    public static func startLabel(_ identity: CopilotIdentity) -> String { "Start \(identity.name ?? CopilotWords.assistant)" }

    /// `advanceLabel`: Skip until there is something to keep; the last one acts.
    public static func advanceLabel(_ step: CopilotSetupStep, answered: Bool, identity: CopilotIdentity, running: Bool) -> String {
        if step.isLast { return running ? "Save" : startLabel(identity) }
        return answered ? "Continue" : "Skip"
    }
}

// MARK: - The answers

public enum CopilotSetupRules {
    public static let maxName = 32
    public static let maxCallThem = 32
    public static let maxAddressNote = 160

    /// `cleanIdentity`: every answer cleaned at once.
    public static func identity(name: String, callThem: String, addressNote: String) -> CopilotIdentity {
        CopilotIdentity(name: CopilotIdentity.clean(name, maxName),
                        callThem: CopilotIdentity.clean(callThem, maxCallThem),
                        addressNote: CopilotIdentity.clean(addressNote, maxAddressNote))
    }

    /// Whether this step has something to keep (what turns Skip into Continue).
    public static func answered(_ step: CopilotSetupStep, identity: CopilotIdentity, folder: CopilotFolder?, accountChosen: Bool) -> Bool {
        switch step {
        case .name: return identity.name != nil
        case .you: return identity.callThem != nil || identity.addressNote != nil
        case .folder: return folder.map { !$0.isDefault } ?? false
        case .account: return accountChosen
        }
    }

    /// Only Claude logins (and ones that do not say) can run Hoot.
    public static func accounts(_ snapshot: CodingAIAccountsSnapshot) -> [CodingAIAccount] {
        snapshot.accounts.filter { $0.provider == "claude" || $0.provider == nil }
    }

    /// `projectDefaultFor(folder) ?? defaultId`.
    public static func currentAccountId(_ snapshot: CodingAIAccountsSnapshot, home: String?) -> String? {
        if let home, !home.isEmpty {
            if let exact = snapshot.projectDefaults[home] { return exact }
            let wanted = NewSessionPaths.normalize(home)
            if !wanted.isEmpty, let hit = snapshot.projectDefaults.first(where: { NewSessionPaths.normalize($0.key) == wanted }) {
                return hit.value
            }
        }
        return snapshot.defaultId
    }

    /// The quiet line under an account: "your own install" (only when the name did not
    /// already say it) and "in use now".
    public static func note(_ account: CodingAIAccount, signIn: CodingAISignIn?, currentId: String?) -> String {
        var parts: [String] = []
        if account.system, CodingAIAccountLabels.accountLabel(signIn) != nil { parts.append("your own install") }
        if account.id == currentId || (currentId == nil && account.system) { parts.append("in use now") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Writing the block (withCopilotIdentity)

extension CopilotIdentity {
    /// `copilotIdentityBlock`: what is written; every branch says something true.
    public static func block(_ raw: CopilotIdentity) -> String {
        let identity = CopilotIdentity(name: raw.name.flatMap { clean($0, CopilotSetupRules.maxName) },
                                       callThem: raw.callThem.flatMap { clean($0, CopilotSetupRules.maxCallThem) },
                                       addressNote: raw.addressNote.flatMap { clean($0, CopilotSetupRules.maxAddressNote) })
        var lines = [heading, ""]
        if let name = identity.name {
            lines += ["Your name is **\(name)**. This app reads it from this line — change the",
                      "name here and it changes in the sidebar, on the tab and in Settings."]
        } else {
            lines += ["They have not given you a name of their own, so you go by the one this app",
                      "gives you: **\(CopilotWords.assistant)**. Do not pick a different name for yourself; if",
                      "they give you one, it replaces this paragraph."]
        }
        lines.append("")
        if let callThem = identity.callThem {
            lines.append("Call them **\(callThem)**.")
        } else {
            lines += ["They have not told you what to call them. If the folder you work in says,",
                      "follow that; otherwise ask, rather than guessing a name out of what you",
                      "find in their files."]
        }
        if let note = identity.addressNote { lines += ["", "Address them like this: \(note)"] }
        lines += ["", end]
        return lines.joined(separator: "\n") + "\n"
    }

    /// `withCopilotIdentity`: the file with this block in it — the old one replaced where
    /// it stands, else a first one under the title. Everything else is kept byte for byte.
    public static func writing(_ identity: CopilotIdentity, into instructions: String) -> String {
        let block = block(identity)
        let lines = instructions.components(separatedBy: "\n")
        let blank: (String) -> Bool = { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var head: ArraySlice<String>
        var tail: ArraySlice<String>
        if let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == heading }) {
            var stop = lines.count
            var at = start + 1
            while at < lines.count {
                if lines[at].trimmingCharacters(in: .whitespacesAndNewlines) == end { stop = at + 1; break }
                if lines[at].range(of: #"^#{1,6}\s"#, options: .regularExpression) != nil { stop = at; break }
                at += 1
            }
            head = lines[..<start]
            tail = lines[stop...]
        } else {
            let titled = (lines.first ?? "").range(of: #"^#\s+\S"#, options: .regularExpression) != nil
            head = lines[..<(titled ? 1 : 0)]
            tail = lines[(titled ? 1 : 0)...]
        }
        while let last = head.last, blank(last) { head = head.dropLast() }
        while let first = tail.first, blank(first) { tail = tail.dropFirst() }
        return (head.isEmpty ? "" : head.joined(separator: "\n") + "\n\n")
            + block
            + (tail.isEmpty ? "" : "\n" + tail.joined(separator: "\n"))
    }
}

// MARK: - The permission question (consent-model.ts)

public enum CopilotConsentWords {
    public static let refuse = "Refuse"
    public static let allow = "Allow once"

    /// `secondsLeft`: whole seconds to the deadline, rounded up, never below zero.
    public static func secondsLeft(expiresAt: Double, now: Double) -> Int {
        max(0, Int(((expiresAt - now) / 1000).rounded(.up)))
    }

    /// `timeoutSentence`.
    public static func timeout(_ seconds: Int) -> String {
        seconds <= 0 ? "Time is up — this is being refused." : "Refused automatically in \(seconds)s if nothing is answered."
    }

    /// The last ten seconds turn the line critical.
    public static func urgent(_ seconds: Int) -> Bool { seconds <= 10 }

    /// The queue line, or nil with nothing behind this one.
    public static func waiting(_ count: Int) -> String? {
        if count <= 0 { return nil }
        return count == 1 ? "One more question is waiting behind this one." : "\(count) more questions are waiting behind this one."
    }
}

/// What the page hands over for the question on screen. The page's own readers
/// (`toolHeading`, `askerSentence`, `argRows`) have already made the words, so the
/// rows keep the order the agent sent them in.
public struct CopilotConsentRequest: Decodable, Equatable, Sendable {
    public struct Row: Decodable, Equatable, Sendable {
        public let name: String
        public let value: String
    }
    public let id: String
    public let heading: String
    public let asker: String
    public let summary: String
    public let rows: [Row]
    public let tier: String
    public let tool: String
    public let expiresAt: Double
    public let waiting: Int
}

// MARK: - The rail row (CopilotEntry.tsx, copilot-model.ts `entryTooltip`)

public enum CopilotEntryWords {
    /// `COPILOT_BLURB`: the row's hover words before anything is known.
    public static let blurb = "Your assistant for this deck — the sessions, the diffs, the prompts."

    /// `entryTooltip`: what the state is, in a sentence.
    public static func tooltip(_ stage: HootStage, problem: String?) -> String {
        switch stage {
        case .stopped: return problem ?? "Not running. Open it to start it."
        case .starting: return "Starting…"
        case .checking: return "Running. Checking whether it is signed in…"
        case .firstRun: return "Running — the account it runs as is signed out. Sign in on its terminal."
        case .unverified: return "Running. This window could not check whether it is signed in."
        case .ready: return "Running."
        }
    }

    /// The row's whole hover line: where the folded panel is, the blurb, or the state.
    public static func help(name: String, stage: HootStage?, problem: String?, parked: Bool) -> String {
        if parked { return "\(name)’s panel is folded in here — click to bring it back" }
        guard let stage else { return blurb }
        return "\(name) — \(tooltip(stage, problem: problem))"
    }
}
