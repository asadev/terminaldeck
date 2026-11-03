import Foundation
import TerminalDeckNativeCore

/// The Memory area's own actions as tools (L5, 11 Oct; HOOT-TOOL-AUDIT.md): everything a person can do in a
/// seat's Memory area and on the Templates screen, for Hoot and for AI apps the person gave a key to.
/// Same door as `DeckMemoryTools`: the caller is identified by the app, reads are free, every change goes
/// through the same consent gate (the caller's permission mode decides whether it asks) and the action log,
/// and each one calls the very store call the Memory area's button calls. Sessions are not granted these.
public enum DeckMemoryProfileTools {
    private typealias K = BackendDeckToolsAppKit
    private typealias M = DeckMemoryTools

    private struct Spec { let id: String, tier: BackendMCPTier, title: String, description: String, schema: String }
    private static let seat = #""seat":{"type":"string","description":"Whose memory: hoot, lead:<project>, role:<project>/<role>. Leave out for Hoot's own."}"#
    private static let category = #""category":{"type":"string","enum":["orchestrator","lead","agent"]}"#
    private static let specs: [Spec] = [
        .init(id: "memory.notes.list", tier: .read, title: "List memory notes",
              description: "List a seat's notes, newest first, as the Memory area's Notes part shows them: by type, current or archived.",
              schema: #"{"type":"object","properties":{\#(seat),"type":{"type":"string"},"archived":{"type":"boolean","description":"true lists the archived ones."},"limit":{"type":"number"}},"additionalProperties":false}"#),
        .init(id: "memory.note.edit", tier: .act, title: "Edit a memory note",
              description: "Change a note's title, text or type, as Save does on an open note. The earlier text is kept.",
              schema: #"{"type":"object","properties":{"id":{"type":"string"},"title":{"type":"string","maxLength":200},"text":{"type":"string","maxLength":8000},"type":{"type":"string"}},"required":["id"],"additionalProperties":false}"#),
        .init(id: "memory.note.restore", tier: .act, title: "Restore an archived note",
              description: "Bring an archived note back into the current notes.",
              schema: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}"#),
        .init(id: "memory.card.save", tier: .alter, title: "Save a seat's own card text",
              description: "Replace the seat's OWN part of its card (the part under the shared template). The template part is changed with memory.template.save.",
              schema: #"{"type":"object","properties":{\#(seat),"text":{"type":"string","maxLength":40000}},"required":["text"],"additionalProperties":false}"#),
        .init(id: "memory.template.read", tier: .read, title: "Read a category template",
              description: "Read the template shared by every seat of one category (orchestrator, lead, agent): shared card text, memory parts, helper checklist, helper AI and model, card limit, sessions per seat.",
              schema: #"{"type":"object","properties":{\#(category)},"required":["category"],"additionalProperties":false}"#),
        .init(id: "memory.template.save", tier: .alter, title: "Change a category template",
              description: "Change a category template. Applies at once to every seat of that category and to future hires. Fields left out stay as they are.",
              schema: #"{"type":"object","properties":{\#(category),"card":{"type":"string","maxLength":40000},"checklist":{"type":"string","maxLength":20000},"parts":{"type":"array","items":{"type":"string","enum":["card","notes","diary","topics","playbook","board","helper"]}},"helperAI":{"type":"string","enum":["claude","codex","gemini"]},"helperModel":{"type":"string"},"cardLimit":{"type":"number","minimum":500,"maximum":40000},"handsPerSeat":{"type":"number","minimum":1,"maximum":12},"handsPerProject":{"type":"number","minimum":1,"maximum":60}},"required":["category"],"additionalProperties":false}"#),
        .init(id: "memory.topics.list", tier: .read, title: "List where-we-are topics",
              description: "List a seat's topics (open first), with their text.",
              schema: #"{"type":"object","properties":{\#(seat),"closed":{"type":"boolean","description":"true includes closed topics."}},"additionalProperties":false}"#),
        .init(id: "memory.topic.set_open", tier: .act, title: "Close or reopen a topic",
              description: "Close a topic (kept, no longer handed to a clean desk) or reopen it.",
              schema: #"{"type":"object","properties":{\#(seat),"id":{"type":"string"},"open":{"type":"boolean"}},"required":["id","open"],"additionalProperties":false}"#),
        .init(id: "memory.board.remove", tier: .alter, title: "Take a row off the board",
              description: "Take one row off the board, as the row's Take off the board button does. It is archived, not deleted.",
              schema: #"{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false}"#),
        .init(id: "memory.questions", tier: .read, title: "Read the tidy-up's questions",
              description: "The tidy-up's Questions for you: open, answered and dismissed, for one seat or all.",
              schema: #"{"type":"object","properties":{\#(seat),"openOnly":{"type":"boolean"}},"additionalProperties":false}"#),
        .init(id: "memory.question.answer", tier: .act, title: "Answer, dismiss or reopen a question",
              description: "Answer one of the tidy-up's questions (answer), wave it away for good (dismiss: true), or ask it again (reopen: true). Only on the person's own words.",
              schema: #"{"type":"object","properties":{"id":{"type":"number"},"answer":{"type":"string","maxLength":2000},"dismiss":{"type":"boolean"},"reopen":{"type":"boolean"}},"required":["id"],"additionalProperties":false}"#),
        .init(id: "memory.flow.switch", tier: .alter, title: "Switch the memory helper or tidy-up on or off",
              description: "Switch the note helper or the nightly tidy-up on or off for the whole app, as the switches in the Helper and Tidy-up parts do.",
              schema: #"{"type":"object","properties":{"which":{"type":"string","enum":["helper","tidy"]},"on":{"type":"boolean"}},"required":["which","on"],"additionalProperties":false}"#),
        .init(id: "memory.folder", tier: .act, title: "Memory folder: where, reindex, back up, move, import",
              description: "The Memory area's Folder part. action where: the folder's path. reindex: rebuild the search index. backup: back up now. move: move the whole memory to path (a logged change). import: copy a Claude Code or Codex memory folder at path into a seat's notes (the original is never changed).",
              schema: #"{"type":"object","properties":{"action":{"type":"string","enum":["where","reindex","backup","move","import"]},"path":{"type":"string"},\#(seat)},"required":["action"],"additionalProperties":false}"#),
        .init(id: "memory.handoffs", tier: .read, title: "List or read handoffs",
              description: "A seat's kept context handoffs, newest first (pass topic to narrow), or one handoff in full (pass id).",
              schema: #"{"type":"object","properties":{\#(seat),"topic":{"type":"string"},"id":{"type":"string"}},"additionalProperties":false}"#),
    ]
    public static var toolIDs: [String] { specs.map(\.id) }

    public static func definitions(access: BackendDeckToolsAppAccess) throws -> [BackendDeckToolsDefinition] {
        try specs.map { spec in
            let tool = try BackendMCPTool(id: spec.id, wireName: spec.id.replacingOccurrences(of: ".", with: "_"), description: spec.description,
                                          inputSchema: NativeRPCValue.parseJSON(Data(spec.schema.utf8)), tier: spec.tier, advertised: false)
            return BackendDeckToolsDefinition(spec: tool, title: spec.title, index: spec.title) { context, args in
                do {
                    guard args.fields != nil else { throw BackendDeckToolsArgs.bad("arguments must be an object") }
                    guard context.allowedTiers.contains(spec.tier) else { throw K.refused("This caller is not permitted to use that tool.") }
                    if context.cancellation.isCancelled { throw CancellationError() }
                    try BackendDeckCoreCatalogueSchema.check(schema: tool.inputSchema, arguments: args)
                    guard DeckMemory.isReady else { throw K.unavailable("Memory") }
                    let caller = try await M.caller(access, context)
                    // The Memory area belongs to the person: Hoot (at the keyboard's side) and keyed AI apps only.
                    guard caller.seesAll else { throw K.refused("A session works its own seat with the memory_* tools; these are the Memory area's own controls.") }
                    return .value(try await run(spec.id, args: args, caller: caller, access: access, context: context))
                } catch is CancellationError { throw CancellationError() }
                catch let error as DeckMemoryError {
                    return BackendDeckToolsMachinesFactory.failureReply(NativeRPCError(code: error.code == .notFound ? "not-found" : "memory", message: error.message))
                }
                catch { return BackendDeckToolsMachinesFactory.failureReply(error) }
            }
        }
    }

    private static func gate(_ access: BackendDeckToolsAppAccess, _ context: BackendMCPCallContext, _ id: String, _ tier: BackendMCPTier,
                             _ sentence: String, mustAnswer: Bool, _ safe: NativeRPCValue) async throws {
        try await access.authorize(context, id, safe, tier, sentence, mustAnswer)
        if context.cancellation.isCancelled { throw CancellationError() }
    }
    private static func owner(_ args: NativeRPCValue) throws -> DeckMemoryOwner {
        guard let named = try K.optStr(args, "seat", trimmed: true) else { return .hoot }
        guard let owner = DeckMemoryOwner(named) else { throw BackendDeckToolsArgs.bad("seat must look like hoot, lead:<project> or role:<project>/<role>") }
        return owner
    }
    private static func categoryArg(_ args: NativeRPCValue) throws -> DeckMemoryCategory {
        let raw = try K.str(args, "category", trimmed: true)
        guard let found = DeckMemoryCategory.allCases.first(where: { $0.rawValue == raw }) else { throw BackendDeckToolsArgs.bad("category is orchestrator, lead or agent") }
        return found
    }
    private static func wire(_ topic: DeckMemoryTopic) -> NativeRPCValue {
        K.object([("id", .string(topic.id)), ("title", .string(topic.title)), ("open", .bool(topic.open)), ("text", .string(topic.body)),
                  ("job", M.opt(topic.job)), ("updated", M.iso(topic.updatedAt))])
    }
    private static func wire(_ question: DeckMemoryQuestion) -> NativeRPCValue {
        K.object([("id", .number(Double(question.id))), ("seat", .string(question.owner.key)), ("question", .string(question.text)),
                  ("why", .string(question.context)), ("state", .string(question.isDismissed ? "dismissed" : question.isOpen ? "open" : "answered")),
                  ("answer", M.opt(question.answer)), ("asked", M.iso(question.askedAt))])
    }
    private static func wire(_ template: DeckMemoryTemplate) -> NativeRPCValue {
        K.object([("category", .string(template.category.rawValue)), ("card", .string(template.card)), ("checklist", .string(template.checklist)),
                  ("parts", K.strings(template.parts.map(\.rawValue).sorted())),
                  ("helperAI", .string(template.helperAI)), ("helperModel", .string(template.helperModel)), ("cardLimit", K.n(template.cardLimit)),
                  ("handsPerSeat", K.n(template.handsPerSeat)), ("handsPerProject", K.n(template.handsPerProject))])
    }

    private static func run(_ id: String, args: NativeRPCValue, caller: M.Caller, access: BackendDeckToolsAppAccess,
                            context: BackendMCPCallContext) async throws -> NativeRPCValue {
        let memory = DeckMemory.store
        // An AI app holding a key is not at the keyboard: its changes always wait for the person's own answer.
        let keyed = caller.kind == .key
        switch id {
        case "memory.notes.list":
            let seat = try owner(args), archived = try BackendDeckToolsArgs.optBool(args, "archived", false)
            let limit = try BackendDeckToolsArgs.optInt(args, "limit", 100, 1, 500)
            let type = try K.optStr(args, "type", trimmed: true).map { DeckMemoryNoteType(rawValue: $0) }
            try await gate(access, context, id, .read, "List the notes of \(seat.key)", mustAnswer: false, K.object([("seat", .string(seat.key))]))
            let notes = try await memory.notes(.init(owner: seat, type: type, archivedOnly: archived, limit: limit))
            try await access.record(context, id, K.object([("seat", .string(seat.key))]), K.object([("notes", K.n(notes.count))]))
            return K.object([("seat", .string(seat.key)), ("notes", .array(notes.map(M.wire)))])
        case "memory.note.edit":
            let noteID = try K.str(args, "id", trimmed: true)
            guard let note = try await memory.note(id: noteID) else { throw BackendDeckToolsArgs.bad("there is no note with the id \(noteID)") }
            let title = try K.optStr(args, "title", trimmed: true), text = try K.optStr(args, "text")
            let type = try K.optStr(args, "type", trimmed: true).map { DeckMemoryNoteType(rawValue: $0) }
            guard title != nil || text != nil || type != nil else { throw BackendDeckToolsArgs.bad("pass title, text or type to change") }
            let safe = K.object([("id", .string(noteID)), ("seat", .string(note.labels.seat)), ("title", .string(title ?? note.title))])
            try await gate(access, context, id, .act, "Edit the memory note “\(note.title)”", mustAnswer: keyed, safe)
            let saved = try await memory.updateNote(id: noteID, title: title, body: text, type: type)
            try await access.record(context, id, safe, K.object([("saved", .bool(true))]))
            return M.wire(saved)
        case "memory.note.restore":
            let noteID = try K.str(args, "id", trimmed: true)
            guard let note = try await memory.note(id: noteID) else { throw BackendDeckToolsArgs.bad("there is no note with the id \(noteID)") }
            let safe = K.object([("id", .string(noteID)), ("title", .string(note.title))])
            try await gate(access, context, id, .act, "Restore the memory note “\(note.title)”", mustAnswer: keyed, safe)
            let restored = try await memory.restoreNote(id: noteID)
            try await access.record(context, id, safe, K.object([("restored", .bool(true))]))
            return M.wire(restored)
        case "memory.card.save":
            let seat = try owner(args), text = try K.str(args, "text")
            let safe = K.object([("seat", .string(seat.key)), ("characters", K.n(text.count))])
            try await gate(access, context, id, .alter, "Replace the own card text of \(seat.key)", mustAnswer: keyed, safe)
            let card = try await memory.saveCard(seat, text: text)
            try await access.record(context, id, safe, K.object([("characters", K.n(card.characters))]))
            return K.object([("seat", .string(seat.key)), ("size", .string("\(card.characters + card.sharedCharacters) of \(card.limit) characters" + (card.overBy > 0 ? ", over by \(card.overBy)" : "")))])
        case "memory.template.read":
            let kind = try categoryArg(args)
            try await gate(access, context, id, .read, "Read the \(kind.title) template", mustAnswer: false, K.object([("category", .string(kind.rawValue))]))
            let template = try await memory.template(kind)
            try await access.record(context, id, K.object([("category", .string(kind.rawValue))]), K.object([("read", .bool(true))]))
            return wire(template)
        case "memory.template.save":
            let kind = try categoryArg(args)
            var template = try await memory.template(kind)
            var changed: [String] = []
            if let text = try K.optStr(args, "card") { template.card = text; changed.append("shared card") }
            if let text = try K.optStr(args, "checklist") { template.checklist = text; changed.append("checklist") }
            if let parts = args["parts"].elements {
                template.parts = Set(parts.compactMap(\.string).compactMap { DeckMemoryPart(rawValue: $0) }); changed.append("parts")
            }
            if let value = try K.optStr(args, "helperAI", trimmed: true) { template.helperAI = value; changed.append("helper AI") }
            if let value = try K.optStr(args, "helperModel", trimmed: true) { template.helperModel = value; changed.append("helper model") }
            if let value = args["cardLimit"].number { template.cardLimit = NativeNumber.clamped(value, to: 500...40_000, fallback: template.cardLimit); changed.append("card limit") }
            if let value = args["handsPerSeat"].number { template.handsPerSeat = NativeNumber.clamped(value, to: 1...12, fallback: template.handsPerSeat); changed.append("sessions per seat") }
            if let value = args["handsPerProject"].number { template.handsPerProject = NativeNumber.clamped(value, to: 1...60, fallback: template.handsPerProject); changed.append("sessions per project") }
            guard !changed.isEmpty else { throw BackendDeckToolsArgs.bad("pass at least one field to change") }
            let safe = K.object([("category", .string(kind.rawValue)), ("fields", K.strings(changed))])
            // It applies to every seat of the category at once and to future hires: an alter, so Hoot's permission mode decides.
            try await gate(access, context, id, .alter, "Change the \(kind.title) template for \(kind.everyone) (\(changed.joined(separator: ", ")))", mustAnswer: keyed, safe)
            let saved = try await memory.saveTemplate(template)
            try await access.record(context, id, safe, K.object([("saved", .bool(true))]))
            return wire(saved)
        case "memory.topics.list":
            let seat = try owner(args), closed = try BackendDeckToolsArgs.optBool(args, "closed", false)
            try await gate(access, context, id, .read, "List the topics of \(seat.key)", mustAnswer: false, K.object([("seat", .string(seat.key))]))
            let topics = try await memory.topics(seat, includeClosed: closed).sorted { $0.open && !$1.open }
            try await access.record(context, id, K.object([("seat", .string(seat.key))]), K.object([("topics", K.n(topics.count))]))
            return K.object([("seat", .string(seat.key)), ("topics", .array(topics.map(wire)))])
        case "memory.topic.set_open":
            let seat = try owner(args), topicID = try K.str(args, "id", trimmed: true)
            guard let open = args["open"].bool else { throw BackendDeckToolsArgs.bad("open must be true or false") }
            let safe = K.object([("seat", .string(seat.key)), ("id", .string(topicID)), ("open", .bool(open))])
            try await gate(access, context, id, .act, (open ? "Reopen" : "Close") + " the topic \(topicID) of \(seat.key)", mustAnswer: keyed, safe)
            let topic = try await memory.setTopic(seat, id: topicID, open: open)
            try await access.record(context, id, safe, K.object([("open", .bool(topic.open))]))
            return wire(topic)
        case "memory.board.remove":
            let rowID = try K.str(args, "id", trimmed: true)
            let safe = K.object([("id", .string(rowID))])
            try await gate(access, context, id, .alter, "Take \(rowID) off the board", mustAnswer: keyed, safe)
            let row = try await memory.archiveBoardRow(id: rowID)
            try await access.record(context, id, safe, K.object([("removed", .bool(true))]))
            return K.object([("removed", .string(row.title))])
        case "memory.questions":
            let named = try K.optStr(args, "seat", trimmed: true) == nil ? nil : try owner(args)
            let openOnly = try BackendDeckToolsArgs.optBool(args, "openOnly", true)
            try await gate(access, context, id, .read, "Read the tidy-up's questions", mustAnswer: false, K.object([("seat", M.opt(named?.key))]))
            let found = try await memory.questions(owner: named, openOnly: openOnly)
            try await access.record(context, id, K.object([("seat", M.opt(named?.key))]), K.object([("questions", K.n(found.count))]))
            return K.object([("questions", .array(found.map(wire)))])
        case "memory.question.answer":
            guard let number = NativeNumber.integer(args["id"].number, in: 1...Int.max) else { throw BackendDeckToolsArgs.bad("id must be a question id (a whole number)") }
            let answer = try K.optStr(args, "answer", trimmed: true)
            let dismiss = try BackendDeckToolsArgs.optBool(args, "dismiss", false), reopen = try BackendDeckToolsArgs.optBool(args, "reopen", false)
            guard [answer != nil && !(answer ?? "").isEmpty, dismiss, reopen].filter({ $0 }).count == 1 else {
                throw BackendDeckToolsArgs.bad("pass exactly one of answer, dismiss: true or reopen: true")
            }
            let verb = dismiss ? "Dismiss" : reopen ? "Ask again" : "Answer"
            let safe = K.object([("id", K.n(number)), ("action", .string(verb.lowercased()))])
            try await gate(access, context, id, .act, "\(verb) the tidy-up's question \(number)", mustAnswer: keyed, safe)
            let question = dismiss ? try await memory.dismissQuestion(id: Int64(number))
                : reopen ? try await memory.reopenQuestion(id: Int64(number))
                : try await memory.answerQuestion(id: Int64(number), answer: answer ?? "")
            try await access.record(context, id, safe, K.object([("done", .bool(true))]))
            return wire(question)
        case "memory.flow.switch":
            let which = try K.oneOf(args, "which", ["helper", "tidy"])
            guard let on = args["on"].bool else { throw BackendDeckToolsArgs.bad("on must be true or false") }
            let key = which == "helper" ? DeckMemoryFlowKeys.helperOn : DeckMemoryFlowKeys.tidyOn
            let name = which == "helper" ? "the memory helper" : "the nightly tidy-up"
            let safe = K.object([("which", .string(which)), ("on", .bool(on))])
            try await gate(access, context, id, .alter, "Switch \(name) " + (on ? "on" : "off") + " for the whole app", mustAnswer: keyed, safe)
            try await memory.setValue(on ? "1" : "0", key: key, owner: nil)
            await DeckMemoryFlow.settingsChanged()
            try await access.record(context, id, safe, K.object([("on", .bool(on))]))
            return K.object([("which", .string(which)), ("on", .bool(on))])
        case "memory.folder":
            let action = try K.oneOf(args, "action", ["where", "reindex", "backup", "move", "import"])
            switch action {
            case "where":
                try await gate(access, context, id, .read, "Read where the memory lives", mustAnswer: false, K.object([("action", .string(action))]))
                let place = await memory.location()
                return K.object([("folder", .string(place.root.path)), ("default", .string(place.defaultRoot.path))])
            case "reindex":
                try await gate(access, context, id, .act, "Rebuild the memory's search index", mustAnswer: keyed, K.object([("action", .string(action))]))
                let report = try await memory.reindex()
                try await access.record(context, id, K.object([("action", .string(action))]), K.object([("scanned", K.n(report.scanned))]))
                return K.object([("scanned", K.n(report.scanned)), ("added", K.n(report.added)), ("changed", K.n(report.changed)), ("missing", K.n(report.missing))])
            case "backup":
                try await gate(access, context, id, .act, "Back up the memory now", mustAnswer: keyed, K.object([("action", .string(action))]))
                let file = try await memory.backup()
                try await access.record(context, id, K.object([("action", .string(action))]), K.object([("done", .bool(true))]))
                return K.object([("backup", .string(file.path))])
            case "move":
                let path = (try K.str(args, "path", trimmed: true) as NSString).expandingTildeInPath
                guard path.hasPrefix("/") else { throw BackendDeckToolsArgs.bad("path must be a full folder path") }
                let safe = K.object([("action", .string(action)), ("to", .string(path))])
                // Every seat's memory moves: the person answers this one.
                try await gate(access, context, id, .alter, "Move all memory to \(path)", mustAnswer: true, safe)
                let report = try await memory.move(to: URL(fileURLWithPath: path, isDirectory: true))
                try await access.record(context, id, safe, K.object([("files", K.n(report.files)), ("verified", .bool(report.verified))]))
                return K.object([("from", .string(report.from.path)), ("to", .string(report.to.path)), ("files", K.n(report.files)), ("verified", .bool(report.verified))])
            default:
                let path = (try K.str(args, "path", trimmed: true) as NSString).expandingTildeInPath
                var folder: ObjCBool = false
                guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &folder), folder.boolValue else {
                    throw BackendDeckToolsArgs.bad("path must be an existing folder")
                }
                let seat = try owner(args)
                let safe = K.object([("action", .string(action)), ("from", .string(path)), ("seat", .string(seat.key))])
                try await gate(access, context, id, .alter, "Import the memory folder \(path) into \(seat.key)", mustAnswer: keyed, safe)
                let report = try await memory.importFolder(URL(fileURLWithPath: path, isDirectory: true), into: seat, label: nil)
                try await access.record(context, id, safe, K.object([("imported", K.n(report.imported))]))
                return K.object([("seat", .string(seat.key)), ("imported", K.n(report.imported)), ("folder", .string(report.folder))])
            }
        case "memory.handoffs":
            let seat = try owner(args)
            try await gate(access, context, id, .read, "Read the handoffs of \(seat.key)", mustAnswer: false, K.object([("seat", .string(seat.key))]))
            if let one = try K.optStr(args, "id", trimmed: true) {
                guard let found = try await memory.handoff(id: one) else { throw BackendDeckToolsArgs.bad("there is no handoff with the id \(one)") }
                return K.object([("id", .string(found.id)), ("title", .string(found.title)), ("topic", M.opt(found.topic)),
                                 ("markdown", .string(found.markdown)), ("file", .string(found.path)), ("written", M.iso(found.createdAt))])
            }
            let list = try await memory.handoffs(seat, topic: try K.optStr(args, "topic", trimmed: true))
            try await access.record(context, id, K.object([("seat", .string(seat.key))]), K.object([("handoffs", K.n(list.count))]))
            return K.object([("handoffs", .array(list.map { K.object([("id", .string($0.id)), ("title", .string($0.title)), ("topic", M.opt($0.topic)), ("written", M.iso($0.createdAt))]) }))])
        default:
            throw K.unavailable(id)
        }
    }
}
