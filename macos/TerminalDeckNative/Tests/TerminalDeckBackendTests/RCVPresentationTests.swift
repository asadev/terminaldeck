import Foundation
import XCTest
import TerminalDeckNativeCore

/// UI fixtures for the Receiver page: fixture sources, rules and events, and the
/// words and rows the page draws from them (RCVPresentation).
final class RCVPresentationTests: XCTestCase {
    private typealias P = RCVPresentation
    private let zone = TimeZone(identifier: "Asia/Dubai")!
    private let locale = Locale(identifier: "en_GB")
    /// 2026-10-08 12:00:00 in Dubai.
    private let now = Date(timeIntervalSince1970: 1_791_446_400)
    private func ms(_ secondsAgo: Double) -> Double { (now.timeIntervalSince1970 - secondsAgo) * 1000 }

    // MARK: Fixtures

    private func whatsapp(active: Bool = true, enabled: Bool = true, events: Int = 3) -> RCVSourceView {
        var source = RCVSource(id: "src-wa", name: "Shop WhatsApp", preset: "whapi", auth: RCVPresets.whapi.auth,
                               mapping: RCVPresets.whapi.mapping, reply: RCVPresets.whapi.reply, enabled: enabled)
        source.createdAt = ms(86_400)
        return RCVSourceView(source: source, address: "https://relay.terminaldeck.dev/in/ABCDEF", active: active,
                             hasReplyCredential: false, lastEventAt: ms(240), eventCount: events, rejectedCount: 1)
    }

    private func github() -> RCVSourceView {
        let source = RCVSource(id: "src-gh", name: "Spacefield repo", preset: "github", auth: RCVPresets.github.auth,
                               mapping: RCVPresets.github.mapping, reply: RCVPresets.github.reply)
        return RCVSourceView(source: source, address: "https://relay.terminaldeck.dev/in/GHGHGH", active: false,
                             hasReplyCredential: true, lastEventAt: nil, eventCount: 0, rejectedCount: 0)
    }

    private func servers() -> RCVSourceView {
        let source = RCVSource(id: "terminaldeck.servers", name: "Servers and apps", preset: "terminaldeck", origin: .terminalDeck,
                               auth: .init(scheme: .none), mapping: RCVPresets.terminalDeck.mapping)
        return RCVSourceView(source: source, address: nil, active: false, hasReplyCredential: false, lastEventAt: nil, eventCount: 0, rejectedCount: 0)
    }

    private let groupRule = RCVRule(id: "rule-group", name: "Shop group", sourceIds: ["src-wa"],
                                    conditions: [.init("fields.chat", .equals, "123@g.us")],
                                    target: .init(kind: .agent, id: "agent-ada", threadKey: "{{fields.chat}}"))

