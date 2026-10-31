import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Supplements for updates/manual-strategy.ts, which has no standalone TS
/// test suite. The real updater/feed/package implementation is never duplicated
/// or run here: every effect reaches one supplied fake operation.
final class BackendSharedUpdateStrategyTestPortTests: XCTestCase {
    private struct Failure: Error, LocalizedError, Sendable {
        let text: String
        var errorDescription: String? { text }
    }
    private struct Sample: Equatable, Sendable { let percent: Double; let rate: Double }
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Sample] = []
        func record(_ percent: Double, _ rate: Double) { lock.lock(); samples.append(.init(percent: percent, rate: rate)); lock.unlock() }
        func read() -> [Sample] { lock.lock(); defer { lock.unlock() }; return samples }
    }
    private enum Fixtures {
        static let feedURL = URL(string: "https://github.com/asadev/terminaldeck/releases/latest/download/latest-native-mac.yml")!
        static let bundleID = "dev.terminaldeck.app"
        static func release(_ version: String, notes: String? = nil) throws -> NativeUpdateRelease {
            let fields: [(String, NativeRPCValue)] = [
                ("schemaVersion", .number(1)), ("channel", .string("native-mac")), ("version", .string(version)),
                ("bundleIdentifier", .string(bundleID)), ("architecture", .string("arm64")),
                ("url", .string("https://github.com/asadev/terminaldeck/releases/download/v\(version)/terminaldeck-native-arm64.zip")),
                ("sha512", .string(Data(repeating: 0xa5, count: 64).base64EncodedString())), ("size", .number(4096)),
                ("releaseDate", .string("2026-10-06T12:00:00.000Z")), ("releaseNotes", notes.map(NativeRPCValue.string) ?? .null),
            ]
            let text = fields.map { $0.0 + ": " + $0.1.compact }.joined(separator: "\n") + "\n"
            return try NativeUpdateFeed.decode(Data(text.utf8), feedURL: feedURL, bundleIdentifier: bundleID, architecture: "arm64")
        }
        static func receipt(_ release: NativeUpdateRelease) throws -> NativeStagedUpdate {
            // Codable fixture construction avoids relying on Core's internal
            // memberwise initializer. No path here is read or written.
            let releaseValue = try NativeRPCValue.parseJSON(JSONEncoder().encode(release))
            let directory = "file:///fixture-updates/\(release.version)"
            let record = NativeRPCValue.object([
                .init("release", releaseValue), .init("directory", .string(directory)),
                .init("archive", .string(directory + "/update.zip")),
                .init("bundle", .string(directory + "/unpacked/Terminal%20Deck.app")),
            ])
            return try JSONDecoder().decode(NativeStagedUpdate.self, from: record.encodedJSON())
        }
    }
    private actor Harness {
        private var feeds: [NativeUpdateRelease]
        private let receipts: [String: NativeStagedUpdate]
        private let feedFailure: Failure?, stageFailure: Failure?, installFailure: Failure?
        private let samples: [Sample]
        private var events: [String] = []
        private var installedBundles: [String] = []
        init(feeds: [NativeUpdateRelease] = [], receipts: [String: NativeStagedUpdate] = [:], samples: [Sample] = [],
             feedFailure: Failure? = nil, stageFailure: Failure? = nil, installFailure: Failure? = nil) {
            self.feeds = feeds; self.receipts = receipts; self.samples = samples
            self.feedFailure = feedFailure; self.stageFailure = stageFailure; self.installFailure = installFailure
        }
        func operations() -> BackendAppManualUpdateStrategy.Operations {
            .init(feed: { try await self.feed() }, stage: { release, progress in try await self.stage(release, progress: progress) },
                  install: { receipt in try await self.install(receipt) })
        }
        func log() -> [String] { events }
        func bundles() -> [String] { installedBundles }
        private func feed() throws -> NativeUpdateRelease {
            events.append("feed")
            if let feedFailure { throw feedFailure }
            guard !feeds.isEmpty else { throw Failure(text: "Unexpected extra feed read in fixture.") }
            return feeds.removeFirst()
        }
        private func stage(_ release: NativeUpdateRelease, progress: BackendAppManualUpdateStrategy.Progress) throws -> NativeStagedUpdate {
            events.append("stage " + release.version)
            for sample in samples { progress(sample.percent, sample.rate) }
            if let stageFailure { throw stageFailure }
            guard let receipt = receipts[release.version] else { throw Failure(text: "No fixture receipt for " + release.version) }
            return receipt
        }
        private func install(_ receipt: NativeStagedUpdate) throws {
            events.append("install " + receipt.release.version); installedBundles.append(receipt.bundle.path)
            if let installFailure { throw installFailure }
        }
    }
    @MainActor func testSemverishSourceParseIntMissingFieldsAndSuffixRules() {
        let cases: [(String, String, Bool)] = [
            ("1.2.4", "1.2.3", true), ("1.2.3", "1.2.3", false), ("1.2.2", "1.2.3", false),
            ("0.10.1", "0.9.1", true), ("v1.2.4", "v1.2.3", true), ("1.2.3-beta.1", "1.2.3", false),
            ("1.2.3", "1.2.3-beta.1", false), ("1.2.4-beta.1", "1.2.3", true),
            ("1.2", "1.2.0", false), ("1.2.0.1", "1.2", true), ("01.002.003", "1.2.3", false),
            ("1.2.4extra", "1.2.3", true), ("1.+3.0", "1.2.9", true), ("1.bad.0", "1.0.0", false),
            ("V1.2.3", "0.2.3", false), ("", "0", false), (" 2.0.0", "1.9.9", true),
        ]
        for (candidate, running, expected) in cases { XCTAssertEqual(BackendAppManualUpdateStrategy.isNewer(candidate, than: running), expected, "\(candidate) vs \(running)") }
    }
    @MainActor func testCheckReturnsOnlyOfferAndExactNullNotesSize() async throws {
        let release = try Fixtures.release("1.2.4", notes: "This strategy does not invent or display notes.")
        let fake = Harness(feeds: [release])
        let strategy = BackendAppManualUpdateStrategy(currentVersion: "1.2.3", operations: await fake.operations())
        let offer = try await strategy.check()
        XCTAssertEqual(offer?.wire, .object([.init("version", .string("1.2.4")), .init("notes", .null), .init("sizeBytes", .number(4096))]))
        let events = await fake.log(); XCTAssertEqual(events, ["feed"])
        let receipt = await strategy.receipt(version: "1.2.4"); XCTAssertNil(receipt)
    }
    @MainActor func testEqualAndOlderChecksNeverStageOrInstall() async throws {
        for candidate in ["1.2.3", "1.2.2"] {
            let fake = Harness(feeds: [try Fixtures.release(candidate)])
            let strategy = BackendAppManualUpdateStrategy(currentVersion: "1.2.3", operations: await fake.operations())
            let offer = try await strategy.check(); XCTAssertNil(offer)
            let events = await fake.log(); XCTAssertEqual(events, ["feed"])
        }
    }
    @MainActor func testCheckPropagatesFeedFailureToTheUpdater() async {
        let fake = Harness(feedFailure: .init(text: "the release feed answered 503"))
        let strategy = BackendAppManualUpdateStrategy(currentVersion: "1.2.3", operations: await fake.operations())
        do { _ = try await strategy.check(); XCTFail("The updater must receive a failed check") }
        catch { XCTAssertEqual(error.localizedDescription, "the release feed answered 503") }
        let events = await fake.log(); XCTAssertEqual(events, ["feed"])
    }
    @MainActor func testDownloadRefetchesStagesAndForwardsRoundedNativeProgress() async throws {
        let release = try Fixtures.release("1.2.4"), receipt = try Fixtures.receipt(release)
        let fake = Harness(feeds: [release, release], receipts: [release.version: receipt], samples: [.init(percent: 0, rate: -1), .init(percent: 50, rate: 10.4), .init(percent: 100, rate: 10.5)])
        let strategy = BackendAppManualUpdateStrategy(currentVersion: "1.2.3", operations: await fake.operations())
        _ = try await strategy.check()
        let progress = ProgressLog()
        let result = try await strategy.download(version: "1.2.4", onProgress: { progress.record($0, $1) })
        XCTAssertEqual(result, .object([.init("ok", .bool(true))]))
        XCTAssertEqual(progress.read(), [.init(percent: 0, rate: 0), .init(percent: 50, rate: 10), .init(percent: 100, rate: 11)])
        let events = await fake.log(); XCTAssertEqual(events, ["feed", "feed", "stage 1.2.4"])
        let stored = await strategy.receipt(version: "1.2.4")
        XCTAssertEqual(stored?.release, receipt.release); XCTAssertEqual(stored?.directory, receipt.directory)
        XCTAssertEqual(stored?.archive, receipt.archive); XCTAssertEqual(stored?.bundle, receipt.bundle)
    }
    @MainActor func testChangedReleaseHasExactRefusalAndCachesNeitherVersion() async throws {
        let offered = try Fixtures.release("1.2.4"), changed = try Fixtures.release("1.2.5"), receipt = try Fixtures.receipt(changed)
        let fake = Harness(feeds: [offered, changed], receipts: [changed.version: receipt])
        let strategy = BackendAppManualUpdateStrategy(currentVersion: "1.2.3", operations: await fake.operations())
        _ = try await strategy.check()
        let result = try await strategy.download(version: "1.2.4", onProgress: { _, _ in })
        XCTAssertEqual(result, .object([.init("ok", .bool(false)), .init("message", .string("The release changed while downloading — expected 1.2.4, found 1.2.5. Check again."))]))
        let original = await strategy.receipt(version: "1.2.4"), newer = await strategy.receipt(version: "1.2.5")
        XCTAssertNil(original); XCTAssertNil(newer)
        let installed = await strategy.install(version: "1.2.4")
        XCTAssertEqual(installed, .object([.init("ok", .bool(false)), .init("message", .string("Nothing is staged for this version. Download it again."))]))
        let events = await fake.log(); XCTAssertEqual(events, ["feed", "feed", "stage 1.2.5"])
    }
    @MainActor func testFeedAndStageDownloadFailuresReturnTheirOwnMessages() async throws {
        let release = try Fixtures.release("1.2.4")
        for feedFails in [true, false] {
            let message = feedFails ? "the release feed could not be read" : "The native update failed its SHA512 check. Nothing was installed."
            let fake = Harness(feeds: [release], feedFailure: feedFails ? .init(text: message) : nil, stageFailure: feedFails ? nil : .init(text: message))
            let strategy = BackendAppManualUpdateStrategy(currentVersion: "1.2.3", operations: await fake.operations())
            let result = try await strategy.download(version: "1.2.4", onProgress: { _, _ in })
            XCTAssertEqual(result, .object([.init("ok", .bool(false)), .init("message", .string(message))]))
            let stored = await strategy.receipt(version: "1.2.4"); XCTAssertNil(stored)
            let events = await fake.log(); XCTAssertEqual(events, feedFails ? ["feed"] : ["feed", "stage 1.2.4"])
        }
    }
    @MainActor func testInstallWithoutStagingRefusesBeforeAnyOperation() async {
        let fake = Harness(), strategy = BackendAppManualUpdateStrategy(currentVersion: "1.2.3", operations: await fake.operations())
        let result = await strategy.install(version: "1.2.4")
        XCTAssertEqual(result, .object([.init("ok", .bool(false)), .init("message", .string("Nothing is staged for this version. Download it again."))]))
        let events = await fake.log(); XCTAssertEqual(events, [])
    }
    @MainActor func testInstallReceivesExactlyTheSuccessfulDownloadReceipt() async throws {
        let release = try Fixtures.release("1.2.4"), receipt = try Fixtures.receipt(release)
        let fake = Harness(feeds: [release], receipts: [release.version: receipt])
        let strategy = BackendAppManualUpdateStrategy(currentVersion: "1.2.3", operations: await fake.operations())
        _ = try await strategy.download(version: "1.2.4", onProgress: { _, _ in })
        let result = await strategy.install(version: "1.2.4")
        XCTAssertEqual(result, .object([.init("ok", .bool(true))]))
        let events = await fake.log(), bundles = await fake.bundles()
        XCTAssertEqual(events, ["feed", "stage 1.2.4", "install 1.2.4"]); XCTAssertEqual(bundles, [receipt.bundle.path])
    }
    @MainActor func testInstallFailureReturnsTheOperationMessageAndKeepsReceipt() async throws {
        let release = try Fixtures.release("1.2.4"), receipt = try Fixtures.receipt(release)
        let fake = Harness(feeds: [release], receipts: [release.version: receipt], installFailure: .init(text: "The helper did not acknowledge the installation."))
        let strategy = BackendAppManualUpdateStrategy(currentVersion: "1.2.3", operations: await fake.operations())
        _ = try await strategy.download(version: "1.2.4", onProgress: { _, _ in })
        let result = await strategy.install(version: "1.2.4")
        XCTAssertEqual(result, .object([.init("ok", .bool(false)), .init("message", .string("The helper did not acknowledge the installation."))]))
        let retained = await strategy.receipt(version: "1.2.4"); XCTAssertEqual(retained?.bundle, receipt.bundle)
    }
    @MainActor func testVerifiedRestoreAdoptionAvoidsNewFeedOrDownload() async throws {
        let receipt = try Fixtures.receipt(Fixtures.release("1.2.4"))
        let fake = Harness(), strategy = BackendAppManualUpdateStrategy(currentVersion: "1.2.3", operations: await fake.operations())
        // This fakes the app owner's already-revalidated restore result. It
        // makes no claim that these path-only fixture bytes passed validation.
        await strategy.adoptVerified(receipt)
        let adopted = await strategy.receipt(version: "1.2.4"); XCTAssertEqual(adopted?.bundle, receipt.bundle)
        let result = await strategy.install(version: "1.2.4")
        XCTAssertEqual(result, .object([.init("ok", .bool(true))]))
        let events = await fake.log(); XCTAssertEqual(events, ["install 1.2.4"])
    }
}
