import Foundation
import TerminalDeckNativeCore

/// Pure task-brief.ts composition. Goals are root-first; the task's surrounding
/// context is capped independently so old notes do not become a transcript.
public enum BackendTaskBriefComposition {
    public static func goals(_ chain: [NativeRPCValue]) -> String {
        guard !chain.isEmpty else { return "" }
        let lines = chain.reversed().enumerated().map { depth, goal in
            let about = goal["description"].string ?? ""
            return String(repeating: "  ", count: depth) + "- **\(oneLine(goal["title"].string ?? "", maximum: 200))** (\(goal["status"].string ?? "unknown"))" + (about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : " — " + oneLine(about, maximum: 600))
        }
        return "\n\n## The goal this serves\n\n" + "This task is part of the goal\(chain.count > 1 ? "s below, from the broadest down to the one it serves directly" : " below"). " +
            "Keep the work pointed at it; say so in your summary if something in the task works against it.\n\n" + lines.joined(separator: "\n")
    }
    /// task-brief.ts retrySection: a try after one that did not finish.
    public static func retry(_ task: BackendTaskRecord) -> String {
        let retry = task.value["retry"]; guard !retry.isNullish else { return "" }
        let note = (retry["note"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return "\n\n## Tried again\n\nThis task was started before and did not finish (try \(Int((retry["count"].number ?? 0)) + 1))." + (note.isEmpty ? "" : "\n\n" + oneLine(note, maximum: 2_000))
    }
    /// agent-briefing.ts stackText: the owner's settings for this agent, as the brief tells them.
    public static func stack(_ agent: NativeRPCValue) -> String {
        typealias C = BackendSharedAgentCapabilities
        let provider = agent["provider"].string, list: (String) -> [String] = { agent[$0].elements?.compactMap(\.string) ?? [] }
        let says: (C.Setting) -> Bool = { C.capabilityFor(provider, setting: $0).support != .unsupported }
        var parts: [String] = []
        if let text = agent["instructions"].string, says(.instructions) { parts.append(text) }
        if says(.toolAdvice) {
            if !list("toolsPreferred").isEmpty { parts.append("Prefer these tools: \(list("toolsPreferred").joined(separator: ", ")).") }
            if !list("toolsAvoided").isEmpty { parts.append("Do not use these tools: \(list("toolsAvoided").joined(separator: ", ")).") }
            if !list("toolsPreferred").isEmpty || !list("toolsAvoided").isEmpty { parts.append("These tool choices are what the owner asked for; your own permission settings still apply.") }
        }
        let skillsOff = agent["skillsOff"].bool == true
        if !list("skills").isEmpty, !skillsOff, says(.skillSelection) {
            parts.append("Use these skills when they fit: \(list("skills").joined(separator: ", ")). That is a request, not a limit: other skills stay available.")
            // CONNECT-SKILLS: a built-in skill is read from the app (the project's own copy, when it has one, wins).
            if let where_ = BackendBuiltInSkills.briefLine(list("skills"), projectFolder: agent["defaultProject"].string) { parts.append(where_) }
        }
        if !list("blockedTools").isEmpty { parts.append("These tools are switched off for you: \(list("blockedTools").joined(separator: ", ")).") }
        if skillsOff { parts.append("Skills are switched off for you.") }
        return parts.isEmpty ? "" : "\n\n## How you work (\(agent["name"].string ?? ""), \(agent["role"].string ?? ""))\n\n" + parts.joined(separator: "\n\n")
    }
    public static func context(_ task: BackendTaskRecord, all: [BackendTaskRecord], names: [String: String]) -> String {
        var parts: [String] = []
        let detail = task.value["detail"], subtasks = (detail["subtasks"].elements ?? []).sorted { ($0["sortOrder"].number ?? 0) < ($1["sortOrder"].number ?? 0) }.prefix(20)
        if !subtasks.isEmpty { parts.append("### Subtasks\n\n" + subtasks.map { "- [\($0["done"].bool == true ? "x" : " ")] \(oneLine($0["title"].string ?? ""))" }.joined(separator: "\n")) }
        let lookup = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) }), word = ["blocked_by": "Waits for", "blocks": "Needed by", "linked": "Related to"]
        var links = detail["dependencies"].elements ?? [], seen = Set<String>(), lines: [String] = []
        for other in all where other.id != task.id { for dep in other.value["detail"]["dependencies"].elements ?? [] where dep["otherTaskId"].string == task.id { let kind = dep["kind"].string ?? "linked"; links.append(dep.setting("kind", .string(kind == "blocks" ? "blocked_by" : kind == "blocked_by" ? "blocks" : "linked")).setting("otherTaskId", .string(other.id))) } }
        for link in links { guard lines.count < 12, let otherID = link["otherTaskId"].string, let other = lookup[otherID], let kind = link["kind"].string, seen.insert(kind + ":" + otherID).inserted else { continue }; lines.append("- \(word[kind] ?? kind): \(oneLine(other.value["title"].string ?? "", maximum: 200)) (\(other.value["crmStatus"].string == "Done" ? "done" : other.value["crmStatus"].string ?? "open"))") }
        if !lines.isEmpty { parts.append("### Linked tasks\n\n" + lines.joined(separator: "\n")) }
        let comments = (detail["comments"].elements ?? []).sorted { ($0["at"].number ?? 0) < ($1["at"].number ?? 0) }.suffix(8)
        if !comments.isEmpty { parts.append("### Latest comments\n\n" + comments.map { row in let who = row["authorUserId"].string ?? "unknown"; return "- \(names[who] ?? who): \(oneLine(row["body"].string ?? ""))" }.joined(separator: "\n")) }
        let notes = (task.value["notes"].elements ?? []).filter { ["progress", "blocker", "question", "completion", "reply"].contains($0["kind"].string ?? "") }.suffix(8)
        if !notes.isEmpty { parts.append("### Latest notes\n\n" + notes.map { row in let who = row["by"].string ?? "unknown"; return "- \(names[who] ?? who) (\(row["kind"].string ?? "unknown")): \(oneLine(row["text"].string ?? ""))" }.joined(separator: "\n")) }
        guard !parts.isEmpty else { return "" }; let text = parts.joined(separator: "\n\n")
        return "\n\n## Already on this task\n\nWhat people and agents have written and done on it so far, newest last.\n\n" + (text.utf16.count > 6_000 ? utf16Prefix(text, 6_000) + "\n…(the rest is on the task)" : text)
    }
    private static func oneLine(_ raw: String, maximum: Int = 400) -> String {
        let text = raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.utf16.count <= maximum ? text : utf16Prefix(text, maximum) + "…"
    }
    /// JavaScript `slice(0, n)` counts UTF-16 units.
    static func utf16Prefix(_ text: String, _ count: Int) -> String { String(decoding: Array(text.utf16.prefix(count)), as: UTF16.self) }
}

