import XCTest
import Foundation
@testable import TerminalDeckNativeCore

/// Device trust, the small core (cloud-lean-v1.md item 4; cloud-device-trust-design.md revision 2). Every test
/// runs the real engine as the app builds it (`trust:` = this Mac's stored trusted list) against the fixture
/// service, with real P-256 device keys.
extension CloudSyncTests {

  // MARK: C. Verification with no fallback: the signer decides

  /// A pack applies only if its signature checks under a key on THIS Mac's list. With no key for its device
  /// nothing of it is applied, downloaded or fetched from the service, although the service accepted the pack.
  func testTrustNothingAppliesWithoutAKeyOnThisMacsList() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), other = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let trust = try CloudSyncFixtureTrust([mac])
    let (engine, store, adapter) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: trust)
    let theirs = try op(entity: "from-the-other-mac", origin: other.deviceId)
    let segment = try await commit([theirs], as: other, on: server, then: mac)
    _ = try await engine.pull()
    let applied = await adapter.count()
    XCTAssertEqual(applied, 0)
    XCTAssertTrue(try store.operations().isEmpty)
    XCTAssertEqual(try store.value("brainSeq") as CloudSequence?, CloudSequence(1), "the position moved past the pack")
    let downloads = await server.segmentDownloadLog, deviceLists = await server.deviceListCalls
    XCTAssertFalse(downloads.contains(segment.descriptor.segmentId), "a pack that is not trusted is never downloaded")
    XCTAssertEqual(deviceLists, 0, "no key is ever fetched from the service")
    let asked = await trust.askedFor()
    XCTAssertEqual(asked, [other.deviceId])
    let refused = try await engine.refusedPacks()
    XCTAssertTrue(refused.isEmpty, "an unknown device is not a refusal")
  }

  /// "Own" is proved by signature, never by the device id: a pack the service attributes to THIS Mac but that
  /// does not check under this Mac's stored key is refused, recorded, never downloaded; the feed moves on and
  /// this Mac's real pack behind it applies.
  func testTrustForgedOwnPackIsRefusedAndTheFeedMovesOn() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), intruder = CloudSyncTestIdentity(deviceId: secondMac, seed: 9)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let trust = try CloudSyncFixtureTrust([mac])
    let (engine, store, adapter) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: trust)
    let forged = try op(entity: "forged", text: "not written on this Mac")
    let forgedSegment = try await commit([forged], as: mac, signedBy: intruder, on: server, then: mac)
    let genuine = try op(entity: "genuine")
    _ = try await engine.enqueue([genuine])
    _ = try await engine.flush()
    let order = await adapter.appliedOrder()
    XCTAssertEqual(order, [genuine.opId], "only the pack signed with this Mac's key applied")
    XCTAssertEqual(try store.value("brainSeq") as CloudSequence?, CloudSequence(2))
    XCTAssertEqual(try store.operations().map(\.opId), [genuine.opId])
    let refused = try await engine.refusedPacks()
    XCTAssertEqual(refused.count, 1)
    XCTAssertEqual(refused.first?.sequence, CloudSequence(1))
    XCTAssertEqual(refused.first?.deviceId, mac.deviceId)
    XCTAssertEqual(refused.first?.reason, CloudPackVerdict.badSignature)
    XCTAssertEqual(refused.first?.storageClass, .brain)
    XCTAssertEqual(refused.first?.checks, 1)
    let downloads = await server.segmentDownloadLog
    XCTAssertFalse(downloads.contains(forgedSegment.descriptor.segmentId))
    // A later pull does not meet the position again and does not stall.
    _ = try await engine.pull()
    let again = try await engine.refusedPacks()
    XCTAssertEqual(again.first?.checks, 1)
  }

  /// The same for a pack attributed to another TRUSTED device with a signature that is not that device's.
  func testTrustBadSignatureFromATrustedDeviceIsRefusedNotAStall() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), other = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let intruder = CloudSyncTestIdentity(deviceId: thirdMac, seed: 9)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let trust = try CloudSyncFixtureTrust([mac, other])
    let (engine, store, adapter) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: trust)
    try await commit([op(entity: "forged-as-other", origin: other.deviceId)], as: other, signedBy: intruder, on: server, then: mac)
    let real = try op(entity: "really-from-other", origin: other.deviceId)
    try await commit([real], as: other, on: server, then: mac)
    _ = try await engine.pull()
    let order = await adapter.appliedOrder()
    XCTAssertEqual(order, [real.opId])
    XCTAssertEqual(try store.value("brainSeq") as CloudSequence?, CloudSequence(2))
    let refused = try await engine.refusedPacks()
    XCTAssertEqual(refused.map(\.sequence), [CloudSequence(1)])
    XCTAssertEqual(refused.first?.deviceId, other.deviceId)
  }

  /// The origin handed to adapters is the verified signer. An operation inside the pack that names another
  /// device as its origin is display text: the pack is the signer's.
  func testTrustTheSignerIsTheOriginNotTheFieldInsideThePack() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), signer = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let trust = try CloudSyncFixtureTrust([mac, signer])
    let (engine, _, adapter) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: trust)
    let naming = try op(entity: "names-a-third-device", origin: thirdMac)
    try await commit([naming], as: signer, on: server, then: mac)
    _ = try await engine.pull()
    let origin = await adapter.origin(of: naming.opId)
    XCTAssertEqual(origin?.deviceId, signer.deviceId)
    XCTAssertEqual(origin?.sequence, CloudSequence(1))
    XCTAssertNil(origin?.late)
  }

  // MARK: D. HELD: untouched, apart, never stops the feed, never built on

  /// Proof P1. Packs of a device this Mac has not trusted wait untouched (never downloaded, opened, merged or
  /// shown to the adapter) in their own table, one row per device with its first waiting position and the
  /// reported counts. The feed position moves on, a trusted device's packs between and behind them apply in the
  /// same pull, nothing is parked or queued because of them, and this Mac stays ready with complete coverage.
  func testTrustUnknownDeviceIsHeldWhileATrustedDevicesPacksApply() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), trusted = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let unknown = CloudSyncTestIdentity(deviceId: thirdMac, seed: 9)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let trust = try CloudSyncFixtureTrust([mac, trusted])
    let (engine, store, adapter) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: trust)
    let own = try op(entity: "own-note")
    _ = try await engine.bootstrap([feedSetup([own])])                                                   // position 1
    let u1 = try op(entity: "unknown-1", origin: unknown.deviceId), t1 = try op(entity: "trusted-1", origin: trusted.deviceId)
    let u2 = try op(entity: "unknown-2", origin: unknown.deviceId), u3 = try op(entity: "unknown-3", origin: unknown.deviceId)
    let t2 = try op(entity: "trusted-2", origin: trusted.deviceId)
    let firstWaiting = try await commit([u1], as: unknown, on: server, then: mac)                         // 2
    try await commit([t1], as: trusted, on: server, then: mac)                                           // 3
    let secondWaiting = try await commit([u2, u3], as: unknown, on: server, then: mac)                    // 4
    try await commit([t2], as: trusted, on: server, then: mac)                                           // 5
    _ = try await engine.pull()

    let order = await adapter.appliedOrder()
    XCTAssertEqual(order, [own.opId, t1.opId, t2.opId], "the trusted device's changes were not delayed")
    XCTAssertEqual(try store.value("brainSeq") as CloudSequence?, CloudSequence(5), "the feed did not stop")
    let waiting = try await engine.heldDevices()
    XCTAssertEqual(waiting.count, 1)
    XCTAssertEqual(waiting.first?.deviceId, unknown.deviceId)
    XCTAssertEqual(waiting.first?.firstHeldSeq, CloudSequence(2))
    XCTAssertNil(waiting.first?.firstHeldSecretsSeq)
    XCTAssertEqual(waiting.first?.packs, 2)
    XCTAssertEqual(waiting.first?.operations, 3)
    XCTAssertEqual(waiting.first?.byDomain, [CloudHeldDomainCount(domain: "memory", packs: 2, operations: 3)])
    XCTAssertEqual(waiting.first?.counting, false)

    // Untouched: never downloaded, no record, no head, nothing parked, queued or refused.
    let downloads = await server.segmentDownloadLog
    XCTAssertFalse(downloads.contains(firstWaiting.descriptor.segmentId))
    XCTAssertFalse(downloads.contains(secondWaiting.descriptor.segmentId))
    XCTAssertEqual(Set(try store.operations().map(\.opId)), [own.opId, t1.opId, t2.opId])
    XCTAssertTrue(try store.rows("SELECT revision FROM entity_heads WHERE entityId IN (?,?,?)", [Data("unknown-1".utf8), Data("unknown-2".utf8), Data("unknown-3".utf8)]).isEmpty)
    for table in ["parked_ops", "parked_packs", "parked_sends", "prepare_journal", "refused_packs"] {
      XCTAssertTrue(try store.rows("SELECT 1 FROM " + table + " LIMIT 1").isEmpty, table)
    }
    XCTAssertEqual(try store.queuedCount(), 0)

    // Waiting packs are no gap: this Mac is ready and its coverage is complete.
    let ready = try await engine.contextReady(projectId: "fixture-project")
    XCTAssertTrue(ready.verified, "\(ready.missingSources)")
    let coverage = try await engine.coverage(sourceId: "fixture-source")
    XCTAssertTrue(coverage.complete, "\(coverage.blockedReasons)")
    let progress = try await engine.restoreProgress()
    XCTAssertEqual(progress.blocked, 0)

    // Nothing was published from or about the waiting material: no checkpoint, only the five packs.
    let checkpoint = try await server.checkpoint()
    XCTAssertNil(checkpoint)
    let packs = await server.segmentCount(), objects = await server.objectCount()
    XCTAssertEqual(packs, 5)
    XCTAssertEqual(objects, 0)

    // A later pull meets nothing again: the counts do not grow.
    _ = try await engine.pull()
    let later = try await engine.heldDevices()
    XCTAssertEqual(later.first?.packs, 2)
  }

  /// This Mac's own device id without an entry on its trusted list is not special either: its own pack coming
  /// back through the feed waits like any untrusted device's (own is proved by signature, never assumed).
  func testTrustOwnPackWithoutAnOwnEntryWaitsLikeAnyOther() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let trust = try CloudSyncFixtureTrust([])
    let (engine, store, adapter) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: trust)
    _ = try await engine.enqueue([try op(entity: "own")])
    _ = try await engine.flush()
    let applied = await adapter.count()
    XCTAssertEqual(applied, 0)
    XCTAssertEqual(try store.value("brainSeq") as CloudSequence?, CloudSequence(1))
    let waiting = try await engine.heldDevices()
    XCTAssertEqual(waiting.map(\.deviceId), [mac.deviceId])
  }

  /// This Mac never builds on waiting material. The first-upload machinery (switched off in this version) and the
  /// coverage records it sends are blocked while any pack waits, by the same kind of guard as a parked conflict.
  func testTrustNothingIsPublishedWhileAnyPackWaits() async throws {
    let server = try CloudSyncFixtureServer(root: scratch(), device: device)
    let (publisher, store, adapter) = try await engine(root: scratch(), server: server)
    await adapter.report(complete: false, gaps: ["Some notes could not be read."])
    let setup = feedSetup([try op(entity: "with-a-gap")], complete: false, gaps: ["Some notes could not be read."])
    try store.hold(deviceId: secondMac, seq: CloudSequence(1), storageClass: .brain, domains: ["memory"], operations: 1)
    do { _ = try await publisher.bootstrap([setup]); XCTFail("An inventory was published while a pack waited") }
    catch { XCTAssertEqual(error as? CloudFailure, .unavailable) }
    let blocked = try await server.checkpoint(), uploaded = await server.objectCount()
    XCTAssertNil(blocked)
    XCTAssertEqual(uploaded, 0)
    let reasons = try await publisher.coverage(sourceId: "fixture-source").blockedReasons
    XCTAssertTrue(reasons.contains { $0.contains("not trusted on this Mac") }, "\(reasons)")

    // Nothing waits any more: the same setup publishes.
    try store.execute("DELETE FROM untrusted_devices")
    _ = try await publisher.bootstrap([setup])
    let published = try await server.checkpoint()
    XCTAssertNotNil(published)

    // The gap heals while a pack waits: no coverage record is sent. Once nothing waits, it is.
    try store.hold(deviceId: secondMac, seq: CloudSequence(1), storageClass: .brain, domains: ["memory"], operations: 1)
    await adapter.report(complete: true)
    try await publisher.retryParked(domains: ["memory"])
    _ = try await publisher.flush()
    let whileWaiting = await server.segmentCount()
    XCTAssertEqual(whileWaiting, 0)
    try store.execute("DELETE FROM untrusted_devices")
    try await publisher.retryParked(domains: ["memory"])
    _ = try await publisher.flush()
    let afterwards = await server.segmentCount()
    XCTAssertEqual(afterwards, 1)
  }

  // MARK: E. Trust at apply time, and release (R1, R6)

  /// Proof P2, first half. After the person trusts two waiting devices in one action their packs are read again
  /// from the first waiting position and applied in ORIGINAL feed order across both devices, as late arrivals
  /// that keep their original device, position and commit time. This Mac's position does not move back, and the
  /// next pack of such a device applies in order, not late.
  func testTrustReleaseAppliesWaitingPacksInOriginalFeedOrderAsLateArrivals() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), trusted = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let x = CloudSyncTestIdentity(deviceId: thirdMac, seed: 9), y = CloudSyncTestIdentity(deviceId: "66666666-6666-4666-8666-666666666666", seed: 10)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let trust = try CloudSyncFixtureTrust([mac, trusted])
    let (engine, store, adapter) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: trust)
    let x1 = try op(entity: "x-1", origin: x.deviceId), y1 = try op(entity: "y-1", origin: y.deviceId)
    let t1 = try op(entity: "t-1", origin: trusted.deviceId)
    let x2 = try op(entity: "x-2", origin: x.deviceId), y2 = try op(entity: "y-2", origin: y.deviceId)
    try await commit([x1], as: x, on: server, then: mac)        // 1
    try await commit([y1], as: y, on: server, then: mac)        // 2
    try await commit([t1], as: trusted, on: server, then: mac)  // 3
    try await commit([x2], as: x, on: server, then: mac)        // 4
    try await commit([y2], as: y, on: server, then: mac)        // 5
    _ = try await engine.pull()
    let before = await adapter.appliedOrder()
    XCTAssertEqual(before, [t1.opId])
    let waiting = try await engine.heldDevices()
    XCTAssertEqual(waiting.map(\.deviceId).sorted(), [x.deviceId, y.deviceId].sorted())
    XCTAssertEqual(waiting.map(\.packs), [2, 2])

    // The person's click on this Mac: both keys are stored, then one release for both.
    try await trust.trust(x)
    try await trust.trust(y)
    let receipts = try await engine.releaseHeld(deviceIds: [y.deviceId, x.deviceId])
    XCTAssertEqual(receipts.count, 4)
    let order = await adapter.appliedOrder()
    XCTAssertEqual(order, [t1.opId, x1.opId, y1.opId, x2.opId, y2.opId], "original feed order across both devices")
    let first = await adapter.origin(of: x1.opId), last = await adapter.origin(of: y2.opId)
    XCTAssertEqual(first, CloudImportOrigin(deviceId: x.deviceId, sequence: CloudSequence(1), committedAt: 1000, late: true))
    XCTAssertEqual(last, CloudImportOrigin(deviceId: y.deviceId, sequence: CloudSequence(5), committedAt: 1000, late: true))
    let inOrder = await adapter.origin(of: t1.opId)
    XCTAssertNil(inOrder?.late)
    let after = try await engine.heldDevices()
    XCTAssertTrue(after.isEmpty)
    XCTAssertEqual(try store.value("brainSeq") as CloudSequence?, CloudSequence(5), "the position did not move back")
    XCTAssertTrue(try store.rows("SELECT 1 FROM parked_ops LIMIT 1").isEmpty)
    XCTAssertTrue(try store.rows("SELECT 1 FROM prepare_journal LIMIT 1").isEmpty)

    // Trusted now: the next pack applies in order and is not late; nothing is applied twice.
    let x3 = try op(entity: "x-3", origin: x.deviceId)
    try await commit([x3], as: x, on: server, then: mac)        // 6
    _ = try await engine.pull()
    let next = await adapter.origin(of: x3.opId), effects = await adapter.effectCount()
    XCTAssertEqual(next?.deviceId, x.deviceId)
    XCTAssertNil(next?.late)
    XCTAssertEqual(effects, 6)
  }

  /// The release also starts by itself: a device trusted on this Mac's list is released at the next pull, before
  /// its newer pack in that same pull is applied (R6), without any call from the wiring.
  func testTrustReleaseRunsBeforeANewerPackOfThatDeviceIsApplied() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), x = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let trust = try CloudSyncFixtureTrust([mac])
    let (engine, _, adapter) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: trust)
    let older = try op(entity: "note", text: "older", origin: x.deviceId)
    let newer = try op(entity: "note", parents: [older.opId], text: "newer", origin: x.deviceId)
    try await commit([older], as: x, on: server, then: mac)   // 1
    _ = try await engine.pull()
    try await trust.trust(x)
    try await commit([newer], as: x, on: server, then: mac)   // 2
    _ = try await engine.pull()
    let order = await adapter.appliedOrder()
    XCTAssertEqual(order, [older.opId, newer.opId], "the waiting older pack went first")
    let late = await adapter.origin(of: older.opId), inOrder = await adapter.origin(of: newer.opId)
    XCTAssertEqual(late?.late, true)
    XCTAssertNil(inOrder?.late)
    let waiting = try await engine.heldDevices()
    XCTAssertTrue(waiting.isEmpty)
  }

  /// R1 and "check again". A trust click releases only when this Mac's list holds exactly the key the person
  /// compared. A list holding another key verifies nothing: the pack is then refused, not applied, and once the
  /// right key is stored "check again" applies it as a late arrival.
  func testTrustClickNeedsTheComparedKeyAndCheckAgainAppliesOnceItChecks() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), x = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let other = CloudSyncTestIdentity(deviceId: secondMac, seed: 9)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let trust = try CloudSyncFixtureTrust([mac])
    let (engine, store, adapter) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: trust)
    let theirs = try op(entity: "from-x", origin: x.deviceId)
    try await commit([theirs], as: x, on: server, then: mac)
    _ = try await engine.pull()
    let compared = try x.jwk()
    // Not on the list yet: nothing is released.
    do { _ = try await engine.trustDevice(deviceId: x.deviceId, signKey: compared); XCTFail("Released without a stored key") }
    catch { XCTAssertEqual(error as? CloudFailure, .versionChanged) }
    // The list holds a key the person did not compare: nothing is released by the click.
    let notCompared = try other.jwk()
    await trust.store(x.deviceId, key: notCompared)
    do { _ = try await engine.trustDevice(deviceId: x.deviceId, signKey: compared); XCTFail("Released under another key") }
    catch { XCTAssertEqual(error as? CloudFailure, .versionChanged) }
    var applied = await adapter.count()
    XCTAssertEqual(applied, 0)
    let stillWaiting = try await engine.heldDevices()
    XCTAssertEqual(stillWaiting.map(\.deviceId), [x.deviceId])
    // With that other key on the list the pack does not check: refused, not applied, no longer waiting.
    _ = try await engine.pull()
    applied = await adapter.count()
    XCTAssertEqual(applied, 0)
    let refused = try await engine.refusedPacks()
    XCTAssertEqual(refused.map(\.sequence), [CloudSequence(1)])
    XCTAssertEqual(refused.first?.reason, CloudPackVerdict.badSignature)
    let noneWaiting = try await engine.heldDevices()
    XCTAssertTrue(noneWaiting.isEmpty)
    // Checking again with the same wrong key changes nothing but the count.
    _ = try await engine.checkRefusedAgain(sequence: nil)
    let recheck = try await engine.refusedPacks()
    XCTAssertEqual(recheck.first?.checks, 2)
    // The compared key is stored: the click passes, and "check again" applies the pack as a late arrival.
    try await trust.trust(x)
    _ = try await engine.trustDevice(deviceId: x.deviceId, signKey: compared)
    let receipts = try await engine.checkRefusedAgain(sequence: CloudSequence(1))
    XCTAssertEqual(receipts.count, 1)
    let origin = await adapter.origin(of: theirs.opId)
    XCTAssertEqual(origin, CloudImportOrigin(deviceId: x.deviceId, sequence: CloudSequence(1), committedAt: 1000, late: true))
    let left = try await engine.refusedPacks()
    XCTAssertTrue(left.isEmpty)
    XCTAssertEqual(try store.value("brainSeq") as CloudSequence?, CloudSequence(1))
  }

  /// Removing trust holds the device's future packs again; what was applied stays; trusting it again releases
  /// them at the next pull.
  func testTrustRemovedHoldsFuturePacksAgainAndWhatWasAppliedStays() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), x = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let trust = try CloudSyncFixtureTrust([mac, x])
    let (engine, _, adapter) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: trust)
    let whileTrusted = try op(entity: "while-trusted", origin: x.deviceId), afterStop = try op(entity: "after-stop", origin: x.deviceId)
    try await commit([whileTrusted], as: x, on: server, then: mac)
    _ = try await engine.pull()
    await trust.stop(x.deviceId)
    try await commit([afterStop], as: x, on: server, then: mac)
    _ = try await engine.pull()
    var order = await adapter.appliedOrder()
    XCTAssertEqual(order, [whileTrusted.opId])
    let waiting = try await engine.heldDevices()
    XCTAssertEqual(waiting.first?.firstHeldSeq, CloudSequence(2))
    XCTAssertEqual(waiting.first?.packs, 1)
    try await trust.trust(x)
    _ = try await engine.pull()
    order = await adapter.appliedOrder()
    XCTAssertEqual(order, [whileTrusted.opId, afterStop.opId])
    let released = await adapter.origin(of: afterStop.opId)
    XCTAssertEqual(released?.late, true)
  }

  /// Trust is read at the moment of applying: a pack prepared while its device was trusted is not applied once
  /// the person stopped the device in between. What was prepared is dropped and the pack waits.
  func testTrustRemovedBetweenPrepareAndApplyHoldsThePack() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), x = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let trust = try CloudSyncFixtureTrust([mac, x])
    let (engine, store, adapter) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: trust)
    let theirs = try op(entity: "prepared-then-stopped", origin: x.deviceId)
    try await commit([theirs], as: x, on: server, then: mac)
    await adapter.afterNextValidation { await trust.stop(x.deviceId) }
    _ = try await engine.pull()
    let applied = await adapter.count()
    XCTAssertEqual(applied, 0)
    XCTAssertTrue(try store.rows("SELECT 1 FROM prepare_journal LIMIT 1").isEmpty, "what was prepared was dropped")
    XCTAssertTrue(try store.operations().isEmpty)
    XCTAssertEqual(try store.value("brainSeq") as CloudSequence?, CloudSequence(1))
    let waiting = try await engine.heldDevices()
    XCTAssertEqual(waiting.map(\.deviceId), [x.deviceId])
    XCTAssertEqual(waiting.first?.packs, 1)
  }

  /// The same across a restart: a pack left prepared in the journal by a crash is judged again when it is read
  /// again; its device was stopped meanwhile, so the journal entry is dropped and the pack waits.
  func testTrustStoppedDeviceIsHeldWhenAPreparedPackIsReplayedAfterARestart() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), x = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let trust = try CloudSyncFixtureTrust([mac, x])
    let root = try scratch(), kill = CloudSyncTrustKillSwitch()
    let (crashing, firstStore, adapter) = try await trustEngine(root: root, server: server, identity: mac, trust: trust, fault: { try kill.check($0) })
    try await commit([op(entity: "prepared-before-the-crash", origin: x.deviceId)], as: x, on: server, then: mac)
    kill.failAtApply(1)
    do { _ = try await crashing.pull(); XCTFail("The apply was not interrupted") } catch {}
    XCTAssertFalse(try firstStore.rows("SELECT 1 FROM prepare_journal LIMIT 1").isEmpty)
    XCTAssertNil(try firstStore.value("brainSeq") as CloudSequence?)
    await trust.stop(x.deviceId)
    let (restarted, store, _) = try await trustEngine(root: root, server: server, identity: mac, trust: trust, adapter: adapter)
    _ = try await restarted.pull()
    XCTAssertTrue(try store.rows("SELECT 1 FROM prepare_journal LIMIT 1").isEmpty)
    XCTAssertEqual(try store.value("brainSeq") as CloudSequence?, CloudSequence(1))
    XCTAssertTrue(try store.operations().isEmpty, "the sync store holds nothing of the stopped device's pack")
    let waiting = try await restarted.heldDevices()
    XCTAssertEqual(waiting.map(\.deviceId), [x.deviceId])
  }

  // MARK: F. Through the real engine: restart in a release, the same record, saved passwords

  /// Proof P2, second half. A release interrupted in the middle (a crash after the adapter applied the second of
  /// three waiting packs) resumes FIRST after the restart, from where it stopped: the rest is applied late, in
  /// order, nothing twice, and only then the device's newer pack, which arrived meanwhile.
  func testTrustRestartInTheMiddleOfAReleaseResumesItBeforeAnythingNewer() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), x = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let trust = try CloudSyncFixtureTrust([mac])
    let root = try scratch(), kill = CloudSyncTrustKillSwitch()
    let (crashing, firstStore, adapter) = try await trustEngine(root: root, server: server, identity: mac, trust: trust, fault: { try kill.check($0) })
    let x1 = try op(entity: "x-1", origin: x.deviceId), x2 = try op(entity: "x-2", origin: x.deviceId), x3 = try op(entity: "x-3", origin: x.deviceId)
    try await commit([x1], as: x, on: server, then: mac)   // 1
    try await commit([x2], as: x, on: server, then: mac)   // 2
    try await commit([x3], as: x, on: server, then: mac)   // 3
    _ = try await crashing.pull()
    try await trust.trust(x)
    kill.failAtApply(2)
    do { _ = try await crashing.releaseHeld(deviceIds: [x.deviceId]); XCTFail("The release was not interrupted") } catch {}
    let interrupted = try await crashing.heldDevices()
    XCTAssertEqual(interrupted.first?.firstHeldSeq, CloudSequence(2), "the row moved forward with the pass")
    XCTAssertEqual(interrupted.first?.packs, 2)
    XCTAssertFalse(try firstStore.rows("SELECT 1 FROM prepare_journal LIMIT 1").isEmpty)
    // Meanwhile the device sends something newer.
    let x4 = try op(entity: "x-4", origin: x.deviceId)
    try await commit([x4], as: x, on: server, then: mac)   // 4

    let (restarted, store, _) = try await trustEngine(root: root, server: server, identity: mac, trust: trust, adapter: adapter)
    _ = try await restarted.pull()
    let order = await adapter.appliedOrder(), effects = await adapter.effectCount()
    XCTAssertEqual(order, [x1.opId, x2.opId, x3.opId, x4.opId], "the release finished before the newer pack")
    XCTAssertEqual(effects, 4, "nothing was applied twice")
    let resumed = await adapter.origin(of: x3.opId), newer = await adapter.origin(of: x4.opId)
    XCTAssertEqual(resumed?.late, true)
    XCTAssertEqual(resumed?.sequence, CloudSequence(3))
    XCTAssertNil(newer?.late)
    let waiting = try await restarted.heldDevices()
    XCTAssertTrue(waiting.isEmpty)
    XCTAssertEqual(try store.value("brainSeq") as CloudSequence?, CloudSequence(4))
    XCTAssertTrue(try store.rows("SELECT 1 FROM prepare_journal LIMIT 1").isEmpty)
    XCTAssertEqual(Set(try store.operations().map(\.opId)), [x1.opId, x2.opId, x3.opId, x4.opId])
  }

  /// A waiting device's version of a record blocks nothing: a trusted device's later change to the SAME record,
  /// naming the waiting version as its parent, applies at once, and so does the change after it (a parked record
  /// would make both wait). Released later, the waiting version arrives late and stays the older one.
  func testTrustWaitingVersionOfARecordDoesNotBlockATrustedDevicesLaterChange() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), trusted = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let waitingDevice = CloudSyncTestIdentity(deviceId: thirdMac, seed: 9)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let trust = try CloudSyncFixtureTrust([mac, trusted])
    let (engine, store, adapter) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: trust)
    let base = try op(entity: "shared-note", text: "written on the waiting device", origin: waitingDevice.deviceId)
    let change = try op(entity: "shared-note", parents: [base.opId], text: "changed on the trusted device", origin: trusted.deviceId)
    let again = try op(entity: "shared-note", parents: [change.opId], text: "changed again", origin: trusted.deviceId)
    try await commit([base], as: waitingDevice, on: server, then: mac)   // 1
    try await commit([change], as: trusted, on: server, then: mac)       // 2
    try await commit([again], as: trusted, on: server, then: mac)        // 3
    _ = try await engine.pull()
    var order = await adapter.appliedOrder()
    XCTAssertEqual(order, [change.opId, again.opId])
    XCTAssertTrue(try store.rows("SELECT 1 FROM parked_ops LIMIT 1").isEmpty, "nothing waits behind a waiting pack")
    func heads() throws -> [String] {
      try store.rows("SELECT revision FROM entity_heads WHERE entityId=?", [Data("shared-note".utf8)]).map { String(decoding: $0[0], as: UTF8.self) }
    }
    XCTAssertEqual(try heads(), [again.opId], "the waiting version is no head, parent or base here")

    try await trust.trust(waitingDevice)
    let compared = try waitingDevice.jwk()
    _ = try await engine.trustDevice(deviceId: waitingDevice.deviceId, signKey: compared)
    order = await adapter.appliedOrder()
    XCTAssertEqual(order, [change.opId, again.opId, base.opId])
    let late = await adapter.origin(of: base.opId)
    XCTAssertEqual(late, CloudImportOrigin(deviceId: waitingDevice.deviceId, sequence: CloudSequence(1), committedAt: 1000, late: true))
    XCTAssertEqual(try heads(), [again.opId], "released late, it is still the older version")
  }

  /// Saved passwords follow the same table with their own position: a saved-password pack of an untrusted device
  /// waits at firstHeldSecretsSeq, never opened, and is released once the device is trusted.
  func testTrustWaitingSavedPasswordPackHasItsOwnPositionAndIsReleased() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), x = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: x.deviceId), protected = CloudSyncProtectedFixtureContent()
    let operation = try await reviewProtectedOperation(protected)
    let senderList = try CloudSyncFixtureTrust([x])
    let (sender, _, _) = try await trustProtectedEngine(root: scratch(), server: server, identity: x, trust: senderList, content: protected)
    _ = try await sender.enqueue([operation])
    _ = try await sender.flush()
    await server.switchDevice(mac.deviceId)
    let trust = try CloudSyncFixtureTrust([mac])
    let (reader, store, adapter) = try await trustProtectedEngine(root: scratch(), server: server, identity: mac, trust: trust, content: protected)
    let openedBefore = await protected.openedIds().count
    _ = try await reader.pull()
    var applied = await adapter.count()
    XCTAssertEqual(applied, 0)
    let openedWhileWaiting = await protected.openedIds().count
    XCTAssertEqual(openedWhileWaiting, openedBefore, "a waiting saved-password pack is never opened")
    XCTAssertEqual(try store.value("secretsSeq") as CloudSequence?, CloudSequence(1), "the saved-password position moved on")
    let waiting = try await reader.heldDevices()
    XCTAssertEqual(waiting.first?.deviceId, x.deviceId)
    XCTAssertNil(waiting.first?.firstHeldSeq)
    XCTAssertEqual(waiting.first?.firstHeldSecretsSeq, CloudSequence(1))
    XCTAssertEqual(waiting.first?.byDomain, [CloudHeldDomainCount(domain: "api-key", packs: 1, operations: 1)])
    let deviceLists = await server.deviceListCalls
    XCTAssertEqual(deviceLists, 0, "no key is fetched from the service for a saved-password pack either")

    try await trust.trust(x)
    _ = try await reader.pull()
    applied = await adapter.count()
    XCTAssertEqual(applied, 1)
    let origin = await adapter.origin(of: operation.opId)
    XCTAssertEqual(origin?.deviceId, x.deviceId)
    XCTAssertEqual(origin?.late, true)
    let none = try await reader.heldDevices()
    XCTAssertTrue(none.isEmpty)
  }

  /// A release reads the feed again page by page: more waiting packs than one feed page (128) are all applied,
  /// in feed order, and none is lost at the page boundary.
  func testTrustReleaseOfMoreWaitingPacksThanOneFeedPageLosesNone() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), x = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let trust = try CloudSyncFixtureTrust([mac])
    let (engine, store, adapter) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: trust)
    var sent: [String] = []
    for index in 0..<135 {
      let operation = try op(entity: "waiting-\(index)", origin: x.deviceId)
      try await commit([operation], as: x, on: server, then: mac)
      sent.append(operation.opId)
    }
    _ = try await engine.pull()
    let waiting = try await engine.heldDevices()
    XCTAssertEqual(waiting.first?.packs, 135)
    XCTAssertEqual(waiting.first?.firstHeldSeq, CloudSequence(1))
    let none = await adapter.count()
    XCTAssertEqual(none, 0)
    try await trust.trust(x)
    let receipts = try await engine.releaseHeld(deviceIds: [x.deviceId])
    XCTAssertEqual(receipts.count, 135)
    let order = await adapter.appliedOrder()
    XCTAssertEqual(order, sent)
    let after = try await engine.heldDevices()
    XCTAssertTrue(after.isEmpty)
    XCTAssertEqual(try store.value("brainSeq") as CloudSequence?, CloudSequence(135))
  }

  /// The lean first version end to end at the sync core (proof P3 without the app): a fresh account, two Macs,
  /// no first upload. Each Mac sets up, each holds the other's baseline until the person trusts that device on
  /// THAT Mac, then both hold both baselines, and a note written on either appears on the other.
  func testTrustTwoMacsOnAFreshAccountTrustEachOtherAndSyncBothWays() async throws {
    let a = CloudSyncTestIdentity(deviceId: device, seed: 7), b = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: a.deviceId)
    let listA = try CloudSyncFixtureTrust([a]), listB = try CloudSyncFixtureTrust([b])
    let (macA, _, adapterA) = try await trustEngine(root: scratch(), server: server, identity: a, trust: listA)
    let (macB, _, adapterB) = try await trustEngine(root: scratch(), server: server, identity: b, trust: listB)
    let noteA = try op(entity: "note-a", text: "baseline of A"), noteB = try op(entity: "note-b", text: "baseline of B", origin: b.deviceId)
    let keyA = try a.jwk(), keyB = try b.jwk()

    _ = try await macA.bootstrap([feedSetup([noteA])])               // position 1
    await server.switchDevice(b.deviceId)
    _ = try await macB.bootstrap([feedSetup([noteB])])               // A's pack waits on B; B's baseline is position 2
    var onB = await adapterB.appliedOrder()
    XCTAssertEqual(onB, [noteB.opId])
    let sheetOnB = try await macB.heldDevices()
    XCTAssertEqual(sheetOnB.map(\.deviceId), [a.deviceId])
    XCTAssertEqual(sheetOnB.first?.packs, 1)
    await server.switchDevice(a.deviceId)
    _ = try await macA.pull()
    var onA = await adapterA.appliedOrder()
    XCTAssertEqual(onA, [noteA.opId])
    let rowOnA = try await macA.heldDevices()
    XCTAssertEqual(rowOnA.map(\.deviceId), [b.deviceId])

    // The person trusts A on B, in B's window. Trust on B does nothing on A.
    await server.switchDevice(b.deviceId)
    try await listB.trust(a)
    _ = try await macB.trustDevice(deviceId: a.deviceId, signKey: keyA)
    onB = await adapterB.appliedOrder()
    XCTAssertEqual(onB, [noteB.opId, noteA.opId])
    await server.switchDevice(a.deviceId)
    _ = try await macA.pull()
    onA = await adapterA.appliedOrder()
    XCTAssertEqual(onA, [noteA.opId], "trust given on B is not trust on A")
    // Then B on A, in A's window.
    try await listA.trust(b)
    _ = try await macA.trustDevice(deviceId: b.deviceId, signKey: keyB)
    onA = await adapterA.appliedOrder()
    XCTAssertEqual(onA, [noteA.opId, noteB.opId])

    // A note written on A appears on B, and one written on B appears on A, in order and not late.
    let laterA = try op(entity: "later-a", text: "written on A")
    _ = try await macA.enqueue([laterA])
    _ = try await macA.flush()
    await server.switchDevice(b.deviceId)
    _ = try await macB.pull()
    let arrivedOnB = await adapterB.origin(of: laterA.opId)
    XCTAssertEqual(arrivedOnB?.deviceId, a.deviceId)
    XCTAssertNil(arrivedOnB?.late)
    let laterB = try op(entity: "later-b", text: "written on B", origin: b.deviceId)
    _ = try await macB.enqueue([laterB])
    _ = try await macB.flush()
    let readyB = try await macB.contextReady(projectId: "fixture-project")
    XCTAssertTrue(readyB.verified, "\(readyB.missingSources)")
    await server.switchDevice(a.deviceId)
    _ = try await macA.pull()
    let arrivedOnA = await adapterA.origin(of: laterB.opId)
    XCTAssertEqual(arrivedOnA?.deviceId, b.deviceId)
    let readyA = try await macA.contextReady(projectId: "fixture-project")
    XCTAssertTrue(readyA.verified, "\(readyA.missingSources)")
    let totalA = await adapterA.count(), totalB = await adapterB.count()
    XCTAssertEqual(totalA, 4)
    XCTAssertEqual(totalB, 4)
    let checkpoint = try await server.checkpoint(), packs = await server.segmentCount()
    XCTAssertNil(checkpoint, "no first upload, on either Mac")
    XCTAssertEqual(packs, 4)
    let emptyA = try await macA.heldDevices(), emptyB = try await macB.heldDevices()
    XCTAssertTrue(emptyA.isEmpty)
    XCTAssertTrue(emptyB.isEmpty)
  }

  /// A service that serves a pack again at a new feed position used to stop a Mac for good. Now the repeat, which
  /// verifies but repeats what this Mac already applied, is refused with its reason, nothing is applied twice,
  /// and the feed moves on to the next pack.
  func testTrustRepeatedPackIdAtANewPositionIsRefusedAndTheFeedMovesOn() async throws {
    let mac = CloudSyncTestIdentity(deviceId: device, seed: 7), trusted = CloudSyncTestIdentity(deviceId: secondMac, seed: 8)
    let server = try CloudSyncFixtureServer(root: scratch(), device: mac.deviceId)
    let trust = try CloudSyncFixtureTrust([mac, trusted])
    let (engine, store, adapter) = try await trustEngine(root: scratch(), server: server, identity: mac, trust: trust)
    let first = try op(entity: "first", origin: trusted.deviceId), next = try op(entity: "next", origin: trusted.deviceId)
    let segment = try await commit([first], as: trusted, on: server, then: mac)   // 1
    _ = try await engine.pull()
    try await server.repeatPack(segment.descriptor.segmentId)                      // 2: the same pack again
    try await commit([next], as: trusted, on: server, then: mac)                   // 3
    _ = try await engine.pull()
    let order = await adapter.appliedOrder(), effects = await adapter.effectCount()
    XCTAssertEqual(order, [first.opId, next.opId])
    XCTAssertEqual(effects, 2, "the repeated pack was not applied again")
    XCTAssertEqual(try store.value("brainSeq") as CloudSequence?, CloudSequence(3), "the Mac was not stopped")
    let refused = try await engine.refusedPacks()
    XCTAssertEqual(refused.map(\.sequence), [CloudSequence(2)])
    XCTAssertEqual(refused.first?.reason, CloudSyncEngine.repeatedPackReason)
    XCTAssertEqual(refused.first?.deviceId, trusted.deviceId)
    // The other two contradictions are named too; the same pack at its own position is simply applied already.
    let d = segment.descriptor
    XCTAssertNil(try store.repeatedPackReason(id: d.segmentId, seq: CloudSequence(1), digest: d.sha256))
    XCTAssertEqual(try store.repeatedPackReason(id: d.segmentId, seq: CloudSequence(1), digest: "other-bytes"), CloudSyncEngine.packIdReusedReason)
    XCTAssertEqual(try store.repeatedPackReason(id: UUID().uuidString.lowercased(), seq: CloudSequence(1), digest: d.sha256), CloudSyncEngine.positionReusedReason)
    // Checking the repeat again does not apply it either.
    let again = try await engine.checkRefusedAgain(sequence: CloudSequence(2))
    XCTAssertTrue(again.isEmpty)
    let stillListed = try await engine.refusedPacks()
    XCTAssertEqual(stillListed.first?.checks, 2)
  }
}
