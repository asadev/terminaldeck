import Foundation
import XCTest
@testable import TerminalDeckBackend

/// WhatsApp's Agent Platform as a URLProtocol stand-in: each test has its own host, a queue of answers and a record
/// of what reached it. Nothing here touches the network.
final class WhatsAppStubHTTP: URLProtocol, @unchecked Sendable {
    struct Answer {
        var status: Int = 200
        var body: Data = Data()
        var failure: URLError.Code?
        var delay: Double = 0
    }
    struct Seen { let method: String; let url: URL; let headers: [String: String]; let body: Data; let timeout: Double }

    static let lock = NSLock()
    nonisolated(unsafe) static var answers: [String: [Answer]] = [:]
    nonisolated(unsafe) static var seen: [String: [Seen]] = [:]
    nonisolated(unsafe) static var inFlight: [String: Int] = [:]
    nonisolated(unsafe) static var mostInFlight: [String: Int] = [:]

    static func script(_ host: String, _ list: [Answer]) { lock.lock(); answers[host, default: []] += list; lock.unlock() }
    static func requests(_ host: String) -> [Seen] { lock.lock(); defer { lock.unlock() }; return seen[host] ?? [] }
    static func most(_ host: String) -> Int { lock.lock(); defer { lock.unlock() }; return mostInFlight[host] ?? 0 }
    static func clear(_ host: String) { lock.lock(); answers[host] = []; lock.unlock() }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let host = request.url?.host ?? ""
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            stream.close()
        }
        Self.lock.lock()
        Self.seen[host, default: []].append(Seen(method: request.httpMethod ?? "GET", url: request.url!,
                                                 headers: request.allHTTPHeaderFields ?? [:], body: body,
                                                 timeout: request.timeoutInterval))
        Self.inFlight[host, default: 0] += 1
        Self.mostInFlight[host] = max(Self.mostInFlight[host] ?? 0, Self.inFlight[host]!)
        let answer = Self.answers[host]?.isEmpty == false ? Self.answers[host]!.removeFirst() : Answer(status: 599)
        Self.lock.unlock()
        let finish: @Sendable () -> Void = { [self] in
            Self.lock.lock(); Self.inFlight[host, default: 1] -= 1; Self.lock.unlock()
            if let failure = answer.failure {
                client?.urlProtocol(self, didFailWithError: URLError(failure))
                return
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !answer.body.isEmpty { client?.urlProtocol(self, didLoad: answer.body) }
            client?.urlProtocolDidFinishLoading(self)
        }
        if answer.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + answer.delay, execute: finish) } else { finish() }
    }
}

/// Virtual time: sleeping only moves the clock forward and is written down.
final class WhatsAppTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double = 1_800_000_000
    private var slept: [Double] = []
    var sleeps: [Double] { lock.lock(); defer { lock.unlock() }; return slept }
    var elapsed: Double { lock.lock(); defer { lock.unlock() }; return seconds - 1_800_000_000 }
    var clock: WhatsAppClock {
        WhatsAppClock(now: { [self] in lock.lock(); defer { lock.unlock() }; return Date(timeIntervalSince1970: seconds) },
                      sleep: { [self] wait in advance(wait) })
    }
    private func advance(_ wait: Double) { lock.lock(); slept.append(wait); seconds += wait; lock.unlock() }
}

final class WhatsAppHTTPTransportTests: XCTestCase, @unchecked Sendable {
    private let key = "EAAG-test-key-\(UUID().uuidString)"
    private let host = "wa-\(UUID().uuidString.lowercased()).test"
    private let time = WhatsAppTestClock()

