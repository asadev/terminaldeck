import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Focused WIP checks for TerminalDeckNativeUITests. Fake RPC only: these checks never call
/// start(), EngineBridge, NSApplication, a relay or a real AI.
final class RECEIVERNativeModelTests: XCTestCase {
    private static func requireFocused() throws {
        let env = ProcessInfo.processInfo.environment
        let lanes = (env["TD_WIP"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lanes.contains("RECEIVER") || env["RECEIVER_FOCUSED_UI"] == "1" else {
            throw XCTSkip("WIP RECEIVER: enable RECEIVER_FOCUSED_UI=1 for the fake-only model checks.")
        }
    }
    private struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    private final class Transport {
        struct Call {
            let channel: String
            let arguments: [String: Any]
        }
        var calls: [Call] = []
        var failCreate = false
        var failNextRule = false
        var inspect: ((String) -> Void)?

        func read(_ channel: String, _ args: [Any?]) async throws -> Any {
            let arguments = (args.first ?? nil) as? [String: Any] ?? [:]
            calls.append(.init(channel: channel, arguments: arguments))
            inspect?(channel)
            switch channel {
            case "receiver:sourceCreate":
                if failCreate { throw NativeRPCError(code: "fixture-refused", message: "The fixture refused this source.") }
                return try Self.createdAnswer(Self.view())
            case "receiver:sourceSave":
                guard let value = arguments["source"] else { throw Failure(message: "Source save omitted its source.") }
                let source = try RCVPresentation.decode(RCVSource.self, from: value)
                return try RCVPresentation.foundation(Self.view(source))
            case "receiver:ruleSave":
                if failNextRule {
                    failNextRule = false
                    throw NativeRPCError(code: "fixture-refused", message: "The fixture refused this rule.")
                }
                guard let value = arguments["rule"] else { throw Failure(message: "Rule save omitted its rule.") }
                return try RCVPresentation.foundation(RCVPresentation.decode(RCVRule.self, from: value))
            case "receiver:test":
                let event = RCVEvent(id: "fixture-event", sourceId: Self.view().id, receivedAt: 1, kind: "receiver.test", title: "Fixture test")
                let decision = RCVDecision(status: .delivered, reason: "Fixture rule matched.", target: .init(kind: .hoot))
                return ["decision": try RCVPresentation.foundation(decision), "event": try RCVPresentation.foundation(event)]
            default:
                throw Failure(message: "Unexpected Receiver call: \(channel)")
            }
        }

        static func source(preset: String = "webhook", typeName: String? = nil,
                           origin: RCVOrigin = .relay, projectScope: RCVProjectScope? = nil) -> RCVSource {
            RCVSource(id: "receiver-native-fixture", name: "Fixture sender", preset: preset, origin: origin,
                      auth: RCVPresets.generic.auth, mapping: RCVPresets.generic.mapping,
                      projectScope: projectScope, type: typeName)
        }
        static func view(_ source: RCVSource = Transport.source()) -> RCVSourceView {
            RCVSourceView(source: source, address: "https://example.invalid/in/fixture", active: true,
                          hasReplyCredential: false, lastEventAt: nil, eventCount: 0, rejectedCount: 0)
        }
        static func overview() -> RCVOverview {
            .init(sources: [view()], rules: [], events: [], unrouted: 0, held: 0, relayConnected: true,
                  relayBase: "https://example.invalid", presets: RCVPresets.all)
        }
        static func createdAnswer(_ view: RCVSourceView) throws -> [String: Any] {
            ["source": try RCVPresentation.foundation(view), "reveal": NSNull()]
        }
        func model() -> NativeRCVModel {
            let model = NativeRCVModel(sourceEvents: [], read: { [self] channel, args in try await read(channel, args) })
            model.overview = Self.overview()
            model.loading = false
            return model
        }
    }

    @MainActor
    func testRejectedCreationKeepsTheAddSheetAndError() async throws {
        try Self.requireFocused()
        let transport = Transport()
        transport.failCreate = true
        let model = transport.model()
        model.openSheet(.addSource)
        let before = model.overview
        let created = await model.createSource(preset: RCVPresets.generic, name: "  Fixture sender  ", auth: nil)
        XCTAssertNil(created)
        XCTAssertEqual(model.sheet?.id, "add-source")
        XCTAssertEqual(model.actionError, "The fixture refused this source.")
        XCTAssertNil(model.busy)
        XCTAssertEqual(model.overview, before, "A rejected source must not appear in the source list.")
        XCTAssertEqual(transport.calls.map(\.channel), ["receiver:sourceCreate"])
        let call = try XCTUnwrap(transport.calls.first)
        XCTAssertEqual(call.arguments["name"] as? String, "Fixture sender")
    }

    @MainActor
    func testConfigureRetriesOneSourceAndStableRuleWithTheSelectedProjectAndTarget() async throws {
        try Self.requireFocused()
        let targets: [RCVTarget] = [.init(kind: .hoot), .init(kind: .agent, id: "fixture-agent"),
                                    .init(kind: .session, id: "fixture-session"), .init(kind: .newTask, id: "fixture-agent")]
        for target in targets {
            let transport = Transport()
            transport.failNextRule = true
            let model = transport.model()
            let created = try RCVPresentation.decode(RCVPresentation.Created.self, from: Transport.createdAnswer(Transport.view()))
            let first = await model.configureCreated(created, type: .code, projectID: "fixture-project", target: target)
            XCTAssertNil(first)
            XCTAssertEqual(model.actionError, "The fixture refused this rule.")
            let second = await model.configureCreated(created, type: .code, projectID: "fixture-project", target: target)
            XCTAssertEqual(second?.source.source.projectID, "fixture-project")
            XCTAssertEqual(second?.source.address, created.source.address)
            XCTAssertNil(model.actionError)
            XCTAssertNil(model.busy)
            XCTAssertEqual(transport.calls.map(\.channel), ["receiver:sourceSave", "receiver:ruleSave", "receiver:sourceSave", "receiver:ruleSave"])
            let sourceCalls = try transport.calls.filter { $0.channel == "receiver:sourceSave" }.map {
                try RCVPresentation.decode(RCVSource.self, from: XCTUnwrap($0.arguments["source"]))
            }
            XCTAssertEqual(sourceCalls.count, 2)
            XCTAssertTrue(sourceCalls.allSatisfy { $0.id == created.source.id && $0.projectID == "fixture-project" })
            let rules = try transport.calls.filter { $0.channel == "receiver:ruleSave" }.map {
                try RCVPresentation.decode(RCVRule.self, from: XCTUnwrap($0.arguments["rule"]))
            }
            XCTAssertEqual(rules.count, 2)
            XCTAssertEqual(Set(rules.map(\.id)), ["source-default-" + created.source.id])
            XCTAssertTrue(rules.allSatisfy { $0.sourceIds == [created.source.id] && $0.target == target })
            XCTAssertEqual(model.rules.count, 1, "Retry replaces the same rule instead of appending another one.")
        }
    }

    @MainActor
    func testEverySourceTestUsesOnlyTheExistingDryRunChannel() async throws {
        try Self.requireFocused()
        for type in NativeRCVSourceType.allCases {
            let transport = Transport(), model = transport.model()
            let view = Transport.view(Transport.source(preset: type.presetID, typeName: type.rawValue))
            let before = model.overview
            await model.testSource(view)
            XCTAssertEqual(transport.calls.map(\.channel), ["receiver:test"], type.rawValue)
            let arguments = try XCTUnwrap(transport.calls.first).arguments
            XCTAssertEqual(arguments["sourceId"] as? String, view.id, type.rawValue)
            XCTAssertNil(arguments["rule"], "Use the source's saved rules.")
            XCTAssertNil(arguments["eventId"])
            let sample = try XCTUnwrap(arguments["sample"] as? String)
            XCTAssertTrue(try JSONSerialization.jsonObject(with: Data(sample.utf8)) is [String: Any], type.rawValue)
            XCTAssertTrue(model.actionNote?.contains("Test only.") == true, type.rawValue)
            XCTAssertNil(model.busy)
            XCTAssertEqual(model.overview, before, "Dry runs must not add a received event or mutate the source list.")
        }
    }

    @MainActor
    func testSourceWindowActionAndSheetStateAreIsolatedWithTheSameFakeTransport() async throws {
        try Self.requireFocused()
        let transport = Transport(), page = transport.model()
        page.busy = "page-pending"
        page.actionError = "page-error"
        page.sheet = .addSource
        page.projects = [.init(id: "fixture-project", name: "Fixture project")]
        let child = page.sourceWindowModel()
        XCTAssertFalse(child === page)
        XCTAssertNil(child.busy)
        XCTAssertNil(child.sheet)
        XCTAssertNil(child.actionError)
        XCTAssertEqual(child.projects, page.projects)
        var sawIndependentPending = false
        transport.inspect = { channel in
            if channel == "receiver:sourceSave" { sawIndependentPending = child.busy == "save-source" && page.busy == "page-pending" }
        }
        var changed = Transport.source()
        changed.name = "Edited in source window"
        let saved = await child.saveSource(changed)
        XCTAssertTrue(saved)
        XCTAssertTrue(sawIndependentPending)
        XCTAssertEqual(page.sources.first?.source.name, "Fixture sender")
        XCTAssertEqual(child.sources.first?.source.name, "Edited in source window")
        child.openSheet(.rule(.init(name: "Fixture rule"), isNew: true))
        XCTAssertEqual(page.sheet?.id, "add-source")
        XCTAssertTrue(child.sheet?.id.hasPrefix("rule:") == true)
        XCTAssertEqual(page.actionError, "page-error")
        XCTAssertNil(child.actionError)
        XCTAssertEqual(transport.calls.map(\.channel), ["receiver:sourceSave"])
        let builtin = Transport.source(origin: .terminalDeck, projectScope: .all)
        XCTAssertEqual(builtin.effectiveProjectScope, .all)
        XCTAssertNil(builtin.projectId, "All projects is distinct from Independent.")
        var narrowed = builtin
        narrowed.projectScope = .project
        narrowed.projectID = "independent"
        XCTAssertEqual(narrowed.effectiveProjectScope, .project)
        XCTAssertEqual(narrowed.projectId, "independent")
    }

    @MainActor
    func testAllNineTypesAndPasteInstructionsUseGenericNamesAndKeepLegacyMappings() throws {
        try Self.requireFocused()
        let expected = ["Webhook (any JSON)", "WhatsApp gateway", "Code host", "Error tracker", "CRM", "Uptime monitor", "Server alert", "Chat app", "Container host"]
        XCTAssertEqual(NativeRCVSourceType.allCases.map(\.rawValue), expected)
        XCTAssertEqual(Set(NativeRCVSourceType.allCases.map(\.presetID)).count, 9)
        for type in NativeRCVSourceType.allCases {
            XCTAssertEqual(NativeRCVSourceType.of(Transport.source(preset: type.presetID)), type)
            XCTAssertEqual(NativeRCVSourceType.of(Transport.source(preset: "webhook", typeName: type.rawValue)), type,
                           "The persisted generic type takes precedence over the original preset.")
            let preset = type.preset(in: RCVPresets.all)
            let words = (preset.name + " " + preset.help).lowercased()
            XCTAssertEqual(preset.name, type.rawValue)
            XCTAssertFalse(["whapi", "sentry", "github"].contains(where: words.contains), type.rawValue)
        }
        for (type, legacy) in [(NativeRCVSourceType.whatsapp, RCVPresets.whapi), (.code, RCVPresets.github), (.errors, RCVPresets.sentry)] {
            let displayed = type.preset(in: RCVPresets.all)
            XCTAssertEqual(displayed.id, legacy.id)
            XCTAssertEqual(displayed.auth, legacy.auth)
            XCTAssertEqual(displayed.mapping, legacy.mapping)
        }
    }

    @MainActor
    func testProjectRuleProjectionKeepsOwnedGlobalAndAllScopeRulesInSavedOrder() throws {
        try Self.requireFocused()
        func source(_ id: String, project: String, all: Bool = false) -> RCVSourceView {
            var value = Transport.source(origin: all ? .terminalDeck : .relay, projectScope: all ? .all : .project)
            value.id = id
            if !all { value.projectID = project }
            return Transport.view(value)
        }
        var explicitCRM = RCVRule(id: "explicit-crm", name: "CRM-owned rule", sourceIds: ["imatch-source"])
        explicitCRM.projectId = "crm"
        var explicitIMatch = RCVRule(id: "explicit-imatch", name: "iMatch-owned rule", sourceIds: ["crm-source"])
        explicitIMatch.projectId = "imatch"
        let saved = [
            RCVRule(id: "crm-inferred", name: "CRM source rule", sourceIds: ["crm-source"]),
            RCVRule(id: "global", name: "Any source rule"),
            RCVRule(id: "imatch-inferred", name: "iMatch source rule", sourceIds: ["imatch-source"]),
            explicitCRM,
            RCVRule(id: "all-scope", name: "Built-in every-project rule", sourceIds: ["terminaldeck.tasks"]),
            RCVRule(id: "independent", name: "Independent source rule", sourceIds: ["independent-source"]),
            explicitIMatch,
            RCVRule(id: "orphan", name: "Unavailable source rule", sourceIds: ["missing-source"])
        ]
        let model = NativeRCVModel(sourceEvents: [], read: { channel, _ in
            XCTFail("Rule projection must not read the engine: " + channel)
            throw Failure(message: "Unexpected rule projection call.")
        })
        model.overview = .init(sources: [source("imatch-source", project: "imatch"), source("crm-source", project: "crm"),
            source("independent-source", project: "independent"), source("terminaldeck.tasks", project: "", all: true)],
            rules: saved, events: [], unrouted: 0, held: 0, relayConnected: false, relayBase: nil, presets: RCVPresets.all)
        model.loading = false
        defer { model.stop() }
        XCTAssertEqual(model.visibleRules.map(\.id), saved.map(\.id))
        for (project, expected) in [
            ("imatch", ["global", "imatch-inferred", "all-scope", "explicit-imatch"]),
            ("crm", ["crm-inferred", "global", "explicit-crm", "all-scope"]),
            ("independent", ["global", "all-scope", "independent"]),
            ("missing-project", ["global", "all-scope"])
        ] {
            model.projectFilter = project
            XCTAssertEqual(model.visibleRules.map(\.id), expected, project)
            XCTAssertEqual(model.rules, saved, "Filtering must not change the order used by ruleMove.")
        }
        model.projectFilter = nil
        XCTAssertEqual(model.visibleRules, saved)
    }

    @MainActor
    func testQuietSourceSearchShowsRejectedLogRowsKeepsLearnSafeAndReportsFailure() async throws {
        try Self.requireFocused()
        var quiet = Transport.source(); quiet.id = "quiet-source"
        var noisy = Transport.source(); noisy.id = "noisy-source"
        var accepted = RCVEvent(id: "quiet-accepted", sourceId: quiet.id, receivedAt: 10, kind: "message", title: "Accepted")
        accepted.status = .delivered
        var rejected = RCVEvent(id: "quiet-rejected", sourceId: quiet.id, receivedAt: 20, kind: "message", title: "Refused")
        rejected.status = .rejected
        var ignored = RCVEvent(id: "quiet-ignored", sourceId: quiet.id, receivedAt: 30, kind: "message", title: "Ignored echo")
        ignored.status = .ignored
        let other = RCVEvent(id: "noisy-only", sourceId: noisy.id, receivedAt: 40, kind: "message", title: "Another source")
        let answer = try RCVPresentation.foundation([accepted, rejected, ignored, other])
        var fail = false
        var calls: [[String: Any]] = []
        let page = NativeRCVModel(sourceEvents: [], read: { channel, args in
            guard channel == "receiver:events" else {
                XCTFail("Unexpected source search call: " + channel)
                throw Failure(message: "Unexpected source search call.")
            }
            calls.append((args.first ?? nil) as? [String: Any] ?? [:])
            if fail { throw Failure(message: "The fixture could not read these events.") }
            return answer
        })
        page.overview = .init(sources: [Transport.view(quiet), Transport.view(noisy)], rules: [], events: [other],
            unrouted: 1, held: 0, relayConnected: false, relayBase: nil, presets: RCVPresets.all)
        page.loading = false
        let model = page.sourceWindowModel(sourceID: quiet.id)
        defer { model.stop(); page.stop() }
        XCTAssertNil(model.searched)
        XCTAssertEqual(model.eventsForSource(quiet.id), [])
        model.search()
        XCTAssertTrue(model.searchLoading)
        let clock = ContinuousClock()
        func waitFor(_ ready: @MainActor () -> Bool) async throws {
            let deadline = clock.now.advanced(by: .seconds(3))
            while clock.now < deadline {
                if ready() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw Failure(message: "The fixture source search did not settle within three seconds.")
        }
        try await waitFor { !model.searchLoading && model.searched != nil }
        XCTAssertEqual(model.eventsForSource(quiet.id).map(\.id), ["quiet-ignored", "quiet-rejected", "quiet-accepted"])
        XCTAssertEqual(model.eventsForSource(quiet.id, includeRejected: false).map(\.id), ["quiet-ignored", "quiet-accepted"])
        XCTAssertEqual(model.recentEvents(of: [quiet.id]).map(\.id), ["quiet-ignored", "quiet-accepted"],
                       "Learn keeps ignored/accepted rows but never learns a refused payload.")
        XCTAssertEqual(model.overview?.events, [other], "Source history must not replace the global recent overview.")
        XCTAssertNil(page.searched, "The isolated source window must not change the page search.")
        XCTAssertNil(model.searchError)
        fail = true
        model.search()
        try await waitFor { !model.searchLoading && model.searchError != nil }
        XCTAssertEqual(model.searchError, "The fixture could not read these events.")
        XCTAssertNil(model.searched)
        XCTAssertEqual(model.eventsForSource(quiet.id), [])
        XCTAssertNil(page.searchError)
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0["sourceId"] as? String == quiet.id && $0["status"] == nil })
    }
}
