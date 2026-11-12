import SwiftUI
import TerminalDeckNativeCore

/// What the chat draws, in order: single rows (the person's messages, Hoot's in-between words, errors, routing cards,
/// handoff lines), and for each job ONE reply: Hoot's avatar, the job's steps (a live list while it works, one folded
/// line after) and the answer under them.
enum HootChatItem: Identifiable {
    case row(HootChatRow)
    /// A job's answer with its steps above it, beside one Hoot avatar. `answer` nil: no answer yet (Hoot is thinking,
    /// or stopped before it answered). `key`: the job's first row, so the reply keeps its place and identity from the
    /// moment the message is sent until the answer is complete (Asad, 12 Oct: no jump when the first words arrive).
    case reply(key: String, answer: HootChatRow?, steps: [HootChatRow], open: Bool)
    var id: String {
        switch self { case .row(let row): row.id; case .reply(let key, _, _, _): "reply:" + key }
    }
    static func isStep(_ row: HootChatRow) -> Bool {
        (row.kind == .toolCall || row.kind == .toolResult) && row.value["routing"].isNullish && !HootHandoffLine.matches(row)
    }
    static func isAnswer(_ row: HootChatRow) -> Bool {
        (row.kind == .message || row.kind == .textDelta) && row.value["background"].fields == nil && row.value["routing"].isNullish
    }
    /// HOOT-FLOW (Asad, 12 Oct): one job = what Hoot did between one message and the next. All its steps fold into the
    /// reply, which stands where the answer is (the last words after the last step); Hoot's own words in between stay
    /// where they were. `open`: the last job (the one Hoot may still be working on).
    static func items(_ rows: [HootChatRow], firstJobKey: String? = nil) -> [HootChatItem] {
        // A job starts at the person's message or at a background task's line.
        var jobs: [[HootChatRow]] = [], current: [HootChatRow] = []
        for row in rows {
            if row.kind == .user || row.value["background"].fields != nil, !current.isEmpty { jobs.append(current); current = [] }
            current.append(row)
        }
        if !current.isEmpty { jobs.append(current) }
        var items: [HootChatItem] = []
        for (index, job) in jobs.enumerated() {
            let steps = job.filter(isStep), answers = job.filter(isAnswer)
            guard let place = job.firstIndex(where: { isStep($0) || isAnswer($0) }) else { items += job.map(HootChatItem.row); continue }
            var answer = answers.last
            if var combined = answer {
                combined.value = combined.value.setting("text", .string(answers.compactMap { $0.value["text"].string }.joined(separator: "\n\n")))
                    .setting("combinedMessageIDs", .array(answers.map { .string($0.id) }))
                answer = combined
            }
            let reply = HootChatItem.reply(key: index == 0 ? (firstJobKey ?? job[0].id) : job[0].id, answer: answer, steps: steps, open: index == jobs.count - 1)
            for (position, row) in job.enumerated() {
                if position == place { items.append(reply) }
                else if !isStep(row), !isAnswer(row) { items.append(.row(row)) }
            }
        }
        return items
    }
    /// Paging may cut through a long tool run. Keep the original job identity so its fold and
    /// latest-line measurement survive both streaming and loading an earlier page.
    static func page(_ rows: [HootChatRow], count: Int) -> [HootChatItem] {
        let start = max(0, rows.count - max(0, count))
        guard start < rows.count else { return [] }
        var firstJobKey: String?
        for row in rows.prefix(start + 1) {
            if firstJobKey == nil || row.kind == .user || row.value["background"].fields != nil { firstJobKey = row.id }
        }
        return items(Array(rows.suffix(from: start)), firstJobKey: firstJobKey)
    }
    /// The moment a message is sent: Hoot's reply is already there, thinking (Asad, 12 Oct: "very very instant").
    static func thinking(_ items: [HootChatItem], live: Bool) -> [HootChatItem] {
        guard live else { return items }
        switch items.last {
        case .reply: return items
        case .row(let row) where row.kind == .user: return items + [.reply(key: row.id, answer: nil, steps: [], open: true)]
        case nil: return [.reply(key: "pending", answer: nil, steps: [], open: true)]
        default: return items
        }
    }
}

