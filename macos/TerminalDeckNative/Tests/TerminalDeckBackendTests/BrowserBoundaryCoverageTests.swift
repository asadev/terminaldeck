import Foundation
import Darwin
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Browser security boundaries")
struct BrowserBoundaryCoverageTests {
    @Test func resourceRulesStayOnTheExactTopPageOrigin() throws {
        let plan = try BackendWebKitProfileArmingRulePlan.make(rules: .object([.init("image", .string("block"))]),
            pageURL: URL(string: "https://example.invalid:8443/page")!)
        #expect(plan.needsInstallation && plan.blockedKinds == ["image"])
        #expect(plan.origin == "https://example.invalid:8443")
        #expect(plan.wireValue["requestInterception"] == .bool(false))
        #expect(plan.wireValue["fulfillment"] == .bool(false))
        let rules = try NativeRPCValue.parseJSON(Data(plan.encodedRules.utf8)).requireArray("rules")
        let patterns = try #require(rules.first?["trigger"]["if-top-url"].elements)
        func matches(_ url: String) throws -> Bool {
            try patterns.contains { value in
                let expression = try NSRegularExpression(pattern: value.requireString("pattern"))
                return expression.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
            }
        }
        #expect(try matches("https://example.invalid:8443/path"))
        #expect(try !matches("https://exampleXinvalid:8443/path"))
        #expect(try !matches("https://example.invalid:8444/path"))
        #expect(try !matches("https://example.invalid.evil:8443/path"))
    }

