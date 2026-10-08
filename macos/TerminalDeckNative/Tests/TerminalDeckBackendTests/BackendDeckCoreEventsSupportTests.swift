import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendDeckCoreEventsTestClock: BackendDeckCoreEventsClock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Double = 1_800_000_000_000
    private var timers: [UUID:(Double,@Sendable () -> Void)] = [:]
    /// Counts every timer set, so a test can wait for one without yielding and hoping.
    let scheduled = BackendDeckCoreTestPortSecuritySignal()
    func now() -> Double { lock.withLock { instant } }
    func schedule(after milliseconds: Double, _ run: @escaping @Sendable () -> Void) -> UUID { let id = lock.withLock { let id = UUID(); timers[id] = (instant + max(milliseconds,0),run); return id }; scheduled.signal(); return id }
    func cancel(_ handle: UUID) { lock.withLock { _ = timers.removeValue(forKey:handle) } }
    func pending() -> Int { lock.withLock { timers.count } }
    func advance(_ milliseconds: Double) {
        let target = now() + milliseconds
        while let next: (UUID,Double,@Sendable () -> Void) = lock.withLock({
            guard let pair = timers.filter({ $0.value.0 <= target }).min(by:{ $0.value.0 < $1.value.0 }) else { instant = target; return nil }
            instant = pair.value.0; timers[pair.key] = nil; return (pair.key,pair.value.0,pair.value.1)
        }) { next.2() }
    }
}

actor BackendDeckCoreEventsTestReceiver {
    struct Post: Sendable { let url: String; let headers: [String:String]; let body: String }
    var posts: [Post] = []
    var statuses = [200]
    var wrongEcho = false
    func setStatuses(_ values: [Int]) { statuses = values }
    func setWrongEcho(_ value: Bool) { wrongEcho = value }
    func post(_ url: String, _ headers: [String:String], _ body: String) throws -> BackendDeckCoreEventsCallbackAnswer {
        posts.append(Post(url:url,headers:headers,body:body)); let value = try NativeRPCValue.parseJSON(Data(body.utf8))
        if value["type"].string == "verification" {
            return .init(status:200,body:BackendDeckCoreEventsSupport.object([("challenge",wrongEcho ? .string("wrong") : value["challenge"])]).compact)
        }
        let status = statuses.first ?? 200; if statuses.count > 1 { statuses.removeFirst() }; return .init(status:status,body:"")
    }
    func deliveries() -> [Post] { posts.filter { (try? NativeRPCValue.parseJSON(Data($0.body.utf8)))?["type"].string != "verification" } }
    func verifications() -> [Post] { posts.filter { (try? NativeRPCValue.parseJSON(Data($0.body.utf8)))?["type"].string == "verification" } }
}

enum BackendDeckCoreEventsTestFixture {
    static let secret = "whsec_" + Data(repeating:7,count:32).base64EncodedString()
    static let otherSecret = "whsec_" + Data(repeating:9,count:32).base64EncodedString()
    static let url = "https://callbacks.example.com/events"
    static func params(session: String? = nil, name: String = "session.turn_finished", url: String = BackendDeckCoreEventsTestFixture.url, secret: String = BackendDeckCoreEventsTestFixture.secret, ttl: Double? = nil) -> NativeRPCValue {
        BackendDeckCoreEventsSupport.object([("name",.string(name)),("arguments",session.map { BackendDeckCoreEventsSupport.object([("sessionId",.string($0))]) } ?? .object([])),("delivery",BackendDeckCoreEventsSupport.object([("mode",.string("webhook")),("url",.string(url)),("secret",.string(secret))])),("ttlMs",ttl.map(NativeRPCValue.number) ?? .null)])
    }
    static func event(_ id: String = UUID().uuidString, type: String = "finished", session: String = "s1", at: Double = 1_800_000_000_000) -> NativeRPCValue {
        BackendDeckCoreEventsSupport.object([("id",.string(id)),("type",.string(type)),("sessionId",.string(session)),("sessionName",.string("api")),("at",.number(at)),("answer",BackendDeckCoreEventsSupport.object([("text",.string("Done.")),("truncated",.bool(false))])),("suggestedTool",.string("sessions_send")),("note",.string("The session finished its turn."))])
    }
    static func drain() async { for _ in 0..<100 { await Task.yield() } }
}