enum HootStep {
    enum Kind { case command, edit, read, search, web, memory, plumbing, tool }
    /// The tool the row really ran (a call through tools_run is the tool it named).
    static func name(_ row: HootChatRow) -> String {
        let raw = row.value["name"].string ?? ""
        let bare = HootFlow.bare(raw)
        if bare == "tools_run", let inner = row.value["input"]["name"].string, !inner.isEmpty { return HootFlow.bare(inner) }
        return raw
    }
    static func kind(_ row: HootChatRow) -> Kind {
        let name = name(row), lower = name.lowercased()
        if ["toolsearch", "todowrite", "todoread", "exitplanmode", "enterplanmode", "task", "agent", "skill"].contains(lower) || row.kind == .toolResult { return .plumbing }
        // Looking up which app tools there are, and the job-flow reports themselves (they are rows of their own).
        if ["tools_describe", "tools_list"].contains(HootFlow.bare(lower)) || HootFlow.isReport(row) { return .plumbing }
        if ["bash", "shell", "exec_command", "run_shell_command", "local_shell", "bashoutput", "killshell"].contains(lower) { return .command }
        if ["edit", "multiedit", "write", "notebookedit", "apply_patch", "replace", "write_file"].contains(lower) { return .edit }
        if ["read", "read_file", "read_many_files", "notebookread", "view"].contains(lower) {
            return (path(row) ?? "").contains("/memory/") ? .memory : .read
        }
        if ["grep", "glob", "ls", "search_file_content", "list_directory", "glob_files"].contains(lower) { return .search }
        if ["webfetch", "websearch", "web_fetch", "google_web_search", "web_search"].contains(lower) { return .web }
        return .tool
    }
    static func path(_ row: HootChatRow) -> String? {
        let input = row.value["input"]
        return input["file_path"].string ?? input["path"].string ?? input["notebook_path"].string ?? input["absolute_path"].string
    }
    static func file(_ row: HootChatRow) -> String { (path(row).map { URL(fileURLWithPath: $0).lastPathComponent }) ?? "a file" }
    /// Lines added and removed by an edit (+N −N).
    static func diff(_ row: HootChatRow) -> (plus: Int, minus: Int) {
        let input = row.value["input"]
        func lines(_ text: String?) -> Int { guard let text, !text.isEmpty else { return 0 }; return text.split(separator: "\n", omittingEmptySubsequences: false).count }
        if let edits = input["edits"].elements {
            return edits.reduce((0, 0)) { ($0.0 + lines($1["new_string"].string), $0.1 + lines($1["old_string"].string)) }
        }
        if let content = input["content"].string { return (lines(content), 0) }
        return (lines(input["new_string"].string), lines(input["old_string"].string))
    }
    /// The app's own tools in plain words (done, while running). Asad: "Read the Tasks list", not raw names.
    static let known: [String: (String, String)] = [
        "tasks_list": ("Read the Tasks list", "Reading the Tasks list"), "tasks_progress": ("Checked how the tasks are going", "Checking how the tasks are going"),
        "tasks_get": ("Read a task", "Reading a task"), "tasks_plan": ("Planned the tasks", "Planning the tasks"),
        "tasks_goals": ("Set the goal", "Setting the goal"), "tasks_delegate": ("Gave a task to an agent", "Giving a task to an agent"),
        "tasks_reassign": ("Gave a task to another agent", "Giving a task to another agent"), "tasks_retry": ("Sent a task back to try again", "Sending a task back"),
        "tasks_review": ("Reviewed a task", "Reviewing a task"), "tasks_verify": ("Checked a task's proof", "Checking a task's proof"),
        "tasks_comment": ("Commented on a task", "Commenting on a task"), "tasks_local": ("Read the Tasks list", "Reading the Tasks list"),
        "tasks_local_change": ("Changed a task", "Changing a task"),
        "tasks_set_status": ("Changed a task's status", "Changing a task's status"), "tasks_agents": ("Looked at the agents", "Looking at the agents"),
        "sessions_list": ("Looked at the sessions", "Looking at the sessions"), "sessions_start": ("Started a session", "Starting a session"),
        "sessions_send": ("Sent a message to a session", "Sending a message to a session"), "sessions_transcript": ("Read a session's conversation", "Reading a session's conversation"),
        "sessions_screen": ("Looked at a session's screen", "Looking at a session's screen"), "sessions_get": ("Read a session", "Reading a session"),
        "sessions_wait": ("Waited for a session", "Waiting for a session"), "sessions_result": ("Read a session's result", "Reading a session's result"),
        "sessions_stop": ("Stopped a session", "Stopping a session"),
        "memory_search": ("Searched memory", "Searching memory"), "memory_card_read": ("Read its card", "Reading its card"),
        "memory_board_read": ("Read the board", "Reading the board"), "memory_diary_read": ("Read a moment in the diary", "Reading the diary"),
        "memory_note_add": ("Saved a note", "Saving a note"), "memory_topic_update": ("Updated where we are", "Updating where we are"),
        "playbook_read": ("Read the playbook", "Reading the playbook"), "knowledge_search": ("Searched the project's knowledge", "Searching the project's knowledge"),
        "knowledge_record": ("Recorded a decision", "Recording a decision"), "devices_screenshot": ("Took a phone screenshot", "Taking a phone screenshot"),
        "devices_open_app": ("Opened an app on a phone", "Opening an app on a phone"), "browser_open": ("Opened a web page", "Opening a web page"),
    ]
    /// An MCP tool's plain title: "mcp__deck-control__sessions_list" → "Looked at the sessions".
    static func toolTitle(_ name: String, live: Bool) -> String {
        let bare = HootFlow.bare(name)
        if let words = known[bare.lowercased()] { return live ? words.1 : words.0 }
        var words = bare.replacingOccurrences(of: "-", with: "_").split(separator: "_").map(String.init)
        guard !words.isEmpty else { return live ? "Using a tool" : "Used a tool" }
        let verbs: [String: (String, String)] = [
            "list": ("Listed", "Listing"), "get": ("Read", "Reading"), "read": ("Read", "Reading"), "start": ("Started", "Starting"),
            "send": ("Sent", "Sending"), "stop": ("Stopped", "Stopping"), "create": ("Created", "Creating"), "update": ("Updated", "Updating"),
            "delete": ("Deleted", "Deleting"), "search": ("Searched", "Searching"), "run": ("Ran", "Running"), "open": ("Opened", "Opening"),
            "set": ("Set", "Setting"), "tap": ("Tapped", "Tapping"), "type": ("Typed into", "Typing into"), "screenshot": ("Took a screenshot of", "Taking a screenshot of"),
            "comment": ("Commented on", "Commenting on"), "wait": ("Waited for", "Waiting for"), "find": ("Found", "Finding"), "record": ("Recorded", "Recording")]
        // The verb is usually last ("sessions_list") or first ("list_sessions").
        let verbIndex = words.lastIndex(where: { verbs[$0.lowercased()] != nil }) ?? words.firstIndex(where: { verbs[$0.lowercased()] != nil })
        guard let index = verbIndex, let verb = verbs[words[index].lowercased()] else {
            return (live ? "Using " : "Used ") + words.joined(separator: " ")
        }
        words.remove(at: index)
        let object = words.joined(separator: " ")
        return (live ? verb.1 : verb.0) + (object.isEmpty ? "" : " " + object)
    }
    /// One plain-language row.
    static func title(_ row: HootChatRow, live: Bool = false) -> String {
        let input = row.value["input"]
        switch kind(row) {
        case .command:
            if let description = input["description"].string, !description.isEmpty { return live ? description + "…" : description }
            return live ? "Running a command…" : "Ran a command"
        case .edit: return (live ? "Editing " : "Edited ") + file(row)
        case .read: return (live ? "Reading " : "Read ") + file(row)
        case .memory: return live ? "Recalling a memory…" : "Recalled a memory"
        case .search: return live ? "Searching files…" : "Searched files"
        case .web: return live ? "Looking on the web…" : "Looked on the web"
        case .plumbing: return live ? "Looking up tools…" : "Looked up tools"
        case .tool: return toolTitle(name(row), live: live) + (live ? "…" : "")
        }
    }
    /// The collapsed line: "Recalled a memory, ran 4 commands, edited postgres.md".
    static func summary(_ rows: [HootChatRow]) -> (text: String, plus: Int, minus: Int) {
        let visible = rows.filter { kind($0) != .plumbing }
        var parts: [String] = []
        func count(_ k: Kind) -> [HootChatRow] { visible.filter { kind($0) == k } }
        let memory = count(.memory), commands = count(.command), reads = count(.read), searches = count(.search),
            web = count(.web), tools = count(.tool), edits = count(.edit)
        if !memory.isEmpty { parts.append(memory.count == 1 ? "recalled a memory" : "recalled \(memory.count) memories") }
        if !commands.isEmpty { parts.append(commands.count == 1 ? "ran a command" : "ran \(commands.count) commands") }
        if !reads.isEmpty { parts.append(reads.count == 1 ? "read " + file(reads[0]) : "read \(reads.count) files") }
        if !searches.isEmpty { parts.append("searched files") }
        if !web.isEmpty { parts.append("looked on the web") }
        if !tools.isEmpty { parts.append(tools.count == 1 ? toolTitle(name(tools[0]), live: false).lowercased() : "used \(tools.count) tools") }
        var plus = 0, minus = 0
        if !edits.isEmpty {
            let files = Set(edits.map(file))
            parts.append(files.count == 1 ? "edited " + files.first! : "edited \(files.count) files")
            for edit in edits { let change = diff(edit); plus += change.plus; minus += change.minus }
        }
        if parts.isEmpty { parts = [visible.isEmpty && rows.contains(where: HootFlow.isReport) ? "rules and steps" : "looked up tools"] }
        let text = parts.joined(separator: ", ")
        return (text.prefix(1).uppercased() + text.dropFirst(), plus, minus)
    }
}