    private func event(_ id: String, status: RCVStatus, secondsAgo: Double, source: String = "src-wa", title: String = "Ali",
                       text: String = "Is the blue shirt in stock?", fields: [String: String] = ["chat": "123@g.us"]) -> RCVEvent {
        var event = RCVEvent(id: id, sourceId: source, receivedAt: ms(secondsAgo), kind: "messages", title: title, text: text, fields: fields,
                             raw: Data(#"{"chat_id":"123@g.us","from":"971500000000","text":{"body":"Is the blue shirt in stock?"}}"#.utf8),
                             headers: ["content-type": "application/json", "user-agent": "Whapi"])
        event.status = status
        return event
    }

    private func overview(events: [RCVEvent] = [], sources: [RCVSourceView]? = nil, rules: [RCVRule]? = nil) -> RCVOverview {
        RCVOverview(sources: sources ?? [whatsapp(), github(), servers()], rules: rules ?? [groupRule], events: events,
                    unrouted: events.filter { $0.status == .unrouted }.count, held: 0, relayConnected: true,
                    relayBase: "https://relay.terminaldeck.dev", presets: RCVPresets.all,
                    agents: [.init(id: "agent-ada", name: "Ada")], sessions: [.init(id: "sess-1", name: "Claude · shop")])
    }

    // MARK: Wire

    func testDecodesAFoundationAnswerAndEncodesArguments() throws {
        let rule = groupRule
        let foundation = try P.foundation(rule)
        XCTAssertEqual((foundation as? [String: Any])?["name"] as? String, "Shop group")
        XCTAssertEqual(try P.decode(RCVRule.self, from: foundation), rule)

        let delivered = { () -> RCVEvent in var e = self.event("e1", status: .delivered, secondsAgo: 10); e.ruleId = "rule-group"; return e }()
        let roundTrip = try P.decode([RCVEvent].self, from: try P.foundation([delivered]))
        XCTAssertEqual(roundTrip, [delivered])

        let created = try P.decode(P.Created.self, from: [
            "source": try P.foundation(whatsapp()),
            "reveal": ["sourceId": "src-wa", "secret": "s3cret", "addressWithSecret": "https://relay.terminaldeck.dev/in/ABCDEF/s3cret"],
        ] as [String: Any])
        XCTAssertEqual(created.source.id, "src-wa")
        XCTAssertEqual(created.reveal?.secret, "s3cret")
        XCTAssertNil(try P.decode(P.Created.self, from: ["source": try P.foundation(github())] as [String: Any]).reveal)
        XCTAssertEqual(try P.decode(P.TaskAnswer.self, from: ["taskId": "t-9"] as [String: Any]).taskId, "t-9")
    }

    func testABadAnswerReadsAsOnePlainSentence() {
        XCTAssertThrowsError(try P.decode(RCVRule.self, from: ["nope": 1] as [String: Any])) { error in
            XCTAssertEqual(P.sentence(error), "The Receiver’s answer could not be read.")
        }
        XCTAssertThrowsError(try P.decode(RCVRule.self, from: NSObject())) { error in
            XCTAssertEqual(P.sentence(error), "The Receiver’s answer could not be read.")
        }
        XCTAssertEqual(P.sentence(NativeRPCError.invalidArguments("Give the rule a name of up to 120 characters.")),
                       "Give the rule a name of up to 120 characters.")
        XCTAssertEqual(P.sentence(EngineWireError.refused("That source is gone.")), "That source is gone.")
    }

    // MARK: Rail and status words

    func testRailCountsAndWords() {
        let o = overview(events: [event("a", status: .unrouted, secondsAgo: 5), event("b", status: .delivered, secondsAgo: 9)])
        XCTAssertEqual(P.Place.allCases.map(\.title), ["Flow", "Unrouted", "Sources", "Rules"])
        XCTAssertEqual(P.Place.allCases.map { P.count($0, in: o) }, [2, 1, 3, 1])
        XCTAssertEqual(P.statuses.map(P.word), ["Delivered", "Waiting", "Unrouted", "Failed", "Repeat", "Ignored", "Rejected"])
        XCTAssertEqual(Set(RCVStatus.allCases), Set(P.statuses), "every status has a place in the filter")
        XCTAssertEqual(P.tone(.failed), .bad)
        XCTAssertEqual(P.tone(.held), .waiting)
        XCTAssertEqual(P.symbol(.delivered), "checkmark.circle")
        for status in RCVStatus.allCases { XCTAssertFalse(P.meaning(status).isEmpty) }
    }

    // MARK: Time words

    func testRelativeTimeWords() {
        XCTAssertEqual(P.relative(ms(10), now: now, timeZone: zone, locale: locale), "just now")
        XCTAssertEqual(P.relative(ms(4 * 60 + 20), now: now, timeZone: zone, locale: locale), "4 min ago")
        XCTAssertEqual(P.relative(ms(3_600), now: now, timeZone: zone, locale: locale), "1 hour ago")
        XCTAssertEqual(P.relative(ms(5 * 3_600), now: now, timeZone: zone, locale: locale), "5 hours ago")
        // Yesterday 21:30 Dubai.
        XCTAssertEqual(P.relative(ms(14.5 * 3_600), now: now, timeZone: zone, locale: locale), "yesterday 21:30")
        // Three days back: weekday and time.
        XCTAssertEqual(P.relative(ms(3 * 86_400), now: now, timeZone: zone, locale: locale), "Mon 12:00")
        // Month abbreviations differ between ICU versions ("Sep" / "Sept").
        XCTAssertTrue(P.relative(ms(30 * 86_400), now: now, timeZone: zone, locale: locale).hasPrefix("8 Sep"))
        let lastYear = P.relative(ms(400 * 86_400), now: now, timeZone: zone, locale: locale)
        XCTAssertTrue(lastYear.hasPrefix("3 Sep") && lastYear.hasSuffix(" 2025"), lastYear)
        XCTAssertEqual(P.hour(22, locale: locale), "22:00")
        XCTAssertEqual(P.hour(8, locale: locale), "08:00")
    }

    // MARK: Flow rows

    func testFlowRowsReadWhereThingsCameFromAndWentTo() {
        var delivered = event("e1", status: .delivered, secondsAgo: 60)
        delivered.ruleId = "rule-group"; delivered.target = groupRule.target
        var byHand = event("e2", status: .delivered, secondsAgo: 30)
        byHand.target = .init(kind: .hoot)
        let unrouted = event("e3", status: .unrouted, secondsAgo: 5, source: "terminaldeck.servers", title: "", text: "", fields: [:])
        let o = overview(events: [delivered, byHand, unrouted])

        let rows = P.rows(o.events, overview: o)
        XCTAssertEqual(rows[0].sourceName, "Shop WhatsApp")
        XCTAssertEqual(rows[0].sourceSymbol, "message")
        XCTAssertEqual(rows[0].route, "→ Shop group → Ada")
        XCTAssertEqual(rows[0].statusWord, "Delivered")
        XCTAssertEqual(rows[1].route, "→ By hand → Hoot")
        XCTAssertNil(rows[2].route)
        XCTAssertEqual(rows[2].statusWord, "Unrouted")
        XCTAssertEqual(rows[2].sourceName, "Servers and apps")
        XCTAssertEqual(rows[2].sourceSymbol, "macwindow")
        XCTAssertEqual(rows[2].title, "messages", "a blank event still has a headline")

        var gone = delivered; gone.sourceId = "src-old"; gone.ruleId = "rule-old"
        let row = P.row(gone, overview: o)
        XCTAssertEqual(row.sourceName, "A removed source")
        XCTAssertEqual(row.route, "→ A deleted rule → Ada")
    }

    func testSearchAndFiltersNarrowTheFlowNewestFirst() {
        let a = event("a", status: .delivered, secondsAgo: 300, text: "Order 1182 shipped")
        let b = event("b", status: .unrouted, secondsAgo: 100, source: "src-gh", title: "Crash on login", text: "", fields: ["repo": "asadev/spacefield"])
        let c = event("c", status: .failed, secondsAgo: 200, text: "Where is my ORDER?")
        let events = [a, b, c]
        let sources = overview().sources

        XCTAssertEqual(P.filter(events, query: "", sourceID: nil, status: nil, sources: sources).map(\.id), ["b", "c", "a"])
        XCTAssertEqual(P.filter(events, query: "order", sourceID: nil, status: nil, sources: sources).map(\.id), ["c", "a"])
        XCTAssertEqual(P.filter(events, query: "spacefield", sourceID: nil, status: nil, sources: sources).map(\.id), ["b"], "field values and source names are searched")
        XCTAssertEqual(P.filter(events, query: "repo spacefield", sourceID: nil, status: nil, sources: sources).map(\.id), ["b"])
        XCTAssertEqual(P.filter(events, query: "", sourceID: "src-wa", status: nil, sources: sources).map(\.id), ["c", "a"])
        XCTAssertEqual(P.filter(events, query: "", sourceID: nil, status: .failed, sources: sources).map(\.id), ["c"])
        XCTAssertEqual(P.filter(events, query: "nothing like it", sourceID: nil, status: nil, sources: sources), [])
    }

    // MARK: One event

    func testTheFourStepChainForADeliveredEvent() {
        var e = event("e1", status: .delivered, secondsAgo: 60)
        e.ruleId = "rule-group"; e.target = groupRule.target; e.taskId = "task-42"
        e.replies = [RCVReply(id: "r1", at: ms(30), text: "Yes, in M and L.", state: .sent, by: "Ada", autoApproved: true)]
        let chain = P.chain(e, overview: overview(events: [e]), now: now, timeZone: zone, locale: locale)
        XCTAssertEqual(chain.map(\.label), ["Came from", "Rule", "Went to", "Result"])
        XCTAssertEqual(chain.map(\.value), ["Shop WhatsApp", "Shop group", "Ada", "Delivered"])
        XCTAssertEqual(chain[0].detail, "messages · info")
        XCTAssertEqual(chain[2].detail, "One ongoing task")
        XCTAssertEqual(chain[3].detail, "Task task-42 · 1 reply")
        XCTAssertTrue(chain.allSatisfy(\.reached))

        let replies = P.replyLines(e, now: now, timeZone: zone, locale: locale)
        XCTAssertEqual(replies.map(\.headline), ["Sent · just now · by Ada · without asking"])
        XCTAssertEqual(replies.first?.text, "Yes, in M and L.")
    }

    func testTheChainForUnroutedHeldRejectedAndIgnored() {
        let o = overview()
        let unrouted = P.chain(event("u", status: .unrouted, secondsAgo: 5), overview: o, now: now, timeZone: zone, locale: locale)
        XCTAssertEqual(unrouted.map(\.value), ["Shop WhatsApp", "No rule matched", "Nowhere yet", "Unrouted"])
        XCTAssertFalse(unrouted[1].reached)
        XCTAssertEqual(unrouted[3].detail, "No rule matched it yet.")

        var held = event("h", status: .held, secondsAgo: 5)
        held.ruleId = "rule-group"; held.target = groupRule.target
        held.resumeAt = ms(-8 * 3_600) // 20:00 today
        XCTAssertEqual(P.chain(held, overview: o, now: now, timeZone: zone, locale: locale)[3].value, "Waiting until 20:00")
        held.resumeAt = ms(-20 * 3_600) // 08:00 tomorrow
        XCTAssertEqual(P.chain(held, overview: o, now: now, timeZone: zone, locale: locale)[3].value, "Waiting until Fri 08:00")

        let rejected = P.chain(event("r", status: .rejected, secondsAgo: 5), overview: o, now: now, timeZone: zone, locale: locale)
        XCTAssertEqual(rejected.map(\.value), ["Shop WhatsApp", "Not checked", "Not sent", "Rejected"])
        XCTAssertEqual(rejected[3].tone, .bad)

        let ignored = P.chain(event("i", status: .ignored, secondsAgo: 5), overview: o, now: now, timeZone: zone, locale: locale)
        XCTAssertEqual(ignored[1].value, "Ignore list")
        XCTAssertEqual(ignored[2].value, "Not sent")
    }

    func testDetailListsTrailFieldsHeadersAndPrettyRaw() {
        var e = event("e1", status: .delivered, secondsAgo: 60, fields: ["sender": "971500000000", "chat": "123@g.us", "Message": "x"])
        e.trail = [RCVStep(at: ms(60), "Arrived from the relay."), RCVStep(at: ms(59), "Rule “Shop group” matched.")]
        let trail = P.trail(e, timeZone: zone, locale: locale)
        XCTAssertEqual(trail.map(\.time), ["11:59:00", "11:59:01"])
        XCTAssertEqual(trail.map(\.words), ["Arrived from the relay.", "Rule “Shop group” matched."])
        XCTAssertEqual(P.fields(e).map(\.name), ["chat", "Message", "sender"])
        XCTAssertEqual(P.headers(e).map(\.name), ["content-type", "user-agent"])
        let raw = P.prettyRaw(e.raw)
        XCTAssertTrue(raw.hasPrefix("{\n"), raw)
        XCTAssertTrue(raw.contains("\"chat_id\" : \"123@g.us\""), raw)
        XCTAssertEqual(P.prettyRaw(Data("plain words".utf8)), "plain words")
        XCTAssertTrue(P.prettyRaw(Data(String(repeating: "a", count: 50).utf8), limit: 10).hasSuffix("…"))
    }

    func testWhichButtonsAnEventOffers() {
        let wa = whatsapp().source, gh = github().source
        var noReply = gh; noReply.reply = nil
        XCTAssertEqual(P.actions(event("u", status: .unrouted, secondsAgo: 1), source: wa),
                       .init(retry: false, replay: true, route: true, reply: true, suggest: true, askHoot: true))
        XCTAssertEqual(P.actions(event("f", status: .failed, secondsAgo: 1), source: noReply),
                       .init(retry: true, replay: true, route: true, reply: false, suggest: false, askHoot: false))
        XCTAssertTrue(P.actions(event("h", status: .held, secondsAgo: 1), source: wa).retry)
        XCTAssertEqual(P.actions(event("r", status: .rejected, secondsAgo: 1), source: wa),
                       .init(retry: false, replay: false, route: false, reply: false, suggest: false, askHoot: false))
        XCTAssertFalse(P.actions(event("x", status: .delivered, secondsAgo: 1), source: nil).reply)
    }

    // MARK: Sources

    func testSourceStatesSummariesAndOrder() {
        XCTAssertEqual(P.state(whatsapp()).word, "Active")
        XCTAssertEqual(P.state(whatsapp(active: false)).word, "Waiting for relay")
        XCTAssertEqual(P.state(whatsapp(enabled: false)).word, "Paused")
        XCTAssertEqual(P.state(servers()).word, "Active", "built-in sources need no relay")
        XCTAssertEqual(P.summary(whatsapp(), now: now, timeZone: zone, locale: locale), "3 events · last 4 min ago · 1 rejected")
        XCTAssertEqual(P.summary(whatsapp(events: 1), now: now, timeZone: zone, locale: locale), "1 event · last 4 min ago · 1 rejected")
        XCTAssertEqual(P.summary(github(), now: now, timeZone: zone, locale: locale), "No events yet")
        XCTAssertEqual(P.sorted([servers(), whatsapp(), github()]).map(\.id), ["src-wa", "src-gh", "terminaldeck.servers"])
        XCTAssertTrue(P.hasOwnSources([servers(), github()]))
        XCTAssertFalse(P.hasOwnSources([servers()]))
        XCTAssertEqual(P.addressLine(servers()), "Built in. Terminal Deck sends its own events here, so there is no address.")
    }

    func testBuiltInSourcesCannotBeDeletedAndTheQuestionNamesTheSource() {
        XCTAssertFalse(P.canDelete(servers().source))
        XCTAssertTrue(P.canDelete(whatsapp().source))
        XCTAssertEqual(P.deleteQuestion(whatsapp().source), "Delete the source “Shop WhatsApp”?")
    }

    func testAddingASourceOffersRelayPresetsAndAuthChoices() {
        XCTAssertFalse(P.creatable(RCVPresets.all).contains { $0.id == "terminaldeck" })
        XCTAssertEqual(P.creatable(RCVPresets.all).first?.id, "webhook")
        XCTAssertTrue(P.authChoosable(RCVPresets.generic))
        XCTAssertFalse(P.authChoosable(RCVPresets.github), "a vendor signature is fixed")
        XCTAssertFalse(P.authChoosable(RCVPresets.terminalDeck))

        let base = RCVAuth(scheme: .token, ipAllow: ["203.0.113.0/24"])
        let signed = P.auth(.hmac, from: base, preset: RCVPresets.generic)
        XCTAssertEqual(signed.scheme, .hmac)
        XCTAssertEqual(signed.hmac?.header, "x-signature-256")
        XCTAssertEqual(signed.ipAllow, ["203.0.113.0/24"], "switching scheme keeps the allow-list")
        XCTAssertEqual(P.auth(.basic, from: base, preset: nil).basicUser, "receiver")
        XCTAssertNil(P.auth(.none, from: signed, preset: nil).hmac)
        XCTAssertEqual(P.addresses("203.0.113.4, 10.0.0.0/8\n 2001:db8::1 "), ["203.0.113.4", "10.0.0.0/8", "2001:db8::1"])
        XCTAssertEqual(P.addressesText(["1.2.3.4", "5.6.7.8"]), "1.2.3.4\n5.6.7.8")
        XCTAssertEqual(P.revealHelp(whatsapp(), presets: RCVPresets.all), RCVPresets.whapi.help)
    }

    func testTheSendersOwnSecretIsOfferedForRelaySourcesAndAskedFirstForSentry() {
        XCTAssertTrue(P.offersOwnSecret(whatsapp().source))
        XCTAssertTrue(P.offersOwnSecret(github().source))
        XCTAssertFalse(P.offersOwnSecret(servers().source), "built-in sources have no secret")
        var open = whatsapp().source; open.auth = .init(scheme: .none)
        XCTAssertFalse(P.offersOwnSecret(open), "a private-address-only source has no secret")
        var sentry = github().source; sentry.preset = "sentry"; sentry.auth = RCVPresets.sentry.auth
        XCTAssertTrue(P.ownSecretFirst(sentry))
        XCTAssertFalse(P.ownSecretFirst(github().source))
        XCTAssertEqual(P.ownSecretHelp, "For senders like Sentry that give you their secret. Paste it here instead of copying ours.")
    }

    func testMappingPreviewPutsASplitItemBackUnderItsPath() {
        // Whapi splits `messages`; the kept raw is one message.
        var e = event("e1", status: .delivered, secondsAgo: 5)
        e.raw = Data(#"{"chat_id":"123@g.us","from":"971500000000","from_name":"Ali","from_me":false,"id":"m1","text":{"body":"Hello"},"type":"text"}"#.utf8)
        let preview = P.preview(whatsapp().source, sample: e)
        XCTAssertEqual(preview.count, 1)
        XCTAssertEqual(preview.first?.title, "Ali")
        XCTAssertEqual(preview.first?.text, "Hello")
        XCTAssertEqual(preview.first?.fields["chat"], "123@g.us")
        XCTAssertEqual(preview.first?.upstreamId, "m1")

        var generic = whatsapp().source
        generic.mapping = RCVPresets.server.mapping
        e.raw = Data(#"{"title":"Disk full","severity":"error","host":"web-1"}"#.utf8)
        let flat = P.preview(generic, sample: e)
        XCTAssertEqual(flat.first?.title, "Disk full")
        XCTAssertEqual(flat.first?.severity, .error)
        XCTAssertEqual(flat.first?.fields["host"], "web-1")
    }

    // MARK: Rules

    func testRuleSummariesInPlainWords() {
        let o = overview()
        XCTAssertEqual(P.summary(groupRule, overview: o), "From Shop WhatsApp · when fields.chat is 123@g.us → Ada (one ongoing task)")
        let any = RCVRule(name: "All to Hoot", target: .init(kind: .hoot))
        XCTAssertEqual(P.summary(any, overview: o), "Any source · everything → Hoot")
        let present = RCVRule(name: "x", conditions: [.init("fields.sender", .exists)], target: .init(kind: .newTask, id: "agent-ada"))
        XCTAssertEqual(P.summary(present, overview: o), "Any source · when fields.sender is present → New task for Ada")
        let session = RCVRule(name: "y", target: .init(kind: .session, id: "sess-1"))
        XCTAssertTrue(P.summary(session, overview: o).hasSuffix("→ Claude · shop (running session)"))
        let unchosen = RCVRule(name: "z", target: .init(kind: .agent, id: ""))
        XCTAssertTrue(P.summary(unchosen, overview: o).hasSuffix("→ Not chosen yet (one ongoing task)"))

        var limited = groupRule
        XCTAssertNil(P.limits(limited, locale: locale))
        limited.quietHours = .init(startHour: 22, endHour: 8, timeZone: "Asia/Dubai")
        limited.dedupeMinutes = 30
        limited.autoApproveReplies = true
        XCTAssertEqual(P.limits(limited, locale: locale), "Quiet 22:00–08:00 · Repeats within 30 min skipped · Replies go out without asking")
    }

    func testMovingRulesStopsAtTheEnds() {
        let rules = [RCVRule(id: "a", name: "A"), RCVRule(id: "b", name: "B"), RCVRule(id: "c", name: "C")]
        XCTAssertNil(P.moveIndex("a", up: true, in: rules))
        XCTAssertEqual(P.moveIndex("a", up: false, in: rules), 1)
        XCTAssertEqual(P.moveIndex("c", up: true, in: rules), 1)
        XCTAssertNil(P.moveIndex("c", up: false, in: rules))
        XCTAssertNil(P.moveIndex("gone", up: true, in: rules))
    }

    func testConditionPathSuggestionsComeFromFieldsHeadersAndThePayload() {
        let e = event("e1", status: .unrouted, secondsAgo: 5)
        let paths = P.paths(sources: [whatsapp().source], events: [e])
        XCTAssertEqual(Array(paths.prefix(5)), ["kind", "severity", "title", "text", "source"])
        XCTAssertTrue(paths.contains("fields.chat"))
        XCTAssertTrue(paths.contains("fields.senderName"), "the source's own field names")
        XCTAssertTrue(paths.contains("raw.chat_id"))
        XCTAssertTrue(paths.contains("raw.text.body"), "one level into nested objects")
        XCTAssertTrue(paths.contains("header.user-agent"))
        XCTAssertEqual(paths.count, Set(paths).count, "no repeats")
        let placeholders = P.placeholders(sources: [], events: [e])
        XCTAssertEqual(placeholders.first, "{{id}}")
        XCTAssertTrue(placeholders.contains("{{title}}"))
        XCTAssertTrue(P.needsValue(.equals))
        XCTAssertFalse(P.needsValue(.missing))
    }

    func testStartingPointsComeFromThePresetsOfTheOwnersSources() {
        let points = P.startingPoints(sources: [whatsapp(), servers()], presets: RCVPresets.all)
        let whapi = points.first { $0.id == "whapi/example-whapi-group" }
        XCTAssertEqual(whapi?.rule.sourceIds, ["src-wa"])
        XCTAssertEqual(whapi?.detail, "For Shop WhatsApp")
        let github = points.first { $0.id == "github/example-github-issue" }
        XCTAssertEqual(github?.rule.sourceIds, [])
        XCTAssertEqual(github?.detail, "For any GitHub source")
        XCTAssertTrue(points.first.map { !$0.rule.sourceIds.isEmpty } ?? false, "ones for existing sources come first")

        let fresh = P.fresh(whapi!.rule)
        XCTAssertNotEqual(fresh.id, "example-whapi-group")
        XCTAssertFalse(fresh.autoApproveReplies)
        XCTAssertEqual(P.newRule().target.kind, .hoot)
        XCTAssertEqual(P.validation(P.newRule()), "Give the rule a name of up to 120 characters.")
        XCTAssertNil(P.validation(groupRule))
    }

    func testTheTestersAnswerInPlainWords() {
        let o = overview()
        let go = RCVDecision(status: .delivered, reason: "Rule “Shop group” matched.", ruleId: "rule-group", ruleName: "Shop group",
                             target: groupRule.target, instruction: "[Receiver] …")
        XCTAssertEqual(P.decisionWords(go, overview: o, now: now, timeZone: zone, locale: locale).headline, "Would go to Ada (one ongoing task)")
        XCTAssertEqual(P.decisionWords(go, overview: o).reason, "Rule “Shop group” matched.")
        var wait = go; wait.status = .held; wait.resumeAt = ms(-8 * 3_600)
        XCTAssertEqual(P.decisionWords(wait, overview: o, now: now, timeZone: zone, locale: locale).headline,
                       "Would wait until 20:00, then go to Ada (one ongoing task)")
        let none = RCVDecision(status: .unrouted, reason: "No rule matched.")
        XCTAssertEqual(P.decisionWords(none, overview: o).headline, "Would wait in Unrouted")
        XCTAssertEqual(P.decisionWords(none, overview: o).tone, .attention)
    }

    // MARK: Empty states

    func testEmptyStatesSayWhatToDo() {
        XCTAssertEqual(P.emptyFlow(hasOwnSources: false, narrowed: false).action, "Add a source")
        XCTAssertTrue(P.emptyFlow(hasOwnSources: false, narrowed: false).message.hasPrefix("Add a source to start receiving"))
        XCTAssertNil(P.emptyFlow(hasOwnSources: true, narrowed: false).action)
        XCTAssertEqual(P.emptyFlow(hasOwnSources: true, narrowed: true).title, "Nothing matches")
        XCTAssertEqual(P.emptyUnrouted.title, "Nothing unrouted")
        XCTAssertEqual(P.emptySources.action, "Add a source")
        XCTAssertEqual(P.emptyRules.title, "No rules yet")
        XCTAssertEqual(P.relayLine(connected: true), "Connected to the relay.")
    }
}
