import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class BackendDeckCoreEventsSubscriptionsTests: XCTestCase {
    private func events(_ receiver: BackendDeckCoreEventsTestReceiver, _ clock: BackendDeckCoreEventsTestClock, directory: URL? = nil) -> BackendDeckCoreEvents {
        BackendDeckCoreEvents(directory:directory,mode:{ _ in "wait" },internet:{ true },clock:clock,post:{ try await receiver.post($0,$1,$2) })
    }
    func testVerificationAndIdempotentLeaseRefresh() async throws {
        let receiver = BackendDeckCoreEventsTestReceiver(), clock = BackendDeckCoreEventsTestClock(), events = events(receiver,clock)
        let first = try await events.subscribe(keyId:"A",via:"internet",params:BackendDeckCoreEventsTestFixture.params())
        clock.advance(60_000); let again = try await events.subscribe(keyId:"A",via:"internet",params:BackendDeckCoreEventsTestFixture.params())
        XCTAssertEqual(first["id"],again["id"]); XCTAssertNotEqual(first["refreshBefore"],again["refreshBefore"])
        let posts = await receiver.verifications(); XCTAssertEqual(posts.count,1)
        XCTAssertNil(BackendDeckCoreEventsWebhook.verify(secret:BackendDeckCoreEventsTestFixture.secret,headers:posts[0].headers,body:posts[0].body,nowSeconds:floor(clock.now()/1_000)))
        await events.stop()
    }
    func testWrongEchoRefusesAndKeepsNoSubscription() async {
        let receiver = BackendDeckCoreEventsTestReceiver(), clock = BackendDeckCoreEventsTestClock(), events = events(receiver,clock)
        await receiver.setWrongEcho(true)
        do { _ = try await events.subscribe(keyId:"A",via:"internet",params:BackendDeckCoreEventsTestFixture.params()); XCTFail() }
        catch let error as BackendDeckCoreEventsError { XCTAssertEqual(error.code,-32015); XCTAssertEqual(error.data["reason"].string,"challenge_failed") }
        catch { XCTFail("Wrong error \(error)") }
        let live = await events.subscriptions(); XCTAssertTrue(live.isEmpty); await events.stop()
    }
    // Every wait in this class is the source's settle() (mcp-events.test.ts:94-96): the posts an
    // offer or a fired retry started have answered. awaitIdle() awaits exactly those, where yielding
    // did not (test410… failed under load in S1e's run).
    func testSessionClaimWinsAgainstCatchAllAndNeverCrossesKeys() async throws {
        let receiver = BackendDeckCoreEventsTestReceiver(), clock = BackendDeckCoreEventsTestClock(), events = events(receiver,clock)
        _ = try await events.subscribe(keyId:"A",via:"internet",params:BackendDeckCoreEventsTestFixture.params(session:"s1",url:"https://callbacks.example.com/one"))
        _ = try await events.subscribe(keyId:"A",via:"internet",params:BackendDeckCoreEventsTestFixture.params(url:"https://callbacks.example.com/all"))
        _ = try await events.subscribe(keyId:"B",via:"internet",params:BackendDeckCoreEventsTestFixture.params(url:"https://callbacks.example.com/other"))
        let offered = await events.offer(keyId:"A",event:BackendDeckCoreEventsTestFixture.event("first")); XCTAssertEqual(offered,1)
        await events.awaitIdle()
        _ = await events.offer(keyId:"A",event:BackendDeckCoreEventsTestFixture.event("second",session:"s2")); await events.awaitIdle()
        let posts = await receiver.deliveries(); XCTAssertEqual(posts.map(\.url),["https://callbacks.example.com/one","https://callbacks.example.com/all"])
        await events.stop()
    }
    func testDeduplicationAndRetries() async throws {
        let receiver = BackendDeckCoreEventsTestReceiver(), clock = BackendDeckCoreEventsTestClock(), events = events(receiver,clock)
        _ = try await events.subscribe(keyId:"A",via:"internet",params:BackendDeckCoreEventsTestFixture.params()); await receiver.setStatuses([500])
        let event = BackendDeckCoreEventsTestFixture.event("retry")
        // mcp-events.test.ts:469-487 settles every post before the clock moves (settle(), :94-96).
        // Yielding was a misport: a late post shifted the retry schedule. awaitIdle() awaits the
        // fired retry timer and the callback it starts.
        _ = await events.offer(keyId:"A",event:event); _ = await events.offer(keyId:"A",event:event)
        await events.awaitIdle()
        for step in [5_000.0,30_000,120_000] { clock.advance(step); await events.awaitIdle() }
        let posts = await receiver.deliveries(), owed = await events.owed(), armed = await events.armed(), live = await events.subscriptions()
        XCTAssertEqual(posts.count,4); XCTAssertEqual(owed,0); XCTAssertFalse(armed); XCTAssertTrue(live[0]["lastDelivery"]["error"].string?.contains("gave up after 4 tries") == true)
        await events.stop()
    }
    func test410EndsSubscriptionAnd413NeverRetries() async throws {
        let receiver = BackendDeckCoreEventsTestReceiver(), clock = BackendDeckCoreEventsTestClock(), events = events(receiver,clock)
        _ = try await events.subscribe(keyId:"A",via:"internet",params:BackendDeckCoreEventsTestFixture.params()); await receiver.setStatuses([413])
        _ = await events.offer(keyId:"A",event:BackendDeckCoreEventsTestFixture.event()); await events.awaitIdle(); clock.advance(200_000); await events.awaitIdle()
        let first = await receiver.deliveries(), live = await events.subscriptions(); XCTAssertEqual(first.count,1); XCTAssertEqual(live.count,1)
        await receiver.setStatuses([410]); _ = await events.offer(keyId:"A",event:BackendDeckCoreEventsTestFixture.event()); await events.awaitIdle()
        let ended = await events.subscriptions(); XCTAssertTrue(ended.isEmpty); await events.stop()
    }
    func testUnsubscribeIsKeyScopedAndIdempotent() async throws {
        let receiver = BackendDeckCoreEventsTestReceiver(), clock = BackendDeckCoreEventsTestClock(), events = events(receiver,clock), params = BackendDeckCoreEventsTestFixture.params()
        _ = try await events.subscribe(keyId:"A",via:"this-mac",params:params)
        _ = try await events.unsubscribe(keyId:"B",params:params); let remains = await events.subscriptions(); XCTAssertEqual(remains.count,1)
        let one = try await events.unsubscribe(keyId:"A",params:params), two = try await events.unsubscribe(keyId:"A",params:params)
        XCTAssertEqual(one,.object([])); XCTAssertEqual(two,.object([])); await events.stop()
    }
    func testTTLBoundsAndRotationGrace() async throws {
        let receiver = BackendDeckCoreEventsTestReceiver(), clock = BackendDeckCoreEventsTestClock(), events = events(receiver,clock)
        let sub = try await events.subscribe(keyId:"A",via:"this-mac",params:BackendDeckCoreEventsTestFixture.params(ttl:10))
        XCTAssertEqual(sub["refreshBefore"].string,BackendDeckCoreEventsSupport.iso(clock.now()+60_000))
        _ = try await events.subscribe(keyId:"A",via:"this-mac",params:BackendDeckCoreEventsTestFixture.params(secret:BackendDeckCoreEventsTestFixture.otherSecret))
        _ = await events.offer(keyId:"A",event:BackendDeckCoreEventsTestFixture.event()); await events.awaitIdle()
        let during = await receiver.deliveries(); XCTAssertEqual(during[0].headers["webhook-signature"]?.split(separator:" ").count,2)
        clock.advance(300_001); _ = await events.offer(keyId:"A",event:BackendDeckCoreEventsTestFixture.event()); await events.awaitIdle()
        let after = await receiver.deliveries(); XCTAssertEqual(after[1].headers["webhook-signature"]?.split(separator:" ").count,1); await events.stop()
    }
    func testSubscriptionPerKeyLimitAndBadArgumentCodes() async throws {
        let receiver = BackendDeckCoreEventsTestReceiver(), clock = BackendDeckCoreEventsTestClock(), events = events(receiver,clock)
        for index in 0..<10 { _ = try await events.subscribe(keyId:"A",via:"internet",params:BackendDeckCoreEventsTestFixture.params(session:"s\(index)")) }
        do { _ = try await events.subscribe(keyId:"A",via:"internet",params:BackendDeckCoreEventsTestFixture.params(session:"overflow")); XCTFail() }
        catch let error as BackendDeckCoreEventsError { XCTAssertEqual(error.code,-32013) }
        do { _ = try await events.subscribe(keyId:"A",via:"internet",params:BackendDeckCoreEventsTestFixture.params(name:"gone")); XCTFail() }
        catch let error as BackendDeckCoreEventsError { XCTAssertEqual(error.code,-32011) }
        _ = try await events.subscribe(keyId:"B",via:"internet",params:BackendDeckCoreEventsTestFixture.params()); await events.stop()
    }
    func testQueueAlreadyDeliveredMeansNoPush() async throws {
        let receiver = BackendDeckCoreEventsTestReceiver(), clock = BackendDeckCoreEventsTestClock()
        let events = BackendDeckCoreEvents(mode:{ _ in "wait" },internet:{ true },clock:clock,post:{ try await receiver.post($0,$1,$2) },owed:{ _,_ in false })
        _ = try await events.subscribe(keyId:"A",via:"internet",params:BackendDeckCoreEventsTestFixture.params()); _ = await events.offer(keyId:"A",event:BackendDeckCoreEventsTestFixture.event())
        await events.awaitIdle(); let posted = await receiver.deliveries(), owed = await events.owed(); XCTAssertTrue(posted.isEmpty); XCTAssertEqual(owed,0); await events.stop()
    }
    func testSubscriptionsAndOwedDeliverySurviveRestart() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at:dir) }
        let receiver = BackendDeckCoreEventsTestReceiver(), clock = BackendDeckCoreEventsTestClock(), first = events(receiver,clock,directory:dir)
        _ = try await first.subscribe(keyId:"A",via:"internet",params:BackendDeckCoreEventsTestFixture.params()); await receiver.setStatuses([500,200])
        // mcp-events.test.ts:586-604: the first post (500) has settled before stop(), and the
        // retry after the restart has settled before owed() is read. awaitIdle() is that settle.
        _ = await first.offer(keyId:"A",event:BackendDeckCoreEventsTestFixture.event("kept")); await first.awaitIdle(); await first.stop()
        let second = events(receiver,clock,directory:dir); await second.load(); let owed = await second.owed(); XCTAssertEqual(owed,1)
        clock.advance(5_000); await second.awaitIdle(); let finished = await second.owed(); XCTAssertEqual(finished,0)
        let attributes = try FileManager.default.attributesOfItem(atPath:dir.appendingPathComponent(BackendDeckCoreEvents.fileName).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue,0o600); await second.stop()
    }
}