/// Decker, 8 Nov (D1, all four apps): a failed step is always its own card, never inside the fold; a failure must
/// stand out. A job's steps, in order: folds of the other steps, split by each failed step.
enum HootStepPart: Identifiable {
    case fold(index: Int, rows: [HootChatRow])
    case failed(HootChatRow)
    var id: String {
        switch self {
        case .fold(let index, let rows): return "fold:" + String(index) + ":" + (rows.first?.id ?? "")
        case .failed(let row): return "failed:" + row.id
        }
    }
    static func parts(_ steps: [HootChatRow]) -> [HootStepPart] {
        var parts: [HootStepPart] = [], run: [HootChatRow] = []
        func close() { if !run.isEmpty { parts.append(.fold(index: parts.count, rows: run)); run = [] } }
        for row in steps {
            if row.kind == .toolCall, HootFlow.failed(row) { close(); parts.append(.failed(row)) } else { run.append(row) }
        }
        close()
        return parts
    }
}

/// The failed step's own card: its plain-words line in the caution colour; it opens to what it was given and said.
struct HootFailedStepCard: View {
    let row: HootChatRow
    @State private var open = false
    var body: some View {
        let title = HootStep.title(row, live: false)
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy(duration: 0.18)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(title).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                    Text("Failed").foregroundStyle(.orange)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .font(.system(size: 12.5)).contentShape(.rect)
            }
            .buttonStyle(.plain).accessibilityLabel(title + ", failed" + (open ? ", expanded" : ", collapsed"))
            if open {
                VStack(alignment: .leading, spacing: 8) {
                    Text(row.value["input"].compact).font(.caption.monospaced()).textSelection(.enabled).lineLimit(12)
                    if row.value.has("output") { NativeChatToolResultContent(output: row.value["output"]).environment(\.nativeChatToolRowID, row.id) }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.orange.opacity(0.10), in: .rect(cornerRadius: 8))
        .accessibilityIdentifier("chat.failedStep." + row.id)
    }
}

