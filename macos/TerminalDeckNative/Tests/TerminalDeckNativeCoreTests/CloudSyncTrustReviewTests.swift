import XCTest
import Foundation
@testable import TerminalDeckNativeCore

/// The trust review's items (review-cloud-sync-trust-core.md), each through the real engine as the app builds it.
extension CloudSyncTests {

  // MARK: S1. The release comes first on every path

  /// A device's older saved-password pack waits; its newer one was first served as locked and parked. Once the
  /// device is trusted and the parked pack is readable, the parked pack is NOT applied before the waiting one:
  /// the release runs first, both arrive in feed order and both are late arrivals.
  func testTrustReviewReleaseComesBeforeAParkedSavedPasswordPackIsRetried() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), x = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: x.deviceId), protected = CloudSyncProtectedFixtureContent()
    let older = try await reviewProtectedOperation(protected), newer = try await reviewProtectedOperation(protected)
    let senderList = try CloudSyncFixtureTrust([x])
    let (sender, _, _) = try await trustProtectedEngine(root: scratch(), server: server, identity: x, trust: senderList, content: protected)
    _ = try await sender.enqueue([older])
    _ = try await sender.flush()                                   // position 1
    _ = try await sender.enqueue([newer])
    _ = try await sender.flush()                                   // position 2
    let feed = try await server.changes(after: .zero, limit: 8)
    let newerPack = try XCTUnwrap(feed.segments.last?.segmentId)
    await server.lock(segments: [newerPack])                       // the service serves the newer pack as locked
    await server.switchDevice(mac.deviceId)
    let list = try CloudSyncFixtureTrust([mac])
    let (reader, store, adapter) = try await trustProtectedEngine(root: scratch(), server: server, identity: mac, trust: list, content: protected)
    _ = try await reader.pull()                                    // older: waits. newer: locked, parked.
    let before = await adapter.count()
    XCTAssertEqual(before, 0)
    let waiting = try await reader.heldDevices()
    XCTAssertEqual(waiting.first?.firstHeldSecretsSeq, CloudSequence(1))
    XCTAssertFalse(try store.rows("SELECT 1 FROM parked_packs LIMIT 1").isEmpty)

    // The device is trusted, the parked pack becomes readable, and the parked packs are retried at once.
    try await list.trust(x)
    await server.lock(segments: [])
    try await reader.retryParked(domains: ["api-key"])
    let order = await adapter.appliedOrder(), effects = await adapter.effectCount()
    XCTAssertEqual(order, [older.opId, newer.opId], "the waiting older pack went first")
    XCTAssertEqual(effects, 2)
    let first = await adapter.origin(of: older.opId), second = await adapter.origin(of: newer.opId)
    XCTAssertEqual(first?.late, true)
    XCTAssertEqual(second?.late, true, "a pack read again is a late arrival")
    XCTAssertTrue(try store.rows("SELECT 1 FROM parked_packs LIMIT 1").isEmpty)
    let none = try await reader.heldDevices()
    XCTAssertTrue(none.isEmpty)
  }

  /// R6 inside one pull: the person's trust click lands after the pull began. The device's newer pack in that
  /// pull is not applied before its older waiting pack: the release runs right there, first.
  func testTrustReviewTrustGivenDuringAPullReleasesOlderPacksBeforeTheNewerOne() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), x = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let list = try CloudSyncFixtureTrust([mac])
    let (engine, _, adapter) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: list)
    let older = try op(entity: "note", text: "older", origin: x.deviceId)
    let newer = try op(entity: "note", parents: [older.opId], text: "newer", origin: x.deviceId)
    try await commit([older], as: x, on: server, then: mac)        // 1
    _ = try await engine.pull()                                    // waits
    try await commit([newer], as: x, on: server, then: mac)        // 2
    // The next pull asks about the waiting device once at its start (not trusted yet); the click lands before the
    // newer pack is judged.
    try await list.trust(x, afterQuestions: 1)
    _ = try await engine.pull()
    let order = await adapter.appliedOrder()
    XCTAssertEqual(order, [older.opId, newer.opId])
    let late = await adapter.origin(of: older.opId), inOrder = await adapter.origin(of: newer.opId)
    XCTAssertEqual(late?.late, true)
    XCTAssertNil(inOrder?.late)
  }

  /// "Check again" does not apply a refused pack of a device ahead of that device's older waiting packs either.
  func testTrustReviewCheckAgainReleasesWaitingPacksFirst() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), x = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let wrong = CloudSyncTestIdentity(deviceId: secondMac, seed: 9)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let list = try CloudSyncFixtureTrust([mac])
    let (engine, _, adapter) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: list)
    let older = try op(entity: "note", text: "older", origin: x.deviceId)
    let newer = try op(entity: "note", parents: [older.opId], text: "newer", origin: x.deviceId)
    try await commit([older], as: x, on: server, then: mac)        // 1: waits (not trusted)
    _ = try await engine.pull()
    let wrongKey = try wrong.jwk()
    await list.store(x.deviceId, key: wrongKey)                    // trusted under a key that is not its own
    try await commit([newer], as: x, on: server, then: mac)        // 2
    _ = try await engine.pull()                                    // both are refused under that key
    let refused = try await engine.refusedPacks()
    XCTAssertEqual(refused.map(\.sequence), [CloudSequence(1), CloudSequence(2)])
    // The device's packs wait again (stopped), the newer one stays refused; then the right key is stored and
    // only the NEWER one is checked again.
    await list.stop(x.deviceId)
    let third = try op(entity: "note-2", origin: x.deviceId)
    try await commit([third], as: x, on: server, then: mac)        // 3: waits
    _ = try await engine.pull()
    try await list.trust(x)
    _ = try await engine.checkRefusedAgain(sequence: CloudSequence(2))
    let order = await adapter.appliedOrder()
    XCTAssertEqual(order.first, third.opId, "the waiting pack was released before the refused one was applied")
    XCTAssertEqual(Set(order), [third.opId, newer.opId])
  }

  // MARK: S3. A refusal must not become a lasting silent gap

  /// A stored key that cannot be read says nothing about the pack: the pack WAITS and is applied once the key on
  /// this Mac's list is right. Refused, it would have been passed over.
  func testTrustReviewUnreadableStoredKeyMakesPacksWaitNotRefused() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), x = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let list = try CloudSyncFixtureTrust([mac])
    await list.store(x.deviceId, key: CloudPublicJWK(kty: "EC", crv: "P-256", x: "AAAA", y: "AAAA"))
    let (engine, _, adapter) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: list)
    let theirs = try op(entity: "good-pack", origin: x.deviceId)
    try await commit([theirs], as: x, on: server, then: mac)
    _ = try await engine.pull()
    let refused = try await engine.refusedPacks(), waiting = try await engine.heldDevices()
    XCTAssertTrue(refused.isEmpty, "nothing is wrong with the pack")
    XCTAssertEqual(waiting.map(\.deviceId), [x.deviceId])
    try await list.trust(x)
    _ = try await engine.pull()
    let order = await adapter.appliedOrder()
    XCTAssertEqual(order, [theirs.opId])
  }

  /// Refused packs are judged again at each launch without a click (a bounded number): a pack refused while a
  /// wrong key was stored is applied as a late arrival after the next start, once the key is right.
  func testTrustReviewRefusedPacksAreCheckedAgainAtLaunch() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), x = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let wrong = CloudSyncTestIdentity(deviceId: secondMac, seed: 9)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let list = try CloudSyncFixtureTrust([mac])
    let wrongKey = try wrong.jwk()
    await list.store(x.deviceId, key: wrongKey)
    let root = try scratch()
    let (engine, _, adapter) = try await trustEngine(root: root, server: server, identity: mac, trust: list)
    let theirs = try op(entity: "refused-then-right", origin: x.deviceId)
    try await commit([theirs], as: x, on: server, then: mac)
    _ = try await engine.pull()
    let refused = try await engine.refusedPacks()
    XCTAssertEqual(refused.count, 1)
    try await list.trust(x)
    _ = try await engine.pull()
    let notYet = await adapter.count()
    XCTAssertEqual(notYet, 0, "judged again at a launch or by a click, not on every pull")
    let (restarted, _, _) = try await trustEngine(root: root, server: server, identity: mac, trust: list, adapter: adapter)
    _ = try await restarted.pull()
    let origin = await adapter.origin(of: theirs.opId)
    XCTAssertEqual(origin?.late, true)
    let left = try await restarted.refusedPacks()
    XCTAssertTrue(left.isEmpty)
  }

  /// Past the refused list only a count is kept, with the lowest unlisted position. "Check again" for everything
  /// reads the feed again from there: a pack past the list is still judged and applied once it checks.
  func testTrustReviewRefusedPacksPastTheListCanStillBeCheckedAgain() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), x = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let wrong = CloudSyncTestIdentity(deviceId: secondMac, seed: 9)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let list = try CloudSyncFixtureTrust([mac])
    let wrongKey = try wrong.jwk()
    await list.store(x.deviceId, key: wrongKey)
    let (engine, store, adapter) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: list)
    store.refusedRowLimit = 1
    let first = try op(entity: "listed", origin: x.deviceId), second = try op(entity: "past-the-list", origin: x.deviceId)
    try await commit([first], as: x, on: server, then: mac)    // 1
    try await commit([second], as: x, on: server, then: mac)   // 2
    _ = try await engine.pull()
    let listed = try await engine.refusedPacks(), beyond = try await engine.refusedBeyondList()
    XCTAssertEqual(listed.map(\.sequence), [CloudSequence(1)])
    XCTAssertEqual(beyond, 1)
    try await list.trust(x)
    let receipts = try await engine.checkRefusedAgain(sequence: nil)
    XCTAssertEqual(receipts.count, 2)
    let order = await adapter.appliedOrder()
    XCTAssertEqual(order, [first.opId, second.opId])
    let left = try await engine.refusedPacks(), none = try await engine.refusedBeyondList()
    XCTAssertTrue(left.isEmpty)
    XCTAssertEqual(none, 0)
  }

  // MARK: S4. A first upload is passed over entirely, for saved passwords too

  /// An account whose old first upload carries a saved-password part. A Mac of this version reads nothing of it
  /// and waits on nothing in it: saved passwords from the feed apply, and nothing is left "waiting to finish
  /// restoring".
  func testTrustReviewFirstUploadWithASavedPasswordPartStopsNothing() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), x = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId), protected = CloudSyncProtectedFixtureContent()
    let (publisher, _, _) = try await engine(root: scratch(), server: server)          // the switched-off machinery makes the first upload
    _ = try await publisher.bootstrap([feedSetup([try op(entity: "in-the-first-upload")])])
    let plain = try await server.checkpoint()
    let old = try XCTUnwrap(plain)
    try await server.installCheckpointForReview(CloudCheckpoint(checkpointId: old.checkpointId, throughSeq: old.throughSeq, root: old.root,
      secretsRoot: old.root, inventoryDigest: old.inventoryDigest, counts: old.counts, verifiedBy: old.verifiedBy))
    let secret = try await reviewProtectedOperation(protected)
    await server.switchDevice(x.deviceId)
    let senderList = try CloudSyncFixtureTrust([x])
    let (sender, _, _) = try await trustProtectedEngine(root: scratch(), server: server, identity: x, trust: senderList, content: protected)
    _ = try await sender.enqueue([secret])
    _ = try await sender.flush()                                                        // position 2
    await server.switchDevice(mac.deviceId)
    let list = try CloudSyncFixtureTrust([mac, x])
    let (reader, store, adapter) = try await trustProtectedEngine(root: scratch(), server: server, identity: mac, trust: list, content: protected)
    _ = try await reader.pull()
    let applied = await adapter.count()
    XCTAssertEqual(applied, 1, "the saved-password pack from the feed applied")
    XCTAssertEqual(try store.value("secretsSeq") as CloudSequence?, CloudSequence(2))
    XCTAssertEqual(try store.value("secretsPending") as Bool?, false)
    XCTAssertNil(try store.value("protectedFailure") as String?)
    let progress = try await reader.restoreProgress()
    XCTAssertEqual(progress.blocked, 0)
  }

  // MARK: S5. A parked record of a device that is no longer trusted blocks nothing

  /// A record of device X is parked (the adapter could not apply it); then X is stopped. A trusted device's later
  /// change to the same record applies at once instead of waiting behind it; the parked record is not retried
  /// while X is not trusted, and is retried once X is trusted again.
  func testTrustReviewParkedRecordOfAStoppedDeviceDoesNotBlockATrustedDevice() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), x = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let trusted = CloudSyncTestIdentity(deviceId: thirdMac, seed: 9)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let list = try CloudSyncFixtureTrust([mac, x, trusted])
    let (engine, store, adapter) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: list)
    let poison = try op(entity: "shared-note", text: "cannot be applied yet", origin: x.deviceId)
    let change = try op(entity: "shared-note", parents: [poison.opId], text: "changed on the trusted device", origin: trusted.deviceId)
    await adapter.refuse([poison.opId])
    try await commit([poison], as: x, on: server, then: mac)          // 1: parked
    _ = try await engine.pull()
    XCTAssertFalse(try store.rows("SELECT 1 FROM parked_ops LIMIT 1").isEmpty)
    await list.stop(x.deviceId)
    try await commit([change], as: trusted, on: server, then: mac)    // 2
    _ = try await engine.pull()
    var order = await adapter.appliedOrder()
    XCTAssertEqual(order, [change.opId], "nothing waits behind a stopped device's parked record")
    // The adapter could apply the parked record now, but its device is not trusted: it is not retried.
    await adapter.heal()
    try await engine.retryParked(domains: ["memory"])
    order = await adapter.appliedOrder()
    XCTAssertEqual(order, [change.opId])
    try await list.trust(x)
    try await engine.retryParked(domains: ["memory"])
    order = await adapter.appliedOrder()
    XCTAssertEqual(order, [change.opId, poison.opId])
    XCTAssertTrue(try store.rows("SELECT 1 FROM parked_ops LIMIT 1").isEmpty)
  }

  // MARK: S7. Waiting rows: a cap, nothing lost past it, and a pull that does not grow with them

  /// Past the list (500 devices; 1 here) a further unknown device gets no row: its packs are still not applied
  /// and only counted. Trusting such a device later still releases every one of its packs, in order, by reading
  /// the feed again from the lowest unlisted position.
  func testTrustReviewWaitingDevicePastTheListLosesNothingWhenTrusted() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), x = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let y = CloudSyncTestIdentity(deviceId: thirdMac, seed: 9)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let list = try CloudSyncFixtureTrust([mac])
    let root = try scratch()
    let (engine, store, adapter) = try await trustEngine(root: root, server: server, identity: mac, trust: list)
    store.heldRowLimit = 1
    let y1 = try op(entity: "y-1", origin: y.deviceId), y2 = try op(entity: "y-2", origin: y.deviceId)
    try await commit([op(entity: "x-1", origin: x.deviceId)], as: x, on: server, then: mac)   // 1: listed
    try await commit([y1], as: y, on: server, then: mac)                                       // 2: past the list
    try await commit([y2], as: y, on: server, then: mac)                                       // 3: past the list
    _ = try await engine.pull()
    let listed = try await engine.heldDevices(), beyond = try await engine.waitingBeyondList()
    XCTAssertEqual(listed.map(\.deviceId), [x.deviceId])
    XCTAssertEqual(beyond, 2)
    let none = await adapter.count()
    XCTAssertEqual(none, 0, "a pack past the list is still never applied")
    XCTAssertEqual(try store.value("brainSeq") as CloudSequence?, CloudSequence(3))

    let key = try y.jwk()
    try await list.trust(y)
    let receipts = try await engine.trustDevice(deviceId: y.deviceId, signKey: key)
    XCTAssertEqual(receipts.count, 2)
    var order = await adapter.appliedOrder()
    XCTAssertEqual(order, [y1.opId, y2.opId], "nothing was lost, and in feed order")
    let late = await adapter.origin(of: y1.opId)
    XCTAssertEqual(late?.late, true)
    let still = try await engine.heldDevices()
    XCTAssertEqual(still.map(\.deviceId), [x.deviceId], "the other device goes on waiting")

    // Also without a click and after a restart: the device's next pack is not applied before its older ones.
    let z = CloudSyncTestIdentity(deviceId: "66666666-6666-4666-8666-666666666666", seed: 10)
    let z1 = try op(entity: "z-1", origin: z.deviceId), z2 = try op(entity: "z-2", origin: z.deviceId)
    try await commit([z1], as: z, on: server, then: mac)                                       // 4: past the list
    _ = try await engine.pull()
    try await list.trust(z)
    try await commit([z2], as: z, on: server, then: mac)                                       // 5
    let (restarted, _, _) = try await trustEngine(root: root, server: server, identity: mac, trust: list, adapter: adapter)
    _ = try await restarted.pull()
    order = await adapter.appliedOrder()
    XCTAssertEqual(order, [y1.opId, y2.opId, z1.opId, z2.opId])
    let effects = await adapter.effectCount()
    XCTAssertEqual(effects, 4, "reading the feed again applied nothing twice")
  }

  /// A pull asks this Mac's list about a bounded number of waiting devices (8, in rotation), not about all of
  /// them, and still reaches every one within a few pulls.
  func testTrustReviewAPullAsksAboutAFewWaitingDevicesInRotation() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let list = try CloudSyncFixtureTrust([mac])
    let (engine, _, _) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: list)
    var unknown: [String] = []
    for index in 0..<12 {
      let other = CloudSyncTestIdentity(deviceId: UUID().uuidString.lowercased(), seed: UInt8(20 + index))
      try await commit([op(entity: "unknown-\(index)", origin: other.deviceId)], as: other, on: server, then: mac)
      unknown.append(other.deviceId)
    }
    _ = try await engine.pull()
    let waiting = try await engine.heldDevices()
    XCTAssertEqual(waiting.count, 12)
    let before = await list.askedFor().count
    _ = try await engine.pull()
    let afterOne = await list.askedFor()
    XCTAssertEqual(afterOne.count - before, CloudSyncEngine.releaseScanPerPull, "not one question per waiting row")
    _ = try await engine.pull()
    let afterTwo = await list.askedFor()
    XCTAssertEqual(afterTwo.count - before, 12)
    XCTAssertEqual(Set(afterTwo.suffix(12)), Set(unknown), "the rotation reached every waiting device")
  }

  // MARK: S9. Setup ends when its pages are stored; the baseline goes up by itself; this Mac pulls meanwhile

  /// Through the app's own path (the `deviceSigner:trust:` initialiser and the paged `bootstrap(sources:cut:)`).
  /// The day's allowance ends after the first of three baseline packs. Setup still returns; progress says how far
  /// the upload is; the setup barrier is gone, so a trusted device's pack is pulled and applied meanwhile; and
  /// after the allowance returns and the app restarted, an ordinary send finishes the baseline. Nobody runs the
  /// setup again.
  func testTrustReviewBaselineGoesUpByItselfAcrossAPauseAndARestartWhileThisMacPulls() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), other = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let list = try CloudSyncFixtureTrust([mac, other])
    let root = try scratch()
    let (engine, store, adapter) = try await trustEngine(root: root, server: server, identity: mac, trust: list)
    let notes = try (0..<600).map { try op(entity: "note-\($0)") }
    await adapter.setUp(with: notes)
    await server.pauseAllowance(of: mac.deviceId, afterCommits: 1)
    let cut = CloudSnapshotCut(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: ["fixture-source": "1"])
    let receipt = try await engine.bootstrap(sources: [adapter], cut: cut)
    XCTAssertFalse(receipt.published)
    let partway = try await engine.baselineProgress()
    XCTAssertEqual(partway?.total, 600)
    XCTAssertEqual(partway?.sent, 256, "one pack of the baseline went up before the allowance ended")
    XCTAssertNil(try store.value("bootstrapInProgress") as String?, "the setup barrier ended with the last page")
    XCTAssertNil(try store.value("baseline") as String?, "not settled while part of it is still here")
    let unfinished = try await engine.coverage(sourceId: "fixture-source")
    XCTAssertFalse(unfinished.complete)
    let notReady = try await engine.contextReady(projectId: "fixture-project")
    XCTAssertFalse(notReady.verified)

    // Meanwhile: a trusted device's pack is pulled and applied.
    let theirs = try op(entity: "from-the-other-mac", origin: other.deviceId)
    try await commit([theirs], as: other, on: server, then: mac)
    _ = try await engine.pull()
    let arrived = await adapter.origin(of: theirs.opId)
    XCTAssertEqual(arrived?.deviceId, other.deviceId)

    // The allowance returns; the app was restarted; an ordinary send finishes the baseline.
    await server.pauseAllowance(of: mac.deviceId, afterCommits: nil)
    let (restarted, sameStore, _) = try await trustEngine(root: root, server: server, identity: mac, trust: list, adapter: adapter)
    _ = try await restarted.flush()
    let finished = try await restarted.baselineProgress()
    XCTAssertNil(finished)
    XCTAssertEqual(try sameStore.value("baseline") as String?, "feed")
    XCTAssertEqual(try sameStore.queuedCount(), 0)
    let complete = try await restarted.coverage(sourceId: "fixture-source")
    XCTAssertTrue(complete.complete, "\(complete.blockedReasons)")
    let ready = try await restarted.contextReady(projectId: "fixture-project")
    XCTAssertTrue(ready.verified, "\(ready.missingSources)")
    let packs = await server.segmentCount(), checkpoint = try await server.checkpoint()
    XCTAssertEqual(packs, 4, "three baseline packs and the other Mac's")
    XCTAssertNil(checkpoint)
  }

  /// No answer from the service when setup ends (no network) does not fail the setup either: the pages are
  /// stored, the barrier ends, and the whole baseline goes up with the next send.
  func testTrustReviewSetupWithoutNetworkStillEndsAndUploadsLater() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let list = try CloudSyncFixtureTrust([mac])
    let (engine, store, adapter) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: list)
    await adapter.setUp(with: [try op(entity: "offline-note")])
    await server.setFailure(.unavailable)
    let cut = CloudSnapshotCut(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: ["fixture-source": "1"])
    _ = try await engine.bootstrap(sources: [adapter], cut: cut)
    let waiting = try await engine.baselineProgress()
    XCTAssertEqual(waiting?.sent, 0)
    XCTAssertEqual(waiting?.total, 1)
    XCTAssertNil(try store.value("bootstrapInProgress") as String?)
    await server.setFailure(nil)
    _ = try await engine.flush()
    let done = try await engine.baselineProgress()
    XCTAssertNil(done)
    XCTAssertEqual(try store.value("baseline") as String?, "feed")
  }

  // MARK: The app's own path: paged setup, send, pull, hold, release

  /// Two Macs built exactly as the app builds them (`deviceSigner:trust:`), set up through the paged call lane A
  /// uses. Each sends its baseline, holds the other's until trusted on THAT Mac, releases it, and a later note
  /// travels each way.
  func testTrustReviewAppPathPagedSetupSendPullHoldAndRelease() async throws {
    let a = CloudSyncTestIdentity(deviceId: device, seed: 7), b = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: a.deviceId)
    let listA = try CloudSyncFixtureTrust([a]), listB = try CloudSyncFixtureTrust([b])
    let (macA, _, adapterA) = try await trustEngine(root: scratch(), server: server, identity: a, trust: listA)
    let (macB, _, adapterB) = try await trustEngine(root: scratch(), server: server, identity: b, trust: listB)
    let noteA = try op(entity: "note-a"), noteB = try op(entity: "note-b", origin: b.deviceId)
    let keyA = try a.jwk(), keyB = try b.jwk()
    func cut() -> CloudSnapshotCut { .init(snapshotId: UUID().uuidString.lowercased(), at: 1000, watermarks: ["fixture-source": "1"]) }
    await adapterA.setUp(with: [noteA])
    _ = try await macA.bootstrap(sources: [adapterA], cut: cut())
    await server.switchDevice(b.deviceId)
    await adapterB.setUp(with: [noteB])
    _ = try await macB.bootstrap(sources: [adapterB], cut: cut())
    let waitingOnB = try await macB.heldDevices()
    XCTAssertEqual(waitingOnB.map(\.deviceId), [a.deviceId])
    try await listB.trust(a)
    _ = try await macB.trustDevice(deviceId: a.deviceId, signKey: keyA)
    var onB = await adapterB.appliedOrder()
    XCTAssertEqual(onB, [noteB.opId, noteA.opId])
    await server.switchDevice(a.deviceId)
    _ = try await macA.pull()
    try await listA.trust(b)
    _ = try await macA.trustDevice(deviceId: b.deviceId, signKey: keyB)
    var onA = await adapterA.appliedOrder()
    XCTAssertEqual(onA, [noteA.opId, noteB.opId])
    let laterA = try op(entity: "later-a")
    _ = try await macA.enqueue([laterA])
    _ = try await macA.flush()
    await server.switchDevice(b.deviceId)
    _ = try await macB.pull()
    onB = await adapterB.appliedOrder()
    XCTAssertEqual(onB.last, laterA.opId)
    let laterB = try op(entity: "later-b", origin: b.deviceId)
    _ = try await macB.enqueue([laterB])
    _ = try await macB.flush()
    await server.switchDevice(a.deviceId)
    _ = try await macA.pull()
    onA = await adapterA.appliedOrder()
    XCTAssertEqual(onA.last, laterB.opId)
    let readyA = try await macA.contextReady(projectId: "fixture-project")
    XCTAssertTrue(readyA.verified, "\(readyA.missingSources)")
    let progress = try await macA.baselineProgress()
    XCTAssertNil(progress)
  }

  // MARK: S2. The test seam does not ship

  /// The closure that stands in for the trusted list in the older tests exists in debug builds only: every line
  /// of the engine that names it lies inside `#if DEBUG`. (This test is compiled in a debug build, like all
  /// tests; it guards the fence itself.)
  func testTrustReviewTheTestSeamExistsInDebugBuildsOnly() throws {
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let text = try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckNativeCore/CloudSyncEngine.swift"), encoding: .utf8)
    var depth = 0, fenced = 0, outside: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed == "#if DEBUG" { depth += 1; continue }
      if trimmed == "#endif" { depth = max(0, depth - 1); continue }
      guard !trimmed.hasPrefix("//"), trimmed.contains(".seam") || trimmed.contains("case seam") || trimmed.contains("verifySignature") else { continue }
      if depth == 0 { outside.append(String(trimmed.prefix(80))) } else { fenced += 1 }
    }
    XCTAssertTrue(outside.isEmpty, "the seam must not exist in a release build: \(outside)")
    XCTAssertGreaterThan(fenced, 0)
  }
}
