import Foundation
import XCTest
@testable import TerminalDeckBackend

final class WhatsAppFakeTransportTests: XCTestCase {
    private typealias Fake = WhatsAppFakeTransport

    func testOffsetsFollowWhatsAppsRules() async {
        let fake = Fake()
        await fake.addBacklog([Fake.text("old", id: "w1")])
        await fake.deliver(Fake.text("new 1", id: "w2"), Fake.text("new 2", id: "w3"))
        let head = await fake.poll(key: "k", offset: nil, timeout: 25)
        XCTAssertEqual(head, .messages([Fake.text("new 1", id: "w2"), Fake.text("new 2", id: "w3")], next: 4))
        let backlog = await fake.poll(key: "k", offset: 0, timeout: 25)
        guard case .messages(let all, 4) = backlog else { return XCTFail("\(backlog)") }
        XCTAssertEqual(all.map(\.id), ["w1", "w2", "w3"])
        let nothing = await fake.poll(key: "k", offset: 4, timeout: 25)
        XCTAssertEqual(nothing, .nothing)
        let again = await fake.poll(key: "k", offset: 2, timeout: 25)
        guard case .messages(let reread, 4) = again else { return XCTFail("\(again)") }
        XCTAssertEqual(reread.map(\.id), ["w2", "w3"], "polling does not consume")
        let polls = await fake.polls
        XCTAssertEqual(polls.map(\.offset), [nil, 0, 4, 2])
    }

    func testAPollReturnsAtMostFifty() async {
        let fake = Fake()
        await fake.deliver((1...70).map { Fake.text("m\($0)", id: "w\($0)") })
        let first = await fake.poll(key: "k", offset: 1, timeout: 25)
        guard case .messages(let page, let next) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(page.count, 50)
        XCTAssertEqual(next, 51)
    }

    func testVirtualTimeMovesOnlyWhenTold() async {
        let fake = Fake()
        _ = await fake.poll(key: "k", offset: 1, timeout: 25)
        var now = await fake.now
        XCTAssertEqual(now, 25, "an empty long-poll takes its timeout, virtually")
        await fake.advance(by: 10)
        _ = await fake.send(key: "k", to: "user:1000", text: "hi")
        now = await fake.now
        let sent = await fake.sent
        XCTAssertEqual(now, 35)
        XCTAssertEqual(sent, [.init(key: "k", to: "user:1000", text: "hi", at: 35)])
    }

    func testScriptedOutcomesComeFirstInOrder() async {
        let fake = Fake()
        await fake.scriptPolls([.backOff(seconds: 2), .keyRefused])
        await fake.replaceNextPoll()
        await fake.scriptSends([.backOff(seconds: 4), .failed("x")])
        await fake.scriptReads([.notCreator])
        await fake.scriptChecks([.unreachable])
        var polls: [WhatsAppPoll] = []
        for _ in 0..<4 { polls.append(await fake.poll(key: "k", offset: 1, timeout: 0)) }
        XCTAssertEqual(polls, [.backOff(seconds: 2), .keyRefused, .replaced, .nothing])
        let sends = [await fake.send(key: "k", to: "user:1000", text: "a"), await fake.send(key: "k", to: "user:1000", text: "b"),
                     await fake.send(key: "k", to: "user:1000", text: "c")]
        XCTAssertEqual(sends, [.backOff(seconds: 4), .failed("x"), .sent])
        let texts = await fake.sentTexts
        XCTAssertEqual(texts, ["c"], "only what was really sent is recorded")
        let read1 = await fake.markRead(key: "k", messageID: "w1", typing: true)
        let read2 = await fake.markRead(key: "k", messageID: "w2", typing: false)
        XCTAssertEqual([read1, read2], [.notCreator, .sent])
        let reads = await fake.reads
        XCTAssertEqual(reads.map(\.messageID), ["w2"])
        let check1 = await fake.check(key: "k")
        let check2 = await fake.check(key: "k")
        XCTAssertEqual([check1, check2], [.unreachable, .accepted])
    }

    func testARefusedKeyIsRefusedEverywhere() async {
        let fake = Fake()
        await fake.refuse(key: "bad")
        let check = await fake.check(key: "bad")
        let poll = await fake.poll(key: "bad", offset: nil, timeout: 25)
        let send = await fake.send(key: "bad", to: "user:1000", text: "x")
        let read = await fake.markRead(key: "bad", messageID: "w", typing: false)
        XCTAssertEqual(check, .refused); XCTAssertEqual(poll, .keyRefused)
        XCTAssertEqual(send, .keyRefused); XCTAssertEqual(read, .keyRefused)
        await fake.accept(key: "bad")
        let accepted = await fake.check(key: "bad")
        XCTAssertEqual(accepted, .accepted)
    }

    func testOnlyTheCreatorCanBeAddressedAndTooLongIsRefused() async {
        let fake = Fake(creator: "user:42")
        let other = await fake.send(key: "k", to: "user:43", text: "x")
        let long = await fake.send(key: "k", to: "user:42", text: String(repeating: "a", count: 4097))
        XCTAssertEqual(other, .notCreator)
        guard case .failed = long else { return XCTFail("\(long)") }
        let sent = await fake.sent
        XCTAssertTrue(sent.isEmpty)
    }

    func testLimitsWhenEnforced() async {
        let fake = Fake()
        await fake.enforceLimits()
        for index in 0..<12 { _ = await fake.send(key: "k", to: "user:1000", text: "\(index)") }
        let thirteenth = await fake.send(key: "k", to: "user:1000", text: "13")
        XCTAssertEqual(thirteenth, .backOff(seconds: 60))
        await fake.advance(by: 60)
        let later = await fake.send(key: "k", to: "user:1000", text: "13")
        XCTAssertEqual(later, .sent)
    }

    func testMediaRespectsTheLimit() async {
        let fake = Fake()
        let picture = WhatsAppMedia(data: Data(count: 100), mimeType: "image/jpeg")
        await fake.setMedia(id: "m1", picture)
        let fits = await fake.media(key: "k", id: "m1", limit: 100)
        let tooBig = await fake.media(key: "k", id: "m1", limit: 99)
        let unknown = await fake.media(key: "k", id: "m2", limit: 100)
        XCTAssertEqual(fits, picture); XCTAssertNil(tooBig); XCTAssertNil(unknown)
        let fetched = await fake.mediaFetches
        XCTAssertEqual(fetched, ["m1", "m1", "m2"])
    }

    func testItIsAWhatsAppTransport() async {
        let transport: any WhatsAppTransport = Fake()
        let check = await transport.check(key: "k")
        XCTAssertEqual(check, .accepted)
    }
}
