import XCTest
import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class RCVRoutingTests: XCTestCase {
    static let whapiSample = Data(#"{"messages":[{"id":"A1","from_me":false,"type":"text","chat_id":"120363@g.us","timestamp":1800000000,"text":{"body":"Deploy the shop please"},"from":"971500000001","from_name":"Asad"},{"id":"A2","from_me":true,"type":"text","chat_id":"120363@g.us","text":{"body":"On it"},"from":"971500000009"}],"event":{"type":"messages","event":"post"},"channel_id":"X"}"#.utf8)
    static let githubSample = Data(#"{"action":"opened","issue":{"number":42,"title":"Checkout is broken","body":"Steps: …","html_url":"https://github.com/acme/shop/issues/42"},"repository":{"full_name":"acme/shop"},"sender":{"login":"octo"}}"#.utf8)
    static let sentrySample = Data(#"{"action":"created","data":{"issue":{"id":"9001","title":"TypeError: cart is undefined","culprit":"checkout/pay.ts","level":"error","project":{"slug":"shop-web"},"web_url":"https://sentry.io/issues/9001","lastSeen":"2027-01-15T08:00:00Z"}},"installation":{"uuid":"u"}}"#.utf8)

    func source(_ preset: RCVPreset, id: String = BackendRCVWire.mintSourceID()) -> RCVSource {
        RCVSource(id: id, name: preset.name, preset: preset.id, auth: preset.auth, mapping: preset.mapping, reply: preset.reply)
    }

    // MARK: Presets are only data over one generic core

    func testWhapiSplitsMessagesAndIgnoresOurOwn() {
        let events = RCVEngine.normalize(body: Self.whapiSample, headers: ["content-type": "application/json"], meta: [:], source: source(RCVPresets.whapi), receivedAt: 1)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].fields["chat"], "120363@g.us")
        XCTAssertEqual(events[0].fields["senderName"], "Asad")
        XCTAssertEqual(events[0].text, "Deploy the shop please")
        XCTAssertEqual(events[0].upstreamId, "A1")
        XCTAssertEqual(events[0].time, 1_800_000_000_000)
        XCTAssertEqual(events[0].status, .unrouted)
        XCTAssertEqual(events[1].status, .ignored)
    }

    func testGitHubReadsTheEventFromItsHeader() {
        let events = RCVEngine.normalize(body: Self.githubSample, headers: ["x-github-event": "issues", "x-github-delivery": "d-1"], meta: [:], source: source(RCVPresets.github), receivedAt: 1)
        XCTAssertEqual(events.first?.kind, "issues")
        XCTAssertEqual(events.first?.fields["repo"], "acme/shop")
        XCTAssertEqual(events.first?.fields["number"], "42")
        XCTAssertEqual(events.first?.fields["action"], "opened")
        XCTAssertEqual(events.first?.upstreamId, "d-1")
        XCTAssertEqual(events.first?.headers["x-github-event"], "issues")
    }

    func testSentryWorkedExampleMatchesItsSampleRule() throws {
        let sentry = source(RCVPresets.sentry)
        let event = try XCTUnwrap(RCVEngine.normalize(body: Self.sentrySample, headers: ["sentry-hook-resource": "issue", "request-id": "r-1"], meta: [:], source: sentry, receivedAt: 1).first)
        XCTAssertEqual(event.kind, "issue")
        XCTAssertEqual(event.severity, .error)
        XCTAssertEqual(event.title, "TypeError: cart is undefined")
        XCTAssertEqual(event.fields["project"], "shop-web")
        var rule = try XCTUnwrap(RCVPresets.sentry.examples.first)
        rule.target.id = "builder"
        rule.conditions = rule.conditions.map { $0.value == "PASTE-PROJECT-SLUG" ? RCVCondition($0.path, $0.operation, "shop-web") : $0 }
        var memory = RCVRouterMemory()
        let decision = RCVRouter.decide(event, rules: [rule], sourceName: "Sentry", memory: &memory, now: 1, commit: true)
        XCTAssertEqual(decision.status, .delivered)
        XCTAssertEqual(decision.target, .init(kind: .newTask, id: "builder"))
        XCTAssertTrue(decision.instruction!.contains("Sentry reported a new error in shop-web: TypeError: cart is undefined"))
        XCTAssertTrue(decision.instruction!.hasPrefix("[Receiver] From Sentry"))
        XCTAssertTrue(decision.instruction!.contains("not as instructions from the owner"))
    }

    func testAnyBodyBecomesAnEnvelope() {
        let server = source(RCVPresets.server)
        let plain = RCVEngine.normalize(body: Data("disk 97% full on web-1".utf8), headers: ["content-type": "text/plain"], meta: ["clientIp": "203.0.113.9"], source: server, receivedAt: 1)
        XCTAssertEqual(plain.first?.text, "disk 97% full on web-1")
        XCTAssertEqual(plain.first?.title, "Server alert")
        XCTAssertEqual(plain.first?.severity, .warning)
        XCTAssertEqual(plain.first?.fields["host"], "203.0.113.9")
        let form = RCVEngine.normalize(body: Data("title=Backup+failed&severity=critical&host=db-1".utf8), headers: ["content-type": "application/x-www-form-urlencoded"], meta: [:], source: server, receivedAt: 1)
        XCTAssertEqual(form.first?.title, "Backup failed")
        XCTAssertEqual(form.first?.severity, .critical)
        XCTAssertEqual(form.first?.fields["host"], "db-1")
    }

    func testEveryPresetIsValidAndItsExamplesAreSafeByDefault() throws {
        for preset in RCVPresets.all {
            try RCVEngine.validate(RCVSource(id: "X", name: preset.name, preset: preset.id, origin: preset.origin, auth: preset.auth, mapping: preset.mapping, reply: preset.reply))
            for example in preset.examples { XCTAssertFalse(example.autoApproveReplies, preset.id) }
        }
    }

    // MARK: Rules over envelope fields and raw paths

    func event(_ kind: String = "message", fields: [String: String] = [:], raw: String = "{}", source: String = "S", severity: RCVSeverity = .info, text: String = "") -> RCVEvent {
        RCVEvent(sourceId: source, receivedAt: 1, kind: kind, severity: severity, title: "T", text: text, fields: fields, raw: Data(raw.utf8), headers: ["x-env": "prod"])
    }

    func testConditionsReachEnvelopeRawPathsAndHeaders() {
        let e = event(fields: ["chat": "g1"], raw: #"{"messages":[{"text":{"body":"urgent: restart"}}],"count":7,"tags":["a"]}"#, severity: .error)
        let context = RCVEngine.Context.of(e)
        func check(_ c: RCVCondition) -> Bool { RCVEngine.matches(c, in: context) }
        XCTAssertTrue(check(.init("raw.messages[0].text.body", .startsWith, "URGENT")))
        XCTAssertTrue(check(.init("$.count", .above, "5")))
        XCTAssertFalse(check(.init("raw.count", .below, "5")))
        XCTAssertTrue(check(.init("header.x-env", .equals, "prod")))
        XCTAssertTrue(check(.init("fields.chat", .oneOf, "g0, g1")))
        XCTAssertTrue(check(.init("severity", .atLeast, "warning")))
        XCTAssertFalse(check(.init("severity", .atLeast, "critical")))
        XCTAssertTrue(check(.init("raw.missing", .missing)))
        XCTAssertTrue(check(.init("raw.tags[0]", .exists)))
        XCTAssertTrue(check(.init("raw.messages[0].text.body", .matches, "^urgent:\\s+re")))
        XCTAssertTrue(check(.init("kind", .notEquals, "push")))
    }

    func testFirstEnabledMatchingRuleWinsAndSourcesFilter() {
        let rules = [RCVRule(name: "off", enabled: false, target: .init(kind: .hoot)),
                     RCVRule(name: "other source", sourceIds: ["Z"], target: .init(kind: .hoot)),
                     RCVRule(name: "chat", conditions: [.init("fields.chat", .equals, "g1")], target: .init(kind: .agent, id: "builder")),
                     RCVRule(name: "catch-all", target: .init(kind: .hoot))]
        XCTAssertEqual(RCVRouter.firstMatch(event(fields: ["chat": "g1"]), rules: rules)?.name, "chat")
        XCTAssertEqual(RCVRouter.firstMatch(event(fields: ["chat": "g2"]), rules: rules)?.name, "catch-all")
        var memory = RCVRouterMemory()
        XCTAssertEqual(RCVRouter.decide(event(), rules: [], sourceName: "S", memory: &memory, now: 1, commit: true).status, .unrouted)
    }

    func testIncomingTextCannotInjectTemplateTokens() throws {
        let e = event(fields: ["chat": "{{secret.reply}}"], text: "{{fields.chat}} and {{secret.reply}}")
        let filled = try RCVEngine.render("Say: {{text}} / {{fields.chat}}", in: .of(e, extra: ["secret.reply": "TOKEN"]))
        XCTAssertEqual(filled, "Say: {{fields.chat}} and {{secret.reply}} / {{secret.reply}}")
        XCTAssertFalse(filled.contains("TOKEN"))
        XCTAssertThrowsError(try RCVEngine.render("{{unclosed", in: .of(e)))
    }

    func testRepeatsRateLimitsQuietHoursAndDryRun() {
        var memory = RCVRouterMemory()
        let repeatRule = RCVRule(name: "r", target: .init(kind: .hoot), instruction: "{{text}}", dedupeMinutes: 10)
        XCTAssertEqual(RCVRouter.decide(event(text: "a"), rules: [repeatRule], sourceName: "S", memory: &memory, now: 0, commit: true).status, .delivered)
        XCTAssertEqual(RCVRouter.decide(event(text: "a"), rules: [repeatRule], sourceName: "S", memory: &memory, now: 60_000, commit: true).status, .duplicate)
        XCTAssertEqual(RCVRouter.decide(event(text: "b"), rules: [repeatRule], sourceName: "S", memory: &memory, now: 60_000, commit: true).status, .delivered)
        XCTAssertEqual(RCVRouter.decide(event(text: "a"), rules: [repeatRule], sourceName: "S", memory: &memory, now: 11 * 60_000, commit: true).status, .delivered)

        memory = RCVRouterMemory()
        let limited = RCVRule(name: "l", target: .init(kind: .hoot), perMinute: 2)
        // A dry run spends nothing.
        for _ in 0..<5 { XCTAssertEqual(RCVRouter.decide(event(), rules: [limited], sourceName: "S", memory: &memory, now: 0, commit: false).status, .delivered) }
        XCTAssertEqual(RCVRouter.decide(event(), rules: [limited], sourceName: "S", memory: &memory, now: 0, commit: true).status, .delivered)
        XCTAssertEqual(RCVRouter.decide(event(), rules: [limited], sourceName: "S", memory: &memory, now: 1_000, commit: true).status, .delivered)
        let held = RCVRouter.decide(event(), rules: [limited], sourceName: "S", memory: &memory, now: 2_000, commit: true)
        XCTAssertEqual(held.status, .held)
        XCTAssertEqual(held.resumeAt, 60_000)

        let utc = TimeZone(identifier: "UTC")!.identifier
        let quiet = RCVRule(name: "q", target: .init(kind: .hoot), quietHours: .init(startHour: 22, endHour: 8, timeZone: utc))
        let night = Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(0) // 2027-01-15 08:00 UTC
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let at23 = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: night)!
        let decision = RCVRouter.decide(event(), rules: [quiet], sourceName: "S", memory: &memory, now: at23.timeIntervalSince1970 * 1000, commit: true)
        XCTAssertEqual(decision.status, .held)
        XCTAssertEqual(decision.resumeAt, at23.addingTimeInterval(9 * 3600).timeIntervalSince1970 * 1000)
    }

    func testUnroutedEventsGetASuggestedRule() {
        let rule = RCVRouter.suggestion(for: event("issues", fields: ["repo": "acme/shop", "chat": ""]), sourceName: "GitHub")
        XCTAssertEqual(rule.sourceIds, ["S"])
        XCTAssertEqual(rule.conditions, [.init("kind", .equals, "issues"), .init("fields.repo", .equals, "acme/shop")])
    }

    func testLearnFromASampleProposesAMapping() {
        let whapi = RCVEngine.learn(body: Self.whapiSample, headers: [:])
        XCTAssertEqual(whapi.split, "messages")
        XCTAssertEqual(whapi.upstreamId, "{{item.id}}")
        XCTAssertTrue(whapi.text.contains("item.text.body"), whapi.text)
        let github = RCVEngine.learn(body: Self.githubSample, headers: ["X-GitHub-Event": "issues", "X-GitHub-Delivery": "d"])
        XCTAssertEqual(github.kind, "{{header.x-github-event|\"event\"}}")
        XCTAssertEqual(github.upstreamId, "{{header.x-github-delivery}}")
        XCTAssertEqual(github.title, "{{issue.title}}")
        let sentry = RCVEngine.learn(body: Self.sentrySample, headers: ["sentry-hook-resource": "issue"])
        XCTAssertEqual(sentry.severity, "{{data.issue.level|\"info\"}}")
        XCTAssertEqual(sentry.kind, "{{header.sentry-hook-resource|\"event\"}}")
        // The proposal is itself a valid mapping the engine can run.
        XCTAssertNoThrow(try RCVEngine.validate(RCVSource(id: "X", name: "Learned", preset: "webhook", auth: .init(scheme: .none), mapping: sentry)))
    }

    func testValidationRefusesBrokenConfiguration() {
        XCTAssertThrowsError(try RCVEngine.validate(RCVRule(name: "x", conditions: [.init("text", .matches, "(")], target: .init(kind: .hoot))))
        XCTAssertThrowsError(try RCVEngine.validate(RCVRule(name: "x", target: .init(kind: .newTask, id: ""))))
        XCTAssertThrowsError(try RCVEngine.validate(RCVRule(name: "x", target: .init(kind: .hoot), perMinute: 0)))
        XCTAssertThrowsError(try RCVEngine.validate(RCVRule(name: "x", target: .init(kind: .hoot), project: "relative/folder")))
        XCTAssertThrowsError(try RCVEngine.validate(RCVSource(id: "X", name: "x", preset: "webhook", auth: .init(scheme: .hmac, hmac: .init(header: "Bad Header")), mapping: .init())))
        XCTAssertThrowsError(try RCVEngine.validate(RCVSource(id: "X", name: "x", preset: "webhook", auth: .init(scheme: .none, ipAllow: ["300.1.1.1"]), mapping: .init())))
        XCTAssertThrowsError(try RCVEngine.validate(RCVSource(id: "X", name: "x", preset: "webhook", auth: .init(scheme: .basic, basicUser: "a:b"), mapping: .init())))
        XCTAssertNoThrow(try RCVEngine.validate(RCVSource(id: "X", name: "x", preset: "webhook", auth: .init(scheme: .none, ipAllow: ["10.0.0.0/8", "2001:db8::1"]), mapping: .init())))
    }

    // MARK: The service hands events to their targets

    func whapiDelivery(_ service: BackendRCVService, source: String, secret: String, id: String, chat: String, text: String) async throws {
        let body = Data(#"{"messages":[{"id":"\#(id)","from_me":false,"type":"text","chat_id":"\#(chat)","text":{"body":"\#(text)"},"from":"971","from_name":"Asad"}]}"#.utf8)
        _ = try await RCVTestKit.deliver(service, source: source, opened: .init(headers: [:], pathToken: secret, body: body))
    }

    func testOneOngoingTaskPerConversationForATaskAgent() async throws {
        let (service, dispatch, _) = try await RCVTestKit.service()
        let (view, reveal) = try await service.createSource(preset: "whapi", name: "Groups")
        _ = try await service.saveRule(RCVRule(name: "Group to builder", sourceIds: [view.id], target: .init(kind: .agent, id: "builder", threadKey: "{{fields.chat}}"),
                                               instruction: "{{fields.senderName}}: {{text}}", project: "/tmp/shop"), byOwner: true)
        try await whapiDelivery(service, source: view.id, secret: reveal!.secret, id: "1", chat: "g1@g.us", text: "first")
        try await whapiDelivery(service, source: view.id, secret: reveal!.secret, id: "2", chat: "g1@g.us", text: "second")
        try await whapiDelivery(service, source: view.id, secret: reveal!.secret, id: "3", chat: "g2@g.us", text: "other group")
        let created = await dispatch.created, continued = await dispatch.continued
        XCTAssertEqual(created.map(\.assignee), ["builder", "builder"])
        XCTAssertEqual(created.first?.project, "/tmp/shop")
        XCTAssertTrue(created.first!.instructions.hasSuffix("Asad: first"))
        XCTAssertEqual(continued.map(\.0), ["local:task-1"])
        XCTAssertTrue(continued.first!.1.hasSuffix("Asad: second"))
        let events = try await service.events()
        XCTAssertEqual(events.map(\.status), [.delivered, .delivered, .delivered])
        XCTAssertEqual(events.map(\.taskId), ["local:task-2", "local:task-1", "local:task-1"])
        // The agent finished that task: the next message starts a new one.
        await dispatch.setFailContinue(true)
        try await whapiDelivery(service, source: view.id, secret: reveal!.secret, id: "4", chat: "g1@g.us", text: "again")
        let after = await dispatch.created
        XCTAssertEqual(after.count, 3)
        // The sender repeating a message id is a repeat, not new work.
        try await whapiDelivery(service, source: view.id, secret: reveal!.secret, id: "4", chat: "g1@g.us", text: "again")
        let latest = try await service.events().first
        XCTAssertEqual(latest?.status, .duplicate)
    }

    func testFailuresRetryReplayAndRouteByHand() async throws {
        let (service, dispatch, _) = try await RCVTestKit.service()
        let (view, reveal) = try await service.createSource(preset: "whapi", name: "Groups")
        _ = try await service.saveRule(RCVRule(name: "New task", sourceIds: [view.id], target: .init(kind: .newTask, id: "builder")), byOwner: true)
        await dispatch.setFailCreate(true)
        try await whapiDelivery(service, source: view.id, secret: reveal!.secret, id: "1", chat: "g", text: "x")
        var event = try await service.events().first!
        XCTAssertEqual(event.status, .failed)
        XCTAssertEqual(event.attempt, 1)
        XCTAssertTrue(event.outcome!.contains("No such agent."))
        await dispatch.setFailCreate(false)
        event = try await service.retry(event.id)
        XCTAssertEqual(event.status, .delivered)
        let replayed = try await service.replay(event.id)
        XCTAssertEqual(replayed.replayOf, event.id)
        XCTAssertEqual(replayed.status, .delivered)
        let routed = try await service.route(event.id, to: .init(kind: .session, id: "s1"), instruction: "Look: {{text}}")
        XCTAssertEqual(routed.sessionId, "s1")
        let typed = await dispatch.typed
        XCTAssertTrue(typed.first!.1.hasSuffix("Look: x"))
        let created = await dispatch.created
        XCTAssertEqual(created.count, 2)
    }

    func testHeldEventsGoOutWhenTheirWindowOpens() async throws {
        let clock = RCVClock()
        let (service, dispatch, _) = try await RCVTestKit.service(clock: clock)
        let (view, reveal) = try await service.createSource(preset: "whapi", name: "Groups")
        _ = try await service.saveRule(RCVRule(name: "Slow", sourceIds: [view.id], target: .init(kind: .hoot), perMinute: 1), byOwner: true)
        try await whapiDelivery(service, source: view.id, secret: reveal!.secret, id: "1", chat: "g", text: "one")
        try await whapiDelivery(service, source: view.id, secret: reveal!.secret, id: "2", chat: "g", text: "two")
        var statuses = try await service.events().map(\.status)
        XCTAssertEqual(statuses, [.held, .delivered])
        clock.advance(61_000)
        await service.wakeHeld()
        statuses = try await service.events().map(\.status)
        XCTAssertEqual(statuses, [.delivered, .delivered])
        let created = await dispatch.created
        XCTAssertEqual(created.map(\.assignee), ["hoot", "hoot"])
    }

    func testTerminalDecksOwnEventsArriveWithNoSetup() async throws {
        let (service, dispatch, _) = try await RCVTestKit.service()
        let sources = try await service.sources()
        XCTAssertEqual(Set(sources.map(\.id)), Set(RCVPresets.internalSources.map(\.id)))
        XCTAssertTrue(sources.allSatisfy { $0.address == nil && $0.active })
        var rule = try XCTUnwrap(RCVPresets.terminalDeck.examples.first)
        rule.sourceIds = ["terminaldeck.servers"]
        _ = try await service.saveRule(rule, byOwner: true)
        await BackendRCVFeed.shared.install(service)
        await BackendRCVFeed.shared.post("terminaldeck.servers", .init(kind: "docker.container.died", severity: .error, title: "shop-web stopped",
                                                                       text: "Exit code 137 (out of memory).", fields: ["server": "web-1", "container": "shop-web"]))
        await BackendRCVFeed.shared.install(nil)
        let event = try await service.events().first!
        XCTAssertEqual(event.kind, "docker.container.died")
        XCTAssertEqual(event.severity, .error)
        XCTAssertEqual(event.fields["container"], "shop-web")
        XCTAssertEqual(event.status, .delivered)
        let created = await dispatch.created
        XCTAssertEqual(created.first?.assignee, "hoot")
        do { try await service.deleteSource("terminaldeck.servers"); XCTFail("built-in sources cannot be deleted") } catch {}
    }

    func testDeletingASourceSwitchesOffRulesLeftWithoutOne() async throws {
        let (service, _, _) = try await RCVTestKit.service()
        let (view, _) = try await service.createSource(preset: "github", name: "Repo")
        var rules = try await service.rules()
        XCTAssertEqual(rules.count, 1, "the preset's example rule is added, switched off")
        XCTAssertFalse(rules[0].enabled)
        let rule = try await service.saveRule(RCVRule(name: "Only repo", sourceIds: [view.id], target: .init(kind: .hoot)), byOwner: true)
        try await service.deleteSource(view.id)
        rules = try await service.rules()
        let after = try XCTUnwrap(rules.first { $0.id == rule.id })
        XCTAssertFalse(after.enabled, "a rule with no source left would otherwise match every source")
    }

    func testDryRunWithADraftRuleAndASample() async throws {
        let (service, dispatch, _) = try await RCVTestKit.service()
        let (view, _) = try await service.createSource(preset: "sentry", name: "Sentry")
        let draft = RCVRule(name: "Errors", sourceIds: [view.id], conditions: [.init("severity", .atLeast, "error")], target: .init(kind: .newTask, id: "builder"))
        let (decision, event) = try await service.test(rule: draft, eventID: nil, sourceID: view.id, sample: String(decoding: Self.sentrySample, as: UTF8.self))
        XCTAssertEqual(decision.status, .delivered)
        XCTAssertEqual(event.title, "TypeError: cart is undefined")
        let created = await dispatch.created
        XCTAssertTrue(created.isEmpty, "a dry run sends nothing")
        let stored = try await service.events()
        XCTAssertTrue(stored.isEmpty, "a dry run stores nothing")
    }
}