@MainActor
final class BackendDeckCoreEventsSupportTests: XCTestCase {
    func testBlockedAddressRangesAndEmbeddedIPv4() {
        let blocked = ["0.0.0.0","10.1.2.3","100.64.0.1","127.0.0.1","169.254.169.254","172.16.0.1","172.31.255.255","192.0.0.1","192.0.2.1","192.88.99.1","192.168.1.1","198.18.0.1","198.51.100.7","203.0.113.9","224.0.0.1","255.255.255.255","::","::1","100::1","fc00::1","fd12:3456::1","fe80::1","fec0::1","ff02::1","2001:db8::1","2001::1","::ffff:127.0.0.1","::ffff:7f00:1","::ffff:10.0.0.1","64:ff9b::a00:1","2002:c0a8:101::1","not an address"]
        for address in blocked { XCTAssertFalse(BackendDeckCoreEventsCallback.isPublicAddress(address),address) }
    }
    func testPublicAddressForms() {
        for address in ["8.8.8.8","1.1.1.1","104.18.32.47","2606:4700::6810:84e5","2a00:1450:4001::200e","::ffff:8.8.8.8","64:ff9b::808:808","2002:808:808::1"] { XCTAssertTrue(BackendDeckCoreEventsCallback.isPublicAddress(address),address) }
    }
    func testCallbackURLChecksBeforeConnecting() async {
        XCTAssertNil(BackendDeckCoreEventsCallback.urlProblem("https://callbacks.chatgpt.com/mcp/events/abc"))
        for address in ["http://example.com/x","https://user:pass@example.com/x","https://localhost/x","https://api.localhost/x","https://printer.local/x","https://metadata.google.internal/x","https://router/x","https://[::1]/x","https://169.254.169.254/latest/meta-data","not a url"] {
            XCTAssertNotNil(BackendDeckCoreEventsCallback.urlProblem(address),address)
            do { _ = try await BackendDeckCoreEventsCallback.post(address,[:],"{}"); XCTFail(address) }
            catch let error as BackendDeckCoreEventsCallbackRefused { XCTAssertEqual(error.reason,"not_public") }
            catch { XCTFail("Wrong refusal: \(error)") }
        }
    }
    func testOwnerWebhookCanUseLoopbackHTTP() {
        for address in ["http://localhost:123/hook","http://127.0.0.1/hook","http://[::1]/hook","https://hooks.example/x"] { XCTAssertNil(BackendDeckCoreEventsWebhook.urlProblem(address)) }
        XCTAssertNotNil(BackendDeckCoreEventsWebhook.urlProblem("http://hooks.example/x"))
        XCTAssertNotNil(BackendDeckCoreEventsWebhook.urlProblem("https://user:password@example.com/x"))
    }
    func testWebhookSigningReplayAndRotation() {
        let secret = BackendDeckCoreEventsTestFixture.secret, other = BackendDeckCoreEventsTestFixture.otherSecret
        var headers = BackendDeckCoreEventsWebhook.headers(secret:secret,id:"n-1",timestamp:1_800_000_000,body:"{}")
        XCTAssertNil(BackendDeckCoreEventsWebhook.verify(secret:secret,headers:headers,body:"{}",nowSeconds:1_800_000_000))
        XCTAssertEqual(BackendDeckCoreEventsWebhook.verify(secret:other,headers:headers,body:"{}",nowSeconds:1_800_000_000),"mismatch")
        XCTAssertEqual(BackendDeckCoreEventsWebhook.verify(secret:secret,headers:headers,body:"{} ",nowSeconds:1_800_000_000),"mismatch")
        XCTAssertEqual(BackendDeckCoreEventsWebhook.verify(secret:secret,headers:headers,body:"{}",nowSeconds:1_800_000_301),"stale")
        headers["webhook-signature"]! += " " + BackendDeckCoreEventsWebhook.sign(secret:other,id:"n-1",timestamp:1_800_000_000,body:"{}")
        XCTAssertNil(BackendDeckCoreEventsWebhook.verify(secret:other,headers:headers,body:"{}",nowSeconds:1_800_000_000))
        headers["webhook-id"] = nil
        XCTAssertEqual(BackendDeckCoreEventsWebhook.verify(secret:secret,headers:headers,body:"{}",nowSeconds:1_800_000_000),"missing")
    }
    func testSubscriptionSecretBoundsAndCanonicalID() {
        XCTAssertNil(BackendDeckCoreEvents.secretProblem(.string(BackendDeckCoreEventsTestFixture.secret)))
        for secret in ["bad","whsec_!bad","whsec_" + Data(repeating:0,count:8).base64EncodedString(),"whsec_" + Data(repeating:0,count:80).base64EncodedString()] { XCTAssertNotNil(BackendDeckCoreEvents.secretProblem(.string(secret))) }
        let one = BackendDeckCoreEvents.subscriptionId(keyId:"a",url:"https://a.example/x",name:"session.exited",sessionId:nil)
        XCTAssertEqual(one,BackendDeckCoreEvents.subscriptionId(keyId:"a",url:"https://a.example/x",name:"session.exited",sessionId:nil))
        XCTAssertNotEqual(one,BackendDeckCoreEvents.subscriptionId(keyId:"b",url:"https://a.example/x",name:"session.exited",sessionId:nil))
        XCTAssertNotEqual(one,BackendDeckCoreEvents.subscriptionId(keyId:"a",url:"https://a.example/x",name:"session.exited",sessionId:"s1"))
    }
    func testAnswerRetentionUsesCumulativeBytes() {
        var buffer = BackendDeckCoreEventsAnswerBuffer()
        buffer.append(Data(repeating:1,count:8_000)); buffer.append(Data(repeating:2,count:1_000)); buffer.append(Data(repeating:3,count:10))
        XCTAssertEqual(buffer.bytesSeen,9_010); XCTAssertEqual(buffer.data.count,8_000)
        XCTAssertEqual(buffer.data.last,1)
    }
    func testLiteralSchemasAndMCPAlterTier() throws {
        let rows = try BackendDeckCoreEventsToolDefinitions.all()
        XCTAssertEqual(rows.count,14)
        XCTAssertEqual(rows.first { $0["id"].string == "mcp.call" }?["tier"].string,"alter")
        XCTAssertEqual(rows.first { $0["id"].string == "mcp.add" }?["inputSchema"]["required"].elements?.compactMap(\.string),["name","scope","transport"])
        XCTAssertEqual(BackendDeckCoreEvents.catalogue().map { $0["name"].string },["session.turn_finished","session.needs_input","session.exited"] + BackendTAGTaskNotifications.eventNames.values.sorted().map(Optional.some))
    }
    func testMCPInputAndOutputSecretRules() throws {
        let input = BackendDeckCoreEventsSupport.object([("next",BackendDeckCoreEventsSupport.object([("headers",BackendDeckCoreEventsSupport.object([("Authorization",.string("Bearer secret"))]))]))])
        XCTAssertEqual(BackendDeckCoreEventsTools.redactEnvValues(input)["next"]["headers"]["Authorization"].string,"[redacted]")
        let status = BackendDeckCoreEventsSupport.object([("env",BackendDeckCoreEventsSupport.object([("TOKEN",.string("secret"))])),("source",.string("/Users/someone/.claude.json")),("url",.string("https://user:password@mcp.example.com/sse")),("args",.array([.string("sk-ant-api03-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")]))])
        let view = BackendDeckCoreEventsTools.serverView(status)
        XCTAssertEqual(view["env"],.missing); XCTAssertEqual(view["envKeys"],.array([.string("TOKEN")]))
        XCTAssertTrue(view.compact.contains("/Users/someone/.claude.json")); XCTAssertFalse(view.compact.contains("password")); XCTAssertFalse(view.compact.contains("sk-ant-api03"))
    }
    func testSharedDefinitionDropsValuesAndCapsNames() throws {
        let text = BackendDeckCoreEventsSupport.object([("kind",.string("mcp-server")),("name",.string(" github ")),("command",.string("npx server")),("env",.array((0..<40).map { .string("TOKEN\($0)=private") }))]).compact
        let draft = try BackendDeckCoreEventsTools.readToolFile(text)
        XCTAssertEqual(draft["env"].elements?.count,32); XCTAssertFalse(draft.compact.contains("private")); XCTAssertEqual(draft["name"].string,"github")
        XCTAssertThrowsError(try BackendDeckCoreEventsTools.readToolFile("not json"))
    }
}