struct HootStepsView: View {
    let rows: [HootChatRow]
    /// Hoot is working on this job now: a live list, row by row.
    let live: Bool
    /// The agents Hoot handed work to in this job (from the app's task records).
    var agents: [HootFlowAgent] = []
    var openTask: ((String) -> Void)? = nil
    /// Beside Hoot's avatar (in its reply) the steps need no indent of their own.
    var indent: CGFloat = 38
    var expansion: Binding<Bool>? = nil
    @State private var localExpanded = false
    private var expanded: Bool { expansion?.wrappedValue ?? localExpanded }
    private func toggleExpansion() {
        if let expansion { expansion.wrappedValue = !expansion.wrappedValue } else { localExpanded.toggle() }
    }
    var body: some View {
        let lines = HootFlow.lines(rows, agents: agents, live: live)
        if live { HootFlowLiveList(lines: lines).padding(.leading, indent) } else { summary(lines) }
    }
    private func summary(_ lines: [HootFlowLine]) -> some View {
        let line = HootStep.summary(rows)
        let extra = HootFlow.counts(lines, agents: agents.count)
        return VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.18)) { toggleExpansion() } } label: {
                HStack(spacing: 6) {
                    Text(line.text + extra).lineLimit(1).truncationMode(.middle)
                    counts(line.plus, line.minus)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .font(.system(size: 12.5)).foregroundStyle(.secondary).contentShape(.rect)
            }
            .buttonStyle(.plain).accessibilityLabel(line.text + extra + (expanded ? ", expanded" : ", collapsed"))
            if expanded {
                HootFlowTable(lines: lines, agents: agents, rows: rows, openTask: openTask).padding(.top, 6)
            }
        }
        .padding(.leading, indent)
    }
    @ViewBuilder private func counts(_ plus: Int, _ minus: Int) -> some View {
        if plus > 0 || minus > 0 {
            HStack(spacing: 3) {
                Text("+\(plus)").foregroundStyle(.green).padding(.horizontal, 3).background(Color.green.opacity(0.15), in: .rect(cornerRadius: 3))
                Text("−\(minus)").foregroundStyle(.red).padding(.horizontal, 3).background(Color.red.opacity(0.15), in: .rect(cornerRadius: 3))
            }.font(.system(size: 11, weight: .medium).monospacedDigit())
        }
    }
}