// MARK: One wording for every assignee: Hoot, a lead, any agent (FORK-TASKS, 11 Oct)
//
// Asad gave Hoot a task called "test" with the text "Hi" and Hoot was told: `CRM task local:2de… ("test")
// is assigned to you. It is CRM task 2de…, in /Users/x. Hi Hand parts to your agents…`. The rules now:
// the title once; the id once, on a line of its own (the tools need it whole); the task's own words as a
// quoted block, so they can never run into the instructions; the project by its name; then what the
// assignee may do. A task with no real work in it is called that, plainly.
extension BackendTaskBriefComposition {
    /// Someone's own words, set apart: one "> " per line.
    public static func quoted(_ raw: String, maximum: Int = 6_000) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "> (nothing is written here)" }
        let cut = text.utf16.count > maximum ? utf16Prefix(text, maximum) + "…" : text
        return cut.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
    }

    /// Words that ask for nothing: a greeting, a placeholder, the task's own furniture, and the few words said
    /// beside a greeting ("Hello there", "Hi Hoot"). Verbs and pronouns are not here (U57, 18 Oct): "Check the
    /// tests", "Test it again please" and "Ping me" are short but real tasks.
    private static let fillerWords: Set<String> = ["hi", "hello", "hey", "yo", "salam", "aoa", "test", "testing",
        "ok", "okay", "asdf", "foo", "bar", "abc", "todo", "task", "new", "untitled", "a", "an", "there", "you", "hoot"]
    /// True when neither the title nor the text asks for anything (the "test" / "Hi" task): a short title,
    /// and every word of it and of the text a greeting or a placeholder.
    public static func hasNoRealWork(title: String, body: String) -> Bool {
        func words(_ text: String) -> [String] { text.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty } }
        let titleWords = words(title)
        guard titleWords.count <= 4 else { return false }
        return !(titleWords + words(body)).contains { !fillerWords.contains($0) }
    }
    static func noRealWorkLine(body: String) -> String {
        let said = oneLine(body, maximum: 80)
        return "This task has no real work in it: " + (said.isEmpty ? "nothing is written in it beyond its title." : "it only says “\(said)”.")
            + " Say that in one short answer and ask what is wanted. Do not make up work."
    }

    /// "Project: Shop (folder /Users/x/Projects/shop)"; a task outside every project names its folder.
    public static func projectLine(name: String?, folder: String) -> String {
        let named = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if named.isEmpty { return folder.isEmpty ? "Project: none" : "Project: none, it works in the folder \(folder)" }
        return folder.isEmpty ? "Project: \(named)" : "Project: \(named) (folder \(folder))"
    }

    /// Who gave the task or wrote the comment, as the brief says it.
    public static func person(_ id: String?, names: [String: String] = [:]) -> String {
        guard let id, !id.isEmpty, id != "me" else { return "the owner" }
        if id == "hoot" { return "Hoot" }
        if let outside = BackendTaskActor.outsideActorName(id) { return outside }
        return names[id] ?? id
    }

    /// The top of every brief: title once, id once, project by name, who gave it.
    static func facts(taskID: String, project: String, givenBy: String) -> String {
        "Task id: \(taskID)\n\(project)\nGiven by: \(givenBy)"
    }

    /// What Hoot is told when a task is given to it.
    public static func hootAssigned(title: String, taskID: String, body: String, project: String, givenBy: String,
                                    agents: [String], goals: String = "", local: Bool) -> String {
        var text = "You have been given a task: \"\(oneLine(title, maximum: 200))\"\n\n" + facts(taskID: taskID, project: project, givenBy: givenBy)
        text += "\n\nWhat the task says:\n\n" + quoted(body)
        if hasNoRealWork(title: title, body: body) { text += "\n\n" + noRealWorkLine(body: body) }
        text += goals
        text += "\n\nWhat you may do:\n"
        text += "- " + answerHere + "\n"
        text += "- " + progressHere + "\n"
        text += agents.isEmpty ? "- Hand parts to agents with tasks_delegate once some are set up: none are yet.\n"
                               : "- Hand parts to your agents with tasks_delegate: \(agents.joined(separator: ", ")).\n"
        text += "- When it is done and right, call tasks_verify."
        if !local { text += "\n\nTerminal Deck sends your comments and your verdict to the CRM this task came from." }
        return text
    }

    /// What Hoot is told when someone writes on a task it holds.
    public static func hootComment(title: String, taskID: String, text: String, by: String?) -> String {
        let lead = by.map { "\($0.prefix(1).uppercased() + $0.dropFirst()) wrote on your task" } ?? "A reply came in on your task"
        return "\(lead) \"\(oneLine(title, maximum: 200))\":\n\n\(quoted(text))\n\nTask id: \(taskID)\n" + answerHere
    }

    /// Something the app tells Hoot about a task it coordinates (an agent finished, a worker stalled).
    public static func hootNotice(_ what: String, taskID: String, next: String) -> String {
        "\(what)\n\nTask id: \(taskID)\n\n\(next)\n" + noticeHere
    }

    // How Hoot answers. In a task turn its answer is posted on the task for it. Where Hoot can only be told
    // in its chat (a build without task turns), it has to post the answer itself, or the owner would have to
    // go and look for it in the chat.
    static let answerHere = "Answer here. Your answer is posted on the task as your comment; it does not go into your chat with the owner."
    static let progressHere = "Post progress on longer work with tasks_comment."
    static let noticeHere = "What you answer here is posted on that task as your comment."
    static let answerInChat = "Answer ON THE TASK with tasks_comment (your answer, a question or progress), not in this chat: the owner reads the task."
    static let noticeInChat = "Post what you find on that task with tasks_comment, not in this chat."
    /// The same brief for a Hoot that is told in its chat instead of in a task turn.
    public static func chatWording(_ brief: String) -> String {
        brief.replacingOccurrences(of: "- " + answerHere + "\n- " + progressHere, with: "- " + answerInChat)
            .replacingOccurrences(of: answerHere, with: answerInChat).replacingOccurrences(of: noticeHere, with: noticeInChat)
    }

    /// Whether this agent's session is given the task tools (only Claude Code is handed them today).
    public static func hasTaskTools(_ agent: NativeRPCValue) -> Bool {
        BackendSharedAgentCapabilities.capabilityFor(agent["claudeAgent"].string != nil ? "claude" : agent["provider"].string, setting: .mcpConfig).support != .unsupported
    }

    /// The top of a freshly started agent's brief.
    public static func agentHeader(title: String, taskID: String, project: String, givenBy: String, local: Bool, tools: Bool) -> String {
        var text = "# \(oneLine(title, maximum: 300))\n\n" + facts(taskID: taskID, project: project, givenBy: givenBy)
        text += "\n\nYou were given this task in Terminal Deck. Do the work, then end with a short summary of what you did and anything left. "
        text += "Your final answer is posted on the task as your comment" + (local ? "." : ", and reported to the CRM it came from.")
        text += tools ? "\nPost progress on longer work with tasks_comment, and hand a part to another agent with tasks_delegate. Both work on this task without asking the owner."
                      : "\nThis session has no task tools, so do not look for any: your final answer is what gets posted."
        return text
    }

    /// The task's own text in an agent's brief.
    public static func agentTask(title: String, body: String) -> String {
        "\n\n## The task\n\n" + quoted(body, maximum: 20_000) + (hasNoRealWork(title: title, body: body) ? "\n\n" + noRealWorkLine(body: body) : "")
    }

    /// A comment or reply typed into an agent's running session (one line: the terminal takes no blocks).
    public static func agentLine(title: String, text: String, by: String?, tools: Bool) -> String {
        let said = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        let lead = by.map { "\($0.prefix(1).uppercased() + $0.dropFirst()) wrote on your task" } ?? "A reply on your task"
        return "\(lead) \"\(oneLine(title, maximum: 120))\": “\(said)” (End with your answer: it is posted on the task for you."
            + (tools ? " tasks_comment is for progress while you work.)" : ")")
    }

    /// A comment or reply that restarts an agent whose session had closed.
    public static func agentReply(title: String, taskID: String, text: String, by: String?) -> String {
        let lead = by.map { "\($0.prefix(1).uppercased() + $0.dropFirst()) wrote on your task" } ?? "A reply came in on your task"
        return "\(lead) \"\(oneLine(title, maximum: 200))\":\n\n\(quoted(text))\n\nTask id: \(taskID)\nEnd with your answer: it is posted on the task for you."
    }
}