    @Test func unsupportedFetchRulesNeverBecomeBroaderResourceBlocks() throws {
        for kind in ["xhr", "fetch"] {
            #expect(throws: (any Error).self) {
                try BackendWebKitProfileArmingRulePlan.make(rules: .object([.init(kind, .string("block"))]),
                    pageURL: URL(string: "https://example.invalid/")!)
            }
        }
        #expect(throws: (any Error).self) {
            try BackendWebKitProfileArmingRulePlan.make(rules: .object([.init("image", .string("block"))]),
                pageURL: URL(fileURLWithPath: "/not-a-page"))
        }
        let allowed = try BackendWebKitProfileArmingRulePlan.make(rules: .object([.init("fetch", .string("allow"))]),
            pageURL: URL(string: "https://example.invalid/")!)
        #expect(!allowed.needsInstallation)
    }

    @Test func armingRespectsCaptureLimitsAndTheExplicitCameraChoice() throws {
        let url = URL(string: "https://example.invalid/")!
        let idle = try BackendWebKitProfileArmingDecision.make(settings: .object([]), pageURL: url)
        #expect(!idle.wanted && !idle.capture && !idle.camera)
        let settings = try NativeRPCValue.parseJSON(Data(#"{"capture":{"on":true,"keepMB":2},"checks":{"screenshotOnBlock":false,"coverage":{"on":true,"pattern":"**"}}}"#.utf8))
        let armed = try BackendWebKitProfileArmingDecision.make(settings: settings, pageURL: url)
        #expect(armed.wanted && armed.capture && !armed.camera)
        #expect(armed.coveragePattern == "**")
        #expect(armed.limits["maxTotalBytes"] == .number(2_097_152))
        #expect(armed.fingerprint != idle.fingerprint)
    }

    @Test func downloadPathsRefuseTraversalAndSymlinkComponents() throws {
        for path in ["", "relative", "/tmp/../outside", "/tmp/a\nb"] {
            #expect(throws: (any Error).self) { try BackendBrowserDownloadsStorage.validPath(path) }
        }
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("downloads")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        #expect(throws: (any Error).self) { try BackendBrowserDownloadsStorage.directory(link, create: false) }
        let descriptor = try BackendBrowserDownloadsStorage.directory(directory, create: false)
        defer { Darwin.close(descriptor) }
        try Data("existing".utf8).write(to: directory.appendingPathComponent("report.txt"))
        #expect(try BackendBrowserDownloadsStorage.candidate("report.txt", in: descriptor, taken: ["report (2).txt"]) == "report (3).txt")
        #expect(try String(contentsOf: directory.appendingPathComponent("report.txt"), encoding: .utf8) == "existing")
    }

    @Test func downloadLedgerReplacementNeverWritesThroughASymlink() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("browser-downloads.json"), withDestinationURL: outside)
        #expect(throws: (any Error).self) { try BackendBrowserDownloadsStorage.readLedger(root: root) }
        let data = Data("[]".utf8)
        try BackendBrowserDownloadsStorage.writeLedger(data, root: root)
        #expect(try BackendBrowserDownloadsStorage.readLedger(root: root) == data)
        #expect(try String(contentsOf: outside, encoding: .utf8) == "unchanged")
        #expect(throws: (any Error).self) {
            try BackendBrowserDownloadsStorage.writeLedger(Data(repeating: 0, count: 4 * 1_024 * 1_024 + 1), root: root)
        }
        #expect(try BackendBrowserDownloadsStorage.readLedger(root: root) == data)
    }

    @Test func assetFetchRefusesRemoteAndDeniedLocalCallersBeforeAnyIO() async throws {
        let root = try scratch(), calls = Calls()
        defer { try? FileManager.default.removeItem(at: root) }
        let denied = NativeRPCError(code: "test-denied", message: "Not granted")
        let hooks = BackendBrowserAssetHooks(resolveProfile: { _, _ in await calls.add("profile"); throw denied },
            fetch: { _, _, _, _, _ in await calls.add("fetch"); throw denied },
            probe: { _, _, _, _ in await calls.add("probe"); throw denied },
            directory: { _, _ in await calls.add("directory"); throw denied },
            file: { _, _ in await calls.add("file"); throw denied },
            authorize: { _, _, _, _, _ in await calls.add("authorize"); throw denied })
        let assets = BackendBrowserScrapingAssets(store: .init(dataRoot: root, changed: { _ in }), hooks: hooks)
        do {
            _ = try await assets.fetch(.object([]), caller: .init(ownerID: "test", attended: false, remote: true))
            Issue.record("A remote caller reached local asset fetching")
        } catch {}
        #expect(await calls.values.isEmpty)
        do {
            _ = try await assets.fetch(.object([]), caller: .init(ownerID: "test", attended: true, remote: false))
            Issue.record("A denied caller reached asset fetching")
        } catch let error as NativeRPCError { #expect(error.code == "test-denied") }
        #expect(await calls.values == ["authorize"])
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func profileLifecycleRejectsToolsBeforeRulesOrCaptureCanBeInstalled() async throws {
        let root = try scratch(), calls = Calls(), profile = UUID().uuidString.lowercased()
        defer { try? FileManager.default.removeItem(at: root) }
        let denied = NativeRPCError(code: "test-denied", message: "Not granted")
        let store = BackendBrowserScrapingStore(dataRoot: root, changed: { _ in await calls.add("store") })
        let network = BackendBrowserNetworkCapture(store: store, hooks: .init(
            target: { _, _ in await calls.add("target"); throw denied },
            observe: { _, _, _ in await calls.add("observe"); throw denied },
            authorize: { _, _, _, _, _ in await calls.add("network-authorize"); throw denied }))
        let assets = BackendBrowserScrapingAssets(store: store, hooks: .init(
            resolveProfile: { _, _ in await calls.add("profile"); throw denied },
            fetch: { _, _, _, _, _ in await calls.add("fetch"); throw denied },
            probe: { _, _, _, _ in await calls.add("probe"); throw denied },
            directory: { _, _ in await calls.add("directory"); throw denied },
            file: { _, _ in await calls.add("file"); throw denied },
            authorize: { _, _, _, _, _ in await calls.add("asset-authorize"); throw denied }))
        let arming = BackendWebKitProfileArming(store: store, network: network, assets: assets, hooks: .init(
            authorize: { _, operation, selected, url, _ in
                await calls.add("authorize:" + operation + ":" + (selected ?? "nil") + ":" + (url?.absoluteString ?? "nil"))
                throw denied
            }, baton: { _ in await calls.add("baton"); throw denied },
            networkArguments: { _ in await calls.add("arguments"); throw denied },
            applyRules: { _, _, _ in await calls.add("rules"); throw denied },
            removeRules: { _ in await calls.add("remove"); throw denied },
            recordBlock: { _, _, _, _, _ in await calls.add("block"); throw denied },
            safeText: { _, _, _ in await calls.add("text"); throw denied },
            changed: { _, _ in await calls.add("changed") }))
        let target = BackendBrowserCaptureTarget(tabID: "tab", profileID: profile, pageURL: URL(string: "https://example.invalid/")!, title: "Test")
        let rpc = NativeRPCContext(caller: .nativeApp, ownerID: "native")
        let tools: [BackendBrowserScrapingCaller] = [
            .init(ownerID: "remote", attended: false, remote: true, rpc: rpc),
            .init(ownerID: "session", sessionID: "agent", attended: true, remote: false, rpc: rpc),
            .init(ownerID: "spoofed", attended: true, remote: false, rpc: .init(caller: .pairedDevice, ownerID: "spoofed")),
            .init(ownerID: "remote-engine", attended: false, remote: true, rpc: .init(caller: .internalEngine, ownerID: "remote-engine"))]
        for caller in tools {
            do {
                let token = try await arming.watch(target: target, caller: caller)
                try? await arming.close(token)
                Issue.record("A tool installed a standing profile lifecycle")
            } catch {}
        }
        #expect(await calls.values.isEmpty)
        do {
            _ = try await arming.watch(target: target, caller: .native(rpc))
            Issue.record("A denied profile was armed")
        } catch let error as NativeRPCError { #expect(error.code == "test-denied") }
        #expect(await calls.values == ["authorize:browser.profile-arm.watch:" + profile + ":https://example.invalid/"])
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    private func scratch() throws -> URL {
        guard let path = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw NativeRPCError(code: "fixture", message: "The scratch directory could not be resolved")
        }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path)).appendingPathComponent("browser-boundaries-" + UUID().uuidString)
    }
    private actor Calls {
        var values: [String] = []
        func add(_ value: String) { values.append(value) }
    }
}
