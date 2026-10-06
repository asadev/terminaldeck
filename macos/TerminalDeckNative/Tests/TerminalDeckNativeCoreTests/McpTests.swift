import Foundation
import Testing
@testable import TerminalDeckNativeCore

// The MCP servers page, native. Mirrors McpSchemaForm.test.tsx, McpAddForm.test.tsx,
// mcp-machines.test.ts and the pure half of McpInspector.test.tsx.

private func json(_ text: String) -> OrderedJSON {
    guard let value = OrderedJSON.parse(text) else { fatalError("bad fixture: \(text)") }
    return value
}

// MARK: - OrderedJSON

@Test func mcpOrderedJSONKeepsKeyOrderAndPrintsLikeJavaScript() {
    let value = json(#"{"zeta": 1, "alpha": [true, null, 2.5, "a\"b"], "mid": {}, "e": 1e-7}"#)
    #expect(value.fields?.map(\.key) == ["zeta", "alpha", "mid", "e"])
    #expect(value.pretty == """
    {
      "zeta": 1,
      "alpha": [
        true,
        null,
        2.5,
        "a\\"b"
      ],
      "mid": {},
      "e": 1e-7
    }
    """)
    #expect(value.compact == #"{"zeta":1,"alpha":[true,null,2.5,"a\"b"],"mid":{},"e":1e-7}"#)
    #expect(OrderedJSON.parse("{") == nil)
    #expect(OrderedJSON.parse(#"{"a":1} x"#) == nil)
    #expect(json(#""\ud83d\ude00""#) == .string("😀"))
}

// MARK: - describeSchema

@Test func mcpSchemaReadsAWellFormedSchema() {
    let described = McpSchema.describe(json(#"""
    {"type": "object", "required": ["path"], "properties": {
      "path": {"type": "string", "description": "Where"},
      "depth": {"type": "integer", "default": 2},
      "all": {"type": "boolean"}}}
    """#))
    #expect(described.fallback == nil)
    #expect(described.fields.map(\.name) == ["path", "depth", "all"])
    #expect(described.fields.map(\.kind) == [.string, .integer, .boolean])
    #expect(described.fields[0].required && !described.fields[1].required)
    #expect(described.fields[0].description == "Where")
    #expect(described.fields[1].defaultValue == .number(2))
}

@Test func mcpSchemaFallsBackInsteadOfFailing() {
    #expect(McpSchema.describe(nil).fallback == "This tool did not describe its arguments.")
    #expect(McpSchema.describe(.null).fallback == "This tool did not describe its arguments.")
    #expect(McpSchema.describe(.string("x")).fallback == "This tool’s schema is not an object.")
    #expect(McpSchema.describe(json(#"{"type":"object","properties":[1]}"#)).fallback == "This tool’s argument list is malformed.")
    #expect(McpSchema.describe(json(#"{"type":"array"}"#)).fallback == "This tool’s schema describes a array, not an argument object.")
    #expect(McpSchema.describe(json(#"{"description":"x"}"#)).fallback == "This tool did not list any arguments.")
    // A no-argument tool is no fields, not a failure.
    let none = McpSchema.describe(json(#"{"type":"object"}"#))
    #expect(none.fallback == nil && none.fields.isEmpty)
}

@Test func mcpSchemaReadsEachKindOfField() {
    let fields = McpSchema.describe(json(#"""
    {"properties": {
      "bad": "a string",
      "maybe": {"type": ["null", "number"]},
      "loose": {"description": "anything"},
      "mode": {"anyOf": [{"const": "fast"}, {"const": "slow"}, {"type": "null"}]},
      "level": {"enum": [1, 2]},
      "opts": {"type": "object", "properties": {"x": {"type": "string"}}},
      "bag": {"type": "object"},
      "rows": {"type": "array", "items": {"type": "object"}},
      "tags": {"type": "array", "items": {"type": "string"}}}}
    """#)).fields
    let kinds = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0) })
    #expect(kinds["bad"]?.kind == .json)
    #expect(kinds["maybe"]?.kind == .number)
    #expect(kinds["loose"]?.kind == .string && kinds["loose"]?.inferred == true)
    #expect(kinds["loose"]?.typeWord == "text (type not declared)")
    #expect(kinds["mode"]?.options?.map(\.label) == ["fast", "slow"])
    #expect(kinds["level"]?.options?.map(\.value) == [.number(1), .number(2)])
    #expect(kinds["opts"]?.kind == .object && kinds["opts"]?.fields?.map(\.name) == ["x"])
    #expect(kinds["bag"]?.kind == .json)
    #expect(kinds["rows"]?.kind == .array && kinds["rows"]?.itemKind == nil)
    #expect(kinds["tags"]?.itemKind == .string)
}

@Test func mcpSchemaStopsDescendingOnceTheNestingGetsSilly() {
    let deep = json(#"{"properties":{"a":{"type":"object","properties":{"b":{"type":"object","properties":{"c":{"type":"object","properties":{"d":{"type":"object","properties":{"e":{"type":"string"}}}}}}}}}}}"#)
    var field = McpSchema.describe(deep).fields.first
    var depth = 0
    while let current = field, current.kind == .object {
        field = current.fields?.first
        depth += 1
    }
    #expect(depth == 3)
    #expect(field?.kind == .json)
}

// MARK: - values

@Test func mcpSchemaSeedsDefaultsAndPrunesBlanks() {
    let fields = McpSchema.describe(json(#"""
    {"properties": {"a": {"type": "string"}, "b": {"type": "number", "default": 3},
     "o": {"type": "object", "properties": {"x": {"type": "string", "default": "y"}}}}}
    """#)).fields
    #expect(McpSchema.initialValues(fields) == json(#"{"b": 3, "o": {"x": "y"}}"#))

    #expect(McpSchema.prune(json(#"{"a": "", "b": 0, "c": false}"#)) == json(#"{"b": 0, "c": false}"#))
    #expect(McpSchema.prune(json(#"{"o": {"x": ""}}"#)) == json("{}"))
    #expect(McpSchema.prune(json(#"{"list": []}"#)) == json(#"{"list": []}"#))
    // An untouched "Add item" row is dropped; everything else stays as typed.
    #expect(McpSchema.prune(json(#"{"list": ["a", null, ""]}"#)) == json(#"{"list": ["a", ""]}"#))
}

@Test func mcpSchemaPicksTheOptionAValueIs() {
    let options = [McpEnumOption(value: .string("a"), label: "a"), McpEnumOption(value: json(#"{"k":1}"#), label: #"{"k":1}"#)]
    #expect(McpSchema.selectIndex(options, nil) == nil)
    #expect(McpSchema.selectIndex(options, .string("a")) == 0)
    #expect(McpSchema.selectIndex(options, json(#"{"k":1}"#)) == 1)
    #expect(McpSchema.selectIndex(options, .string("z")) == nil)
}

@Test func mcpSchemaNamesWhatIsMissing() {
    let fields = McpSchema.describe(json(#"""
    {"required": ["name", "count", "flag", "list"], "properties": {
      "name": {"type": "string"}, "count": {"type": "number"}, "flag": {"type": "boolean"},
      "list": {"type": "array", "items": {"type": "string"}},
      "o": {"type": "object", "required": ["inner"], "properties": {"inner": {"type": "string"}}}}}
    """#)).fields
    #expect(McpSchema.missingRequired(fields, json("{}")) == ["name", "count", "flag", "list", "o.inner"])
    // false and 0 are answers; an empty list is not.
    #expect(McpSchema.missingRequired(fields, json(#"{"name":"n","count":0,"flag":false,"list":[],"o":{"inner":"i"}}"#)) == ["list"])
}

@Test func mcpSchemaReadsNumbersAndJSONBoxes() {
    #expect(McpSchema.number("", integer: false) == nil)
    #expect(McpSchema.number("2.5", integer: false) == .number(2.5))
    #expect(McpSchema.number("12abc", integer: true) == .number(12))
    #expect(McpSchema.number("-3.9", integer: true) == .number(-3))
    #expect(McpSchema.number("abc", integer: true) == nil)
    #expect(McpSchema.readJSONBox("  ").value == nil && McpSchema.readJSONBox("  ").error == nil)
    #expect(McpSchema.readJSONBox("[1]").value == json("[1]"))
    #expect(McpSchema.readJSONBox("{").error == "Invalid JSON")
}

// MARK: - Adding a server

@Test func mcpAddOffersScopesByProject() {
    #expect(McpScopeChoice.choices(projectPath: nil).map(\.value) == [.user])
    #expect(McpScopeChoice.choices(projectPath: "/w/api").map(\.label) == ["All projects", "This project only", "This project, shared"])
    #expect(McpScopeChoice.choices(projectPath: "/w/api").allSatisfy { !$0.help.isEmpty })
    #expect(McpScopeChoice.choices(projectPath: "/w/api")[2].help.contains("inactive until Claude Code asks you to approve it"))
    #expect(McpScopeChoice.note(scope: .user, projectPath: nil) == "Available everywhere. Open a project to save one for that project alone.")
}

@Test func mcpAddSendsOnlyTheChosenTransportsField() throws {
    var draft = McpAddDraft()
    draft.name = "  files "
    draft.command = " npx server "
    draft.url = "https://stale"
    draft.extras = "A=1\n\n  B=2  \n"
    let stdio = draft.request(projectPath: "/w/api")
    #expect(stdio["name"] as? String == "files")
    #expect(stdio["command"] as? String == "npx server")
    #expect(stdio["url"] as? String == "")
    #expect(stdio["extras"] as? [String] == ["A=1", "B=2"])
    #expect(stdio["projectPath"] as? String == "/w/api")
    draft.transport = .http
    let http = draft.request(projectPath: nil)
    #expect(http["command"] as? String == "")
    #expect(http["url"] as? String == "https://stale")
    #expect(http["projectPath"] is NSNull)
}

@Test func mcpAddSaysWhatIsMissing() {
    var draft = McpAddDraft()
    #expect(draft.missing == "Give the server a name first.")
    draft.name = "x"
    #expect(draft.missing == "Say which command starts it.")
    draft.transport = .sse
    #expect(draft.missing == "Say which URL it is reached at.")
    draft.url = "https://x"
    #expect(draft.missing == nil)
}

@Test func mcpEditAndImportStarts() {
    let edit = McpFormStart.edit(name: "gh", scope: .local, transport: .stdio, command: "npx gh", envKeys: ["TOKEN", "ORG"])
    #expect(edit.draft.extras == "TOKEN=\nORG=")
    #expect(edit.draft.command == "npx gh" && edit.draft.url == "")
    #expect(edit.savedNote?.hasPrefix("TOKEN, ORG already have values in your configuration") == true)
    let remote = McpFormStart.edit(name: "r", scope: .user, transport: .http, command: "https://r", envKeys: [])
    #expect(remote.draft.url == "https://r" && remote.draft.command == "")
    #expect(remote.savedNote == nil)
    let imported = McpFormStart.import(name: "i", transport: .stdio, command: "c", url: "", env: ["K"], scope: .user)
    #expect(imported.savedKeys.isEmpty && imported.draft.extras == "K=")
}

// MARK: - Servers and inventory (McpInspector)

@Test func mcpServerLinesAndStates() throws {
    let local = try #require(McpServerStatus.from(json(#"{"id":"a","name":"a","transport":"stdio","command":"node","args":["s.js","--x"],"state":"ready"}"#)))
    #expect(local.commandLine == "node s.js --x")
    let remote = try #require(McpServerStatus.from(json(#"{"id":"b","name":"b","transport":"http","url":"https://b","unsupported":"Claude Code dials it"}"#)))
    #expect(remote.commandLine == "https://b")
    #expect(remote.whyLabel == "Why it cannot be opened")
    // A status pushed without an args array does not throw.
    #expect(McpServerStatus.from(json(#"{"id":"c","transport":"stdio","command":"x"}"#))?.commandLine == "x")
    #expect(McpConnectionState.allCasesLabels == ["Not connected", "Connecting", "Connected", "Failed", "Exited"])
    // A push lays its fields over what is held.
    let merged = local.merging(json(#"{"id":"a","state":"failed","error":"boom"}"#))
    #expect(merged.state == .failed && merged.error == "boom" && merged.command == "node")
}

@Test func mcpResultTextAndSectionErrors() {
    let result = McpCallResult.from(json(#"{"ok":true,"durationMs":12,"result":{"content":[{"type":"text","text":"one"},{"type":"image"},{"type":"text","text":"two"},7]}}"#))
    #expect(result.text == "one\ntwo")
    #expect(result.summary == "Succeeded in 12ms")
    #expect(McpCallResult.from(json(#"{"ok":true,"result":{"content":"x"}}"#)).text == nil)

    let inventory = McpInventory.from(json(#"""
    {"serverId":"a","tools":[{"name":"t"}],"resources":[{"uri":"u"}],"resourceTemplates":[{"uriTemplate":"v/{x}"}],"prompts":[],
     "errors":{"resourceTemplates":"templates failed","server":"down","tools":"tools failed","prompts":"down"}}
    """#))
    #expect(inventory.count(.resources) == 2)
    #expect(inventory.errors(for: .resources) == ["templates failed", "down"])
    #expect(inventory.errors(for: .tools) == ["down", "tools failed"])
    #expect(inventory.errors(for: .prompts) == ["down"])
    #expect(McpInventory.from(json(#"{"errors":{}}"#)).errors(for: .tools).isEmpty)
    #expect(mcpFolderName("/Users/me/code/api/") == "api")
}

@Test func mcpDeadlinesSayItPlainly() {
    #expect(McpDeadline.overdue("Reading your MCP configuration", seconds: 12) == "Reading your MCP configuration did not answer within 12 seconds.")
    #expect(McpDeadline.describe(seconds: 1) == "1 second")
    #expect(McpDeadline.describe(seconds: 0.5) == "500 ms")
    #expect(McpDeadline.failure("Error invoking remote method 'mcp:add': Error: nope") == "Error: nope")
}

// MARK: - Another machine (mcp-machines)

private let estate = json(#"""
{"here": "  ", "machines": [
  {"id": "pc", "name": "Office PC"}, {"id": "off", "name": "Offline"}, {"id": "old", "name": "Old build"},
  {"id": "idle", "name": "No sessions"}, {"id": "lab", "name": "Lab"}],
 "links": [
  {"id": "pc", "state": "online", "capabilities": ["controls"], "sessions": [{"id": "s1", "title": "api", "cwd": "C:/w/api"}]},
  {"id": "off", "state": "offline", "capabilities": ["controls"], "sessions": [{"id": "s2", "title": "x", "cwd": ""}]},
  {"id": "old", "state": "online", "capabilities": [], "sessions": [{"id": "s3", "title": "y", "cwd": ""}]},
  {"id": "idle", "state": "online", "capabilities": ["controls"], "sessions": []},
  {"id": "lab", "state": "online", "capabilities": ["controls"], "sessions": [{"id": "s4", "title": "", "cwd": "/srv"}]}]}
"""#)

@Test func mcpMachinesOffersOnlyThoseThatCanAnswer() {
    let targets = McpMachineTarget.reportable(estate)
    #expect(targets.map(\.machineId) == ["pc", "lab"])
    #expect(targets[0].sessionId == "s1" && targets[0].sessionTitle == "api" && targets[0].cwd == "C:/w/api")
    #expect(targets[1].sessionTitle == "a session")
    #expect(McpMachineTarget.hereName(estate) == "This Mac")
    #expect(McpMachineTarget.hereName(json(#"{"here":"Studio"}"#)) == "Studio")
}

@Test func mcpMachinesForgetsAPickThatCanNoLongerBeRead() {
    let targets = McpMachineTarget.reportable(estate)
    #expect(McpMachineTarget.pickSurvives("pc", targets))
    #expect(!McpMachineTarget.pickSurvives("off", targets))
    #expect(!McpMachineTarget.pickSurvives("idle", targets))
    #expect(McpMachineTarget.pickSurvives(nil, []))
}

@Test func mcpMachinesReadsTheConnectors() {
    #expect(McpRow.list(nil) == nil)
    #expect(McpRow.list(json(#"{"x":1}"#)) == nil)
    let rows = McpRow.list(json(#"[{"id":"a","name":"a","scope":"user","transport":"stdio"},{"id":"b","name":"b","enabled":false,"disabledReason":"Not approved"},{"name":"no id"}]"#))
    #expect(rows?.map(\.id) == ["a", "b"])
    #expect(rows?[0].detail == "user · stdio")
    #expect(rows?[1].detail == "Not approved")
    #expect(rows?[1].enabled == false)
}

private extension McpConnectionState {
    static var allCasesLabels: [String] {
        [McpConnectionState.idle, .connecting, .ready, .failed, .closed].map(\.label)
    }
}