    private func transport(_ limits: WhatsAppHTTPTransport.Limits = .init()) -> WhatsAppHTTPTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WhatsAppStubHTTP.self]
        return WhatsAppHTTPTransport(session: URLSession(configuration: configuration),
                                     base: URL(string: "https://\(host)/agent/v1")!, clock: time.clock, limits: limits,
                                     mediaHosts: ["test"])
    }

    private func answer(_ status: Int, _ json: String = "") -> WhatsAppStubHTTP.Answer {
        WhatsAppStubHTTP.Answer(status: status, body: Data(json.utf8))
    }
    private func error(_ status: Int, _ code: Int, _ message: String = "(#\(0)) failure") -> WhatsAppStubHTTP.Answer {
        answer(status, #"{"error":{"message":"\#(message)","type":"OAuthException","code":\#(code),"fbtrace_id":"AbC"}}"#)
    }
    private func failure(_ code: URLError.Code) -> WhatsAppStubHTTP.Answer { WhatsAppStubHTTP.Answer(failure: code) }
    private func script(_ list: WhatsAppStubHTTP.Answer...) { WhatsAppStubHTTP.script(host, list) }
    private var seen: [WhatsAppStubHTTP.Seen] { WhatsAppStubHTTP.requests(host) }
    private func query(_ index: Int) -> [String: String] {
        let items = URLComponents(url: seen[index].url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }
    private func json(_ index: Int) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: seen[index].body)) as? [String: Any] ?? [:]
    }

    private static let updates = #"""
    {"object":"whatsapp_agent_platform","entry":[{"id":"123456789","changes":[{"field":"messages","value":{
      "messaging_product":"whatsapp",
      "contacts":[{"wa_id":"user:50972923564215","profile":{"name":"Alex"}}],
      "messages":[
        {"from":"user:50972923564215","id":"wamid.T1","timestamp":"1736844652","type":"text","text":{"body":"Hello \"agent\" 😀"}},
        {"from":"user:50972923564215","id":"wamid.I1","timestamp":"1736844653","type":"image","image":{"id":"998a7c17","mime_type":"image/jpeg","sha256":"qMVn","caption":"look at this"},"context":{"id":"wamid.Q","from":"agent:123456789"}},
        {"from":"user:50972923564215","id":"wamid.D1","timestamp":"1736844654","type":"document","document":{"id":"14ef9fff","mime_type":"application/pdf","sha256":"x","caption":"the report","filename":"report.pdf"}},
        {"from":"user:50972923564215","id":"wamid.A1","timestamp":"1736844655","type":"audio","audio":{"id":"5f637c19","mime_type":"audio/ogg","sha256":"h2Es","voice":true}},
        {"from":"user:50972923564215","id":"wamid.S1","timestamp":"1736844656","type":"sticker","sticker":{"id":"2c3dde1d","mime_type":"image/webp","sha256":"y","animated":false}},
        {"from":"user:50972923564215","id":"wamid.R1","timestamp":"1736844657","type":"reaction","reaction":{"message_id":"wamid.OUT","emoji":"👍"}},
        {"from":"user:50972923564215","id":"wamid.V1","timestamp":"1736844658","type":"video","video":{"id":"451bd2ad","mime_type":"video/mp4","sha256":"z"}},
        {"from":"user:50972923564215","id":"wamid.X1","timestamp":"1736844659","type":"location","location":{}}
      ],
      "statuses":[{"id":"wamid.OUT","status":"read","recipient_id":"user:50972923564215","timestamp":"1736844650"}]
    }}]}],"next_offset":4611686018427387905}
    """#

    // MARK: - Polling

    func testPollParsesEveryMessageKindAndKeepsTheOffsetAs64Bit() async throws {
        script(answer(200, Self.updates))
        let result = await transport().poll(key: key, offset: 1286, timeout: 25)
        guard case .messages(let messages, let next) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(next, 4_611_686_018_427_387_905)
        XCTAssertEqual(messages.map(\.kind), [.text, .image, .document, .audio, .sticker, .reaction, .video, .other])
        XCTAssertEqual(messages[0].text, "Hello \"agent\" 😀")
        XCTAssertEqual(messages[0].from, "user:50972923564215")
        XCTAssertEqual(messages[0].timestamp, Date(timeIntervalSince1970: 1_736_844_652))
        XCTAssertEqual(messages[1].mediaID, "998a7c17"); XCTAssertEqual(messages[1].caption, "look at this")
        XCTAssertEqual(messages[1].mimeType, "image/jpeg"); XCTAssertNil(messages[1].text)
        XCTAssertEqual(messages[2].fileName, "report.pdf"); XCTAssertEqual(messages[2].caption, "the report")
        XCTAssertEqual(messages[3].mediaID, "5f637c19"); XCTAssertEqual(messages[3].mimeType, "audio/ogg")
        XCTAssertEqual(messages[4].mediaID, "2c3dde1d")
        XCTAssertNil(messages[5].mediaID); XCTAssertNil(messages[5].text)
        XCTAssertEqual(messages[5].id, "wamid.R1")
        let request = seen[0]
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.path, "/agent/v1/updates")
        XCTAssertEqual(query(0), ["offset": "1286", "limit": "50", "timeout": "25"])
        XCTAssertEqual(request.headers["Authorization"], "Bearer " + key)
        XCTAssertGreaterThan(request.timeout, 25 + 20, "the client's read timeout is well above the poll's 25 s")
    }

    func testOnlyReceiptsGiveNoMessagesButTheNextOffset() async {
        script(answer(200, #"{"object":"whatsapp_agent_platform","entry":[{"id":"1","changes":[{"field":"messages","value":{"messaging_product":"whatsapp","contacts":[],"messages":[],"statuses":[{"id":"wamid.O","status":"delivered","recipient_id":"user:1","timestamp":"1"}]}}]}],"next_offset":1288}"#))
        let result = await transport().poll(key: key, offset: 1287, timeout: 25)
        XCTAssertEqual(result, .messages([], next: 1288))
    }

    func testOffsetRulesNilOmitsItZeroAsksForTheBacklogAndTimeoutIsClamped() async {
        script(answer(204), answer(204), answer(204))
        let client = transport()
        _ = await client.poll(key: key, offset: nil, timeout: 25)
        _ = await client.poll(key: key, offset: 0, timeout: 90)
        _ = await client.poll(key: key, offset: -5, timeout: -1)
        XCTAssertEqual(query(0), ["limit": "50", "timeout": "25"])
        XCTAssertEqual(query(1), ["offset": "0", "limit": "50", "timeout": "25"])
        XCTAssertEqual(query(2), ["offset": "0", "limit": "50", "timeout": "0"])
    }

    func testPollStatusesMapToTheProtocol() async {
        script(answer(204), error(409, 1752041), error(401, 190), error(400, 100), error(400, 2))
        let client = transport()
        let nothing = await client.poll(key: key, offset: 7, timeout: 25)
        let replaced = await client.poll(key: key, offset: 7, timeout: 25)
        let malformed = await client.poll(key: key, offset: 7, timeout: 25)
        let invalid = await client.poll(key: key, offset: 7, timeout: 25)
        let otherBadRequest = await client.poll(key: key, offset: 7, timeout: 25)
        XCTAssertEqual(nothing, .nothing)
        XCTAssertEqual(replaced, .replaced)
        XCTAssertEqual(malformed, .keyRefused)
        XCTAssertEqual(invalid, .keyRefused)
        XCTAssertEqual(otherBadRequest, .backOff(seconds: 2))
    }

    func testPollBacksOffExponentiallyCappedAtSixtyAndASuccessResetsIt() async {
        script(error(429, 130429), error(500, 2), failure(.timedOut), failure(.notConnectedToInternet), error(503, 2),
               error(429, 130429), answer(200, #"{"entry":[],"next_offset":9}"#), error(429, 130429), answer(200, "not json"))
        let client = transport()
        var waits: [Double] = []
        for _ in 0..<6 {
            if case .backOff(let wait) = await client.poll(key: key, offset: 9, timeout: 25) { waits.append(wait) }
        }
        XCTAssertEqual(waits, [2, 4, 8, 16, 32, 60])
        let good = await client.poll(key: key, offset: 9, timeout: 25)
        XCTAssertEqual(good, .messages([], next: 9))
        let again = await client.poll(key: key, offset: 9, timeout: 25)
        XCTAssertEqual(again, .backOff(seconds: 2), "a good poll resets the back-off")
        let garbage = await client.poll(key: key, offset: 9, timeout: 25)
        XCTAssertEqual(garbage, .backOff(seconds: 4), "a 200 that is not WhatsApp's shape is a failed poll, never a new offset")
        XCTAssertTrue(time.sleeps.isEmpty, "the poll gives the wait to the engine; it does not sleep")
    }

    func testNeverTwoPollsAtOnceForOneKey() async {
        var slow = answer(204); slow.delay = 0.05
        script(slow, slow, slow)
        let client = transport()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { _ = await client.poll(key: self.key, offset: 1, timeout: 25) } }
        }
        XCTAssertEqual(seen.count, 3)
        XCTAssertEqual(WhatsAppStubHTTP.most(host), 1)
    }

    func testFifteenPollsAMinute() async {
        WhatsAppStubHTTP.script(host, Array(repeating: answer(204), count: 16))
        let client = transport()
        for _ in 0..<16 { _ = await client.poll(key: key, offset: 1, timeout: 0) }
        XCTAssertEqual(seen.count, 16)
        XCTAssertEqual(time.sleeps.count, 1)
        XCTAssertEqual(time.elapsed, 60, accuracy: 0.01, "the 16th poll waits until the oldest one is a minute old")
    }

    // MARK: - Key check

    func testKeyCheckIsOneQuickLookWithoutAnOffset() async {
        script(answer(200, #"{"entry":[],"next_offset":3}"#), answer(204), error(400, 100), error(401, 190), error(500, 2),
               failure(.cannotFindHost), error(409, 1752041))
        let client = transport()
        var results: [WhatsAppKeyCheck] = []
        for _ in 0..<7 { results.append(await client.check(key: key)) }
        XCTAssertEqual(results, [.accepted, .accepted, .refused, .refused, .unreachable, .unreachable, .accepted])
        XCTAssertEqual(query(0), ["limit": "1", "timeout": "0"])
    }

    // MARK: - Sending

    func testSendBodyCopiesTheRecipientAndA2xxIsNeverRetried() async {
        script(answer(200, #"{"messaging_product":"whatsapp","contacts":[{"input":"user:50972923564215","wa_id":"user:50972923564215"}],"messages":[{"id":"wamid.NEW"}]}"#))
        let result = await transport().send(key: key, to: "user:50972923564215", text: "Done ✅\nسب ٹھیک ہے")
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen[0].method, "POST")
        XCTAssertEqual(seen[0].url.path, "/agent/v1/messages")
        XCTAssertEqual(seen[0].headers["Content-Type"], "application/json")
        let body = json(0)
        XCTAssertEqual(body["messaging_product"] as? String, "whatsapp")
        XCTAssertEqual(body["to"] as? String, "user:50972923564215")
        XCTAssertEqual(body["type"] as? String, "text")
        XCTAssertEqual((body["text"] as? [String: Any])?["body"] as? String, "Done ✅\nسب ٹھیک ہے")
        XCTAssertGreaterThanOrEqual(seen[0].timeout, 60)
    }

    func testOnly503With131016IsSentAgainAfterBackingOff() async {
        script(error(503, 131016), answer(200, #"{"messages":[{"id":"wamid.2"}]}"#))
        let result = await transport().send(key: key, to: "user:1", text: "hi")
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(seen.count, 2)
        XCTAssertEqual(time.sleeps, [2])
    }

    func testRateLimitedSendIsRetriedThenGivesBackOff() async {
        script(error(429, 130429), error(429, 130429), error(429, 130429))
        let result = await transport().send(key: key, to: "user:1", text: "hi")
        XCTAssertEqual(result, .backOff(seconds: 8))
        XCTAssertEqual(seen.count, 3)
        XCTAssertEqual(time.sleeps, [2, 4])
    }

    func testUnknownWhetherSentIsReportedAndNeverRetried() async {
        for unknown in [error(500, 2), failure(.timedOut), failure(.networkConnectionLost), error(503, 2), error(502, 2)] {
            let before = seen.count
            script(unknown, answer(200))
            let result = await transport().send(key: key, to: "user:1", text: "once")
            XCTAssertEqual(result, .failed(WhatsAppHTTPTransport.unknownWhetherSent))
            XCTAssertEqual(seen.count, before + 1, "never sent twice")
            WhatsAppStubHTTP.clear(host)
        }
        XCTAssertTrue(time.sleeps.isEmpty)
    }

    func testARequestThatNeverLeftIsSentAgain() async {
        script(failure(.notConnectedToInternet), answer(200))
        let result = await transport().send(key: key, to: "user:1", text: "hi")
        XCTAssertEqual(result, .sent)
        XCTAssertEqual(seen.count, 2)
    }

    func testRefusalsAreNotRetried() async {
        script(error(400, 131009, "(#131009) Missing or malformed required fields"), error(403, 131005), error(401, 190),
               error(400, 100, "(#100) Invalid OAuth access token"), error(400, 100, "text.body"), error(404, 2))
        let client = transport()
        let malformed = await client.send(key: key, to: "user:1", text: "a")
        let notCreator = await client.send(key: key, to: "user:1", text: "a")
        let missingHeader = await client.send(key: key, to: "user:1", text: "a")
        let invalidKey = await client.send(key: key, to: "user:1", text: "a")
        let tooLong = await client.send(key: key, to: "user:1", text: "a")
        let other = await client.send(key: key, to: "user:1", text: "a")
        XCTAssertEqual(malformed, .failed("WhatsApp refused the message (HTTP 400, code 131009)."))
        XCTAssertEqual(notCreator, .notCreator)
        XCTAssertEqual(missingHeader, .keyRefused)
        XCTAssertEqual(invalidKey, .keyRefused)
        XCTAssertEqual(tooLong, .failed("WhatsApp said the message is too long."))
        XCTAssertEqual(other, .failed("WhatsApp refused the message (HTTP 404, code 2)."))
        XCTAssertEqual(seen.count, 6)
        XCTAssertTrue(time.sleeps.isEmpty)
    }

    func testWhatCannotBeSentNeverLeaves() async {
        let client = transport()
        let agent = await client.send(key: key, to: "agent:123", text: "a")
        let bare = await client.send(key: key, to: "50972923564215", text: "a")
        let long = await client.send(key: key, to: "user:1", text: String(repeating: "😀", count: 2049))
        let empty = await client.send(key: key, to: "user:1", text: "")
        XCTAssertEqual(agent, .notCreator)
        XCTAssertEqual(bare, .notCreator)
        XCTAssertEqual(long, .failed("The message is longer than WhatsApp allows (4096 characters)."))
        XCTAssertEqual(empty, .failed("There was nothing to send."))
        XCTAssertTrue(seen.isEmpty)
    }

    func testSendsGoOneAtATimeInOrder() async {
        var slow = answer(200); slow.delay = 0.03
        WhatsAppStubHTTP.script(host, Array(repeating: slow, count: 4))
        let client = transport()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<4 { group.addTask { _ = await client.send(key: self.key, to: "user:1", text: "part \(index)") } }
        }
        XCTAssertEqual(seen.count, 4)
        XCTAssertEqual(WhatsAppStubHTTP.most(host), 1, "never two sends at once for one key")
    }

    func testTwelveSendsAMinute() async {
        WhatsAppStubHTTP.script(host, Array(repeating: answer(200), count: 13))
        let client = transport()
        for index in 0..<13 {
            let result = await client.send(key: key, to: "user:1", text: "n\(index)")
            XCTAssertEqual(result, .sent)
        }
        XCTAssertEqual(time.sleeps.count, 1)
        XCTAssertEqual(time.elapsed, 60, accuracy: 0.01)
    }

    // MARK: - Read and typing

    func testMarkReadWithAndWithoutTyping() async {
        script(answer(200, #"{"success":true}"#), answer(200, #"{"success":true}"#), error(403, 131005), error(401, 190),
               error(400, 131009))
        let client = transport()
        let typing = await client.markRead(key: key, messageID: "wamid.A", typing: true)
        let plain = await client.markRead(key: key, messageID: "wamid.B", typing: false)
        let notCreator = await client.markRead(key: key, messageID: "wamid.C", typing: false)
        let refused = await client.markRead(key: key, messageID: "wamid.D", typing: false)
        let malformed = await client.markRead(key: key, messageID: "nope", typing: false)
        XCTAssertEqual([typing, plain, notCreator, refused], [.sent, .sent, .notCreator, .keyRefused])
        XCTAssertEqual(malformed, .failed("WhatsApp could not mark the message read (HTTP 400, code 131009)."))
        XCTAssertEqual(seen[0].url.path, "/agent/v1/statuses")
        XCTAssertEqual(json(0)["status"] as? String, "read")
        XCTAssertEqual(json(0)["message_id"] as? String, "wamid.A")
        XCTAssertEqual((json(0)["typing_indicator"] as? [String: Any])?["type"] as? String, "text")
        XCTAssertNil(json(1)["typing_indicator"])
    }

    func testMarkReadRetriesOnceThenGivesBackOff() async {
        script(error(503, 2), answer(200, #"{"success":true}"#), error(429, 130429), error(500, 2))
        let client = transport()
        let retried = await client.markRead(key: key, messageID: "wamid.A", typing: true)
        let gaveUp = await client.markRead(key: key, messageID: "wamid.B", typing: true)
        XCTAssertEqual(retried, .sent)
        XCTAssertEqual(gaveUp, .backOff(seconds: 4), "429 then 500 in a row: 2 s, then 4 s")
        XCTAssertEqual(seen.count, 4)
    }

    func testTheThirteenthStatusCallInAMinuteIsSkippedNotQueued() async {
        WhatsAppStubHTTP.script(host, Array(repeating: answer(200, #"{"success":true}"#), count: 13))
        let client = transport()
        for _ in 0..<12 { _ = await client.markRead(key: key, messageID: "wamid.A", typing: true) }
        let skipped = await client.markRead(key: key, messageID: "wamid.A", typing: true)
        guard case .backOff(let wait) = skipped else { return XCTFail("\(skipped)") }
        XCTAssertEqual(wait, 60, accuracy: 0.01)
        XCTAssertEqual(seen.count, 12)
    }

    // MARK: - Media

    func testMediaFetchesTheMetadataThenTheBytesWithTheSameKey() async {
        let bytes = Data(repeating: 7, count: 1000)
        script(answer(200, #"{"url":"https://\#(host)/agent/v1/media/998a7c17/content","mime_type":"image/jpeg","sha256":"ab","file_size":1000,"id":"998a7c17","messaging_product":"whatsapp"}"#),
               WhatsAppStubHTTP.Answer(status: 200, body: bytes))
        let media = await transport().media(key: key, id: "998a7c17", limit: 5 * 1024 * 1024)
        XCTAssertEqual(media, WhatsAppMedia(data: bytes, mimeType: "image/jpeg"))
        XCTAssertEqual(seen.map(\.url.path), ["/agent/v1/media/998a7c17", "/agent/v1/media/998a7c17/content"])
        XCTAssertEqual(seen[1].headers["Authorization"], "Bearer " + key)
    }

    func testMediaRespectsTheLimitAndNeverSendsTheKeyElsewhere() async {
        script(answer(200, #"{"url":"https://\#(host)/c","mime_type":"video/mp4","file_size":20000000,"id":"v"}"#),
               answer(200, #"{"url":"http://\#(host)/c","mime_type":"image/jpeg","file_size":10,"id":"i"}"#),
               answer(200, #"{"url":"https://evil.example.com/c","mime_type":"image/jpeg","file_size":10,"id":"i"}"#),
               error(400, 100),
               answer(200, #"{"url":"https://\#(host)/c","mime_type":"image/jpeg","id":"i"}"#), WhatsAppStubHTTP.Answer(status: 200, body: Data(count: 11)),
               answer(200, #"{"url":"https://\#(host)/c","mime_type":"image/jpeg","id":"i"}"#), error(404, 100))
        let client = transport()
        let tooBig = await client.media(key: key, id: "v", limit: 16 * 1024 * 1024)
        let plainHTTP = await client.media(key: key, id: "i", limit: 100)
        let foreignHost = await client.media(key: key, id: "i", limit: 100)
        let unknown = await client.media(key: key, id: "gone", limit: 100)
        let overOnDownload = await client.media(key: key, id: "i", limit: 10)
        let expired = await client.media(key: key, id: "i", limit: 100)
        XCTAssertNil(tooBig); XCTAssertNil(plainHTTP); XCTAssertNil(foreignHost); XCTAssertNil(unknown)
        XCTAssertNil(overOnDownload); XCTAssertNil(expired)
        XCTAssertEqual(seen.count, 8, "no download after a refused size, scheme or host")
        XCTAssertFalse(seen.contains { $0.url.host == "evil.example.com" })
    }

    // MARK: - The key stays secret

    func testTheKeyNeverAppearsInAnyOutcomeOrText() async {
        let secret = key
        script(error(400, 100, "(#100) Invalid OAuth access token \(secret)"), error(500, 2), failure(.timedOut),
               error(400, 131009, "(#131009) bad \(secret)"), error(418, 7, secret),
               error(429, 1), error(429, 1), error(429, 1),
               error(400, 131009, secret), error(409, 1752041), error(500, 2), error(401, 190))
        let client = transport()
        var words: [String] = []
        for _ in 0..<5 { words.append(String(describing: await client.send(key: secret, to: "user:1", text: "x"))) }
        words.append(String(describing: await client.send(key: secret, to: "user:1", text: "x")))
        words.append(String(describing: await client.markRead(key: secret, messageID: "m", typing: true)))
        words.append(String(describing: await client.poll(key: secret, offset: 1, timeout: 25)))
        words.append(String(describing: await client.poll(key: secret, offset: 1, timeout: 25)))
        words.append(String(describing: await client.check(key: secret)))
        words.append(String(describing: client))
        words.append(WhatsAppHTTPTransport.unknownWhetherSent)
        for word in words { XCTAssertFalse(word.contains(secret), word) }
        XCTAssertFalse(words.joined().contains("EAAG-test-key"))
    }
}
