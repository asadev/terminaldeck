import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckCoreCatalogueRulesTests: XCTestCase {
    private typealias Rules = BackendDeckCoreCatalogueRules
    private func json(_ text: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(text.utf8)) }
    private var step: NativeRPCValue { try! json(#"{"type":"object","properties":{"verb":{"type":"string","enum":["click","type","press"]},"selector":{"type":"string"},"value":{"type":"string"},"timeoutMs":{"type":"number"}},"required":["verb","selector"],"additionalProperties":false}"#) }
    private func refusal(_ schema: NativeRPCValue, _ args: NativeRPCValue) -> String {
        do { try BackendDeckCoreCatalogueSchema.check(schema: schema, arguments: args); return "" }
        catch { return error.localizedDescription }
    }
    func testUnknownArgumentsAreNamedBeforeMissingAndListRealNames() throws {
        let args = try json(##"{"verb":"type","selector":"#q","text":"hello"}"##)
        XCTAssertEqual(refusal(step, args), "text is not an argument this tool takes. It takes: verb, selector, value, timeoutMs.")
        XCTAssertTrue(refusal(step, try json(#"{"bypass":true,"approved":true}"#)).contains("bypass, approved are not arguments"))
        XCTAssertEqual(refusal(step, args.removing("text").setting("text", .missing)), "")
        XCTAssertEqual(refusal(try json(#"{"type":"object","properties":{}}"#), args), "")
    }
    func testValueShapeEnumRequiredAndUnknownKeywords() throws {
        XCTAssertEqual(refusal(step, try json(#"{"verb":"click","selector":7}"#)), "selector must be string, not integer")
        XCTAssertEqual(refusal(step, try json(#"{"verb":"click","selector":null}"#)), "selector must be string, not null")
        XCTAssertEqual(refusal(step, try json(##"{"verb":"hover","selector":"#a"}"##)), "verb must be one of: click, type, press — not \"hover\"")
        XCTAssertEqual(refusal(step, .object([])), "verb, selector are required")
        let arbitrary = try json(#"{"properties":{"at":{"type":"string","format":"date-time","pattern":"^z"}}}"#)
        XCTAssertEqual(refusal(arbitrary, try json(#"{"at":"not a date"}"#)), "")
    }
    func testFiniteNumbersArrayItemsAndUnionTypes() throws {
        let schema = try json(#"{"properties":{"n":{"type":"number"},"whole":{"type":"integer"},"steps":{"type":"array","items":{"type":"string"}},"maybe":{"type":["string","null"]}}}"#)
        XCTAssertEqual(refusal(schema, .object([.init("n", .number(.nan))])), "n must be number, not number")
        XCTAssertEqual(refusal(schema, .object([.init("n", .number(.infinity))])), "n must be number, not number")
        XCTAssertEqual(refusal(schema, try json(#"{"whole":1.5}"#)), "whole must be integer, not number")
        XCTAssertEqual(refusal(schema, try json(#"{"steps":["a",2]}"#)), "steps[1] must be string, not integer")
        XCTAssertEqual(refusal(schema, try json(#"{"maybe":null}"#)), "")
        XCTAssertEqual(refusal(schema, try json(#"{"maybe":true}"#)), "maybe must be one of: string, null")
    }
    func testEnumRefusalNeverCopiesWholePayload() {
        let long = String(repeating: "x", count: 400)
        let message = refusal(step, .object([.init("verb", .string(long)), .init("selector", .string("#a"))]))
        XCTAssertLessThan(message.count, 200)
        XCTAssertFalse(message.contains(long))
    }
    func testAllBuiltinsKeepRealNamesSchemasAndTiers() throws {
        let metadata = try BackendDeckCoreCatalogueLiterals.builtins()
        XCTAssertEqual(metadata.map { $0.tool.id }.sorted(), ["alerts.list", "git.diff", "git.status", "log.note", "projects.list", "sessions.get", "sessions.list", "sessions.result", "sessions.send", "sessions.start", "sessions.stop", "sessions.transcript", "settings.read", "settings.write"])
        XCTAssertEqual(metadata.filter { $0.tool.tier == .alter }.map { $0.tool.id }, ["settings.write"])
        for entry in metadata {
            XCTAssertEqual(entry.tool.wireName, entry.tool.id.replacingOccurrences(of: ".", with: "_"))
            XCTAssertEqual(entry.tool.inputSchema["type"], .string("object"))
            XCTAssertEqual(entry.tool.inputSchema["additionalProperties"], .bool(false))
            do { try BackendDeckCoreCatalogueSchema.check(tool: entry.tool, arguments: .object([])) }
            catch { XCTAssertTrue(error is BackendDeckCoreSecurityRefusal) }
            XCTAssertEqual(entry.advertisedValue["inputSchema"], entry.tool.inputSchema)
        }
    }
    func testBudgetMeasuresWirePayloadAndDetectsVerboseContribution() throws {
        let original = try BackendDeckCoreCatalogueLiterals.builtins(), base = BackendDeckCoreCatalogueCost.measure(original)
        XCTAssertFalse(base.overBudget)
        XCTAssertEqual(base.chars, NativeRPCValue.object([.init("tools", .array(original.map(\.advertisedValue)))]).compact.utf16.count)
        let verbose = try original[0].replacingDescription(String(repeating: "This tool does a thing, and here is every consideration. ", count: 540))
        XCTAssertTrue(BackendDeckCoreCatalogueCost.measure(original + [verbose]).overBudget)
        XCTAssertEqual(Rules.estimateTokens(""), 0)
        XCTAssertEqual(Rules.estimateTokens("x"), 1)
        XCTAssertEqual(Rules.estimateTokens("xxxxxxx"), 2)
    }
    func testTextAndNoteBoundsCountUTF16AndRefuseAllTerminalControls() throws {
        XCTAssertEqual(try Rules.sanitizeSendText("テストを実行してください"), "テストを実行してください")
        XCTAssertEqual(try Rules.sanitizeNote(" ملاحظة عن الجلسة "), "ملاحظة عن الجلسة")
        for raw in ["a\nb", "a\rb", "a\tb", "\u{1b}[2J", "\u{03}", "\u{04}", "\u{1a}", "\u{7f}", "a\u{9b}m", "\u{85}a"] {
            XCTAssertThrowsError(try Rules.sanitizeSendText(raw))
            XCTAssertThrowsError(try Rules.sanitizeNote(raw))
        }
        XCTAssertThrowsError(try Rules.sanitizeSendText(""))
        XCTAssertThrowsError(try Rules.sanitizeNote("  \t "))
        XCTAssertThrowsError(try Rules.sanitizeSendText(String(repeating: "😀", count: 2_001)))
        XCTAssertThrowsError(try Rules.sanitizeNote(String(repeating: "x", count: 301)))
        XCTAssertEqual(try Rules.sanitizeSendText(String(repeating: "😀", count: 2_000)).utf16.count, 4_000)
        XCTAssertEqual(try Rules.sanitizeNote("\u{feff}note\u{feff}"), "note")
    }
    func testProtectedNamespacesAndIndividualKeysDoNotPermitPartialWrites() throws {
        for key in ["remote.enabled", "remote.future", "copilot.permissions", "security.anything", "confine.anything", "deckControl.future", "browser.persistSession", "advanced.debugMode"] {
            XCTAssertTrue(Rules.isProtectedSetting(key))
            let args = Rules.object([("scope", .string("settings")), ("patch", Rules.object([("appearance.density", .string("compact")), (key, .bool(true))]))])
            XCTAssertThrowsError(try BackendDeckCoreCatalogueBuiltins.checkSettingsPatch(args))
        }
        XCTAssertFalse(Rules.isProtectedSetting("appearance.remoteLook"))
    }
    func testSettingsReuseSchemaClampAndDistinguishStoresAndReset() throws {
        XCTAssertGreaterThan(SettingsSchema.all.count, 10)
        let valid = BackendDeckCoreCatalogueSettings.check(scope: "settings", patch: try json(#"{"appearance.density":"compact","appearance.terminalFontSize":4000}"#))
        XCTAssertTrue(valid.problems.isEmpty)
        XCTAssertEqual(valid.effective["appearance.terminalFontSize"], .number(24))
        XCTAssertEqual(valid.adjusted, ["appearance.terminalFontSize"])
        let bad = BackendDeckCoreCatalogueSettings.check(scope: "settings", patch: try json(#"{"appearance.density":"none","made.up":1,"general.copyOnSelect":true}"#))
        XCTAssertEqual(bad.problems.map(\.key), ["appearance.density", "made.up"])
        XCTAssertEqual(bad.effective, .object([.init("general.copyOnSelect", .bool(true))]))
        XCTAssertTrue(bad.problemSentence.contains("comfortable, compact"))
        XCTAssertTrue(BackendDeckCoreCatalogueSettings.check(scope: "settings", patch: try json(#"{"appearance.theme":"light"}"#)).problemSentence.contains("scope \"preferences\""))
        XCTAssertTrue(BackendDeckCoreCatalogueSettings.check(scope: "preferences", patch: try json(#"{"theme":"light"}"#)).problems.isEmpty)
        XCTAssertTrue(BackendDeckCoreCatalogueSettings.check(scope: "settings", patch: try json(#"{"appearance.density":null}"#)).problems.isEmpty)
        XCTAssertTrue(BackendDeckCoreCatalogueSettings.check(scope: "preferences", patch: try json(#"{"theme":null}"#)).problemSentence.contains("cannot be set to null"))
    }
    func testRunTargetAcceptsBothArgumentShapesAndRefusesNonObjects() throws {
        let target = try BackendDeckCoreCatalogueRunTarget.parse(try json(#"{"name":" sessions_list ","arguments":"{}"}"#))
        XCTAssertEqual(target.name, "sessions_list")
        XCTAssertEqual(target.arguments, .object([]))
        for args in [#"{}"#, #"{"name":"x","arguments":"{"}"#, #"{"name":"x","arguments":[]}"#, #"{"name":"x","arguments":"false"}"#] {
            XCTAssertThrowsError(try BackendDeckCoreCatalogueRunTarget.parse(json(args)))
        }
        XCTAssertEqual(try BackendDeckCoreCatalogueRunTarget.parse(try json(#"{"name":"x","arguments":null}"#)).arguments, .object([]))
    }
    func testEmptinessIsAlwaysPresentOnPayloadAndSummary() {
        for produced in [-1.0, 0, 1] {
            let value = Rules.withEmptiness(.object([.init("rows", .array([]))]), produced: produced, whenNone: "No matching request arrived; load a page that matches the configured rules.")
            XCTAssertEqual(value["empty"], .bool(produced <= 0))
            XCTAssertEqual(value["emptyReason"].string?.isEmpty, produced > 0)
            XCTAssertEqual(Rules.emptySummary(produced)["empty"], value["empty"])
        }
    }
}
