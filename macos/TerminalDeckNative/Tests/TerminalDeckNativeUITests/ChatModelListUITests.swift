import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// 28 Oct (Asad: "no other models in the list"): a chat's model menu lists the account's whole live list in one
/// section, ticks the 1M choice a chat started on "opus[1m]" runs with, and keeps it when the CLI reports its model.
private enum ChatModelListFixture {
    private static func row(_ id: String, _ name: String) -> NativeRPCValue {
        .object([.init("id", .string(id)), .init("name", .string(name))])
    }
    /// The box's choices as the app now answers for a chat on "opus[1m]" (see ChatModelListTests for how they are made).
    static let options: NativeRPCValue = .object([.init("ready", .bool(true)), .init("permissionMode", .string("bypass")),
        .init("model", .string("claude:opus[1m]")), .init("effort", .string("xhigh")),
        .init("efforts", .array(["low", "medium", "high", "xhigh", "max"].map(NativeRPCValue.string))),
        .init("catalog", .object([.init("claude", .object([
            .init("models", .array([row("claude-opus-5-5", "Opus 5.5"), row("claude-sonnet-5", "Sonnet 5"), row("claude-haiku-4-5", "Haiku 4.5"),
                                    row("claude-opus-4-1", "Opus 4.1"), row("claude-opus-5-5[1m]", "Opus 5.5 1M"), row("claude-sonnet-5[1m]", "Sonnet 5 1M")])),
            .init("featured", .array(["claude-opus-5-5", "claude-opus-5-5[1m]", "claude-sonnet-5", "claude-sonnet-5[1m]", "claude-haiku-4-5"].map(NativeRPCValue.string))),
            .init("more", .array([.string("claude-opus-4-1")]))]))])),
        .init("models", .array([.object([.init("id", .string("claude:opus[1m]")), .init("provider", .string("Claude Code")), .init("name", .string("Opus 1M"))])]))])
    static func chat(sequence: Double = 0, model: String? = nil) -> NativeRPCValue {
        var value = NativeRPCValue.object([.init("conversationId", .string("model-list-fixture")), .init("sequence", .number(sequence)),
            .init("events", .array([])), .init("alive", .bool(true)), .init("busy", .bool(false)), .init("options", options)])
        if let model { value = value.setting("model", .string(model)).setting("provider", .string("claude")) }
        return value
    }
    /// The same box on this Mac's own Claude Code sign-in: Claude Code's own choices (aliases, each meaning a model).
    static func cliRow(_ id: String, _ name: String, _ means: String) -> NativeRPCValue {
        .object([.init("id", .string(id)), .init("name", .string(name)), .init("resolvedModel", .string(means))])
    }
    static let cliOptions: NativeRPCValue = options.setting("catalog", .object([.init("claude", .object([
        .init("models", .array([cliRow("opus", "Opus", "claude-opus-5-5"), cliRow("haiku", "Haiku", "claude-haiku-5-5"),
                                cliRow("opus[1m]", "Opus 1M", "claude-opus-5-5[1m]")])),
        .init("featured", .array(["opus", "opus[1m]", "haiku"].map(NativeRPCValue.string))), .init("more", .array([])),
        .init("source", .string("cli"))]))]))
    static func cliChat(sequence: Double = 0, model: String? = nil) -> NativeRPCValue {
        chat(sequence: sequence, model: model).setting("options", cliOptions)
    }
}

@MainActor final class ChatModelListUITests: XCTestCase {
    private typealias Fixture = ChatModelListFixture
    func testTheMenuListsEveryModelAndTicksTheOneMillionChoiceInUse() async throws {
        let model = NativeHootChatModel(fixture: Fixture.chat(), optionsInvoke: { _, _ in ChatModelListFixture.options.foundation ?? [:] },
                                        source: .session("fixture-session", provider: "claude"))
        let section = try XCTUnwrap(model.catalogue.sections.first)
        XCTAssertEqual(model.catalogue.sections.map(\.name), ["Claude Code"])
        XCTAssertEqual(section.featured.map(\.name), ["Opus 5.5", "Opus 5.5 1M", "Sonnet 5", "Sonnet 5 1M", "Haiku 4.5"])
        XCTAssertEqual(section.more.map(\.name), ["Opus 4.1"])
        let million = try XCTUnwrap(section.featured.first { $0.id == "claude:claude-opus-5-5[1m]" })
        XCTAssertTrue(model.catalogue.isChosen(million, savedID: model.composerDraft.modelID), "opus[1m] ticks Opus 5.5 1M")
        XCTAssertFalse(model.catalogue.isChosen(section.featured[0], savedID: model.composerDraft.modelID))
        // The CLI reports the model without "[1m]": the 1M choice stays ticked.
        model.acceptFixtureUpdate(Fixture.chat(sequence: 1, model: "claude-opus-5-5"))
        XCTAssertEqual(model.composerDraft.modelID, "claude:claude-opus-5-5[1m]")
        XCTAssertTrue(model.catalogue.isChosen(million, savedID: model.composerDraft.modelID))
        XCTAssertEqual(model.composerDraft.effort, "xhigh", "effort stays its own choice")
        XCTAssertFalse(EngineBridge.shared.isReady)
    }

    func testOnThisMacsOwnSignInTheMenuListsClaudeCodesOwnChoices() async throws {
        let model = NativeHootChatModel(fixture: Fixture.cliChat(), optionsInvoke: { _, _ in ChatModelListFixture.cliOptions.foundation ?? [:] },
                                        source: .session("fixture-session", provider: "claude"))
        let section = try XCTUnwrap(model.catalogue.sections.first)
        XCTAssertEqual(section.featured.map(\.name), ["Opus", "Opus 1M", "Haiku"])
        let million = try XCTUnwrap(section.featured.first { $0.id == "claude:opus[1m]" })
        XCTAssertTrue(model.catalogue.isChosen(million, savedID: model.composerDraft.modelID))
        // The CLI reports "claude-opus-5-5": still the Opus 1M choice, by what it means.
        model.acceptFixtureUpdate(Fixture.cliChat(sequence: 1, model: "claude-opus-5-5"))
        XCTAssertTrue(model.catalogue.isChosen(million, savedID: model.composerDraft.modelID), "ticked: \(model.composerDraft.modelID)")
        XCTAssertFalse(model.catalogue.isChosen(section.featured[0], savedID: model.composerDraft.modelID))
        XCTAssertFalse(EngineBridge.shared.isReady)
    }
}
