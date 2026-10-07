import AppKit
import Foundation
import TerminalDeckNativeCore
import TerminalDeckBackend

/// Owns the existing update IPC contract for the native app. Downloading is
/// explicit; a ready update installs only after normal application termination.
@MainActor
final class NativeAppUpdater {
    static let shared = NativeAppUpdater()
    static let channels: Set<String> = ["update:get", "update:check", "update:download", "update:install"]

    private(set) var state: UpdateState = .none
    var onState: (([String: Any]) -> Void)?
    private(set) var relaunchOnQuit = false

    private let bundle: Bundle
    private let feedURL: URL
    private let dataRoot: URL
    private let currentVersion: String
    private let identifier: String
    private let executableName: String
    private let helper: URL?
    private var offered: NativeUpdateRelease?
    private var staged: NativeStagedUpdate?
    private var helperArmed = false
    private var started = false
    private var restoring = false
    private var lastAutomaticCheck = Date.distantPast
    private var launchTask: Task<Void, Never>?
    private var focusObserver: BackendAppWindowFocusSubscription?
    private lazy var strategy: BackendAppManualUpdateStrategy? = {
        guard let helper else { return nil }
        let context = BackendAppManualUpdateStrategy.Context(feedURL: feedURL,
            updatesRoot: dataRoot.appendingPathComponent("native-updates", isDirectory: true),
            currentBundle: bundle.bundleURL, helper: helper, currentVersion: currentVersion,
            bundleIdentifier: identifier, executableName: executableName,
            architecture: NativeHost.architecture, relaunch: true)
        let native = BackendAppManualUpdateStrategy.Operations.native(context) { [weak self] in
            guard let self else { throw NativeRPCError(code: "closed", message: "The update controller has stopped.") }
            // The strategy already obtained the real helper acknowledgement.
            self.helperArmed = true
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
        // Keep Foundation's numeric network failures readable before the
        // strategy turns its download/install failures into result messages.
        let operations = BackendAppManualUpdateStrategy.Operations(feed: native.feed, stage: { release, progress in
            do { return try await native.stage(release, progress) }
            catch { throw NativeRPCError(code: "update-failed", message: BackendAppUpdateError.describe(error).text) }
        }, install: { receipt in
            do { try await native.install(receipt) }
            catch { throw NativeRPCError(code: "update-failed", message: BackendAppUpdateError.describe(error).text) }
        })
        return BackendAppManualUpdateStrategy(currentVersion: currentVersion, operations: operations)
    }()

    init(bundle: Bundle = .main, dataRoot: URL? = nil) {
        self.bundle = bundle
        self.dataRoot = dataRoot ?? InstalledTerminalDeck.configuration().dataRoot
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        identifier = bundle.bundleIdentifier ?? ""
        executableName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? ""
        helper = bundle.resourceURL?.appendingPathComponent("native-updates/install-update.sh")
        let configured = bundle.object(forInfoDictionaryKey: "TDNativeUpdateFeed") as? String
        feedURL = URL(string: configured ?? "https://github.com/asadev/terminaldeck/releases/latest/download/latest-native-mac.yml")
            ?? URL(string: "https://invalid.local/latest-native-mac.yml")!
        if bundle.bundleURL.pathExtension != "app" || identifier.isEmpty || executableName.isEmpty {
            state = .unsupported(reason: "This is a development run. Packaged native apps check the native GitHub release feed.")
        } else if helper.map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
            state = .unsupported(reason: "This native build is missing its update helper. Download a complete native app or rebuild it.")
        } else if (try? NativeUpdateFeed.validateFeedURL(feedURL)) == nil {
            state = .unsupported(reason: "This native build has no valid latest-native-mac.yml update feed.")
        }
    }

    var rawState: [String: Any] {
        func value(_ optional: Any?) -> Any { optional ?? NSNull() }
        switch state {
        case .idle(let checkedAt): return ["phase": "idle", "checkedAt": value(checkedAt)]
        case .checking: return ["phase": "checking"]
        case .available(let version, let notes, let size): return ["phase": "available", "version": value(version), "notes": value(notes), "sizeBytes": value(size)]
        case .downloading(let version, let percent, let rate): return ["phase": "downloading", "version": value(version), "percent": value(percent), "bytesPerSecond": value(rate)]
        case .ready(let version): return ["phase": "ready", "version": value(version)]
        case .error(let message): return ["phase": "error", "message": message]
        case .unsupported(let reason): return ["phase": "unsupported", "reason": reason]
        }
    }

    func handle(_ channel: String) async -> [String: Any]? {
        guard Self.channels.contains(channel) else { return nil }
        switch channel {
        case "update:check": await check(automatic: false)
        case "update:download": await download()
        case "update:install":
            if case .ready(let version?) = state, let strategy {
                relaunchOnQuit = true
                let result = await strategy.install(version: version)
                if result["ok"].bool != true {
                    relaunchOnQuit = false
                    set(.error(message: BackendAppUpdateError.describe(result["message"]).text))
                }
            }
        default: break
        }
        return rawState
    }

    func start() {
        guard !started, state.phase != "unsupported" else { return }
        started = true
        restoring = true
        launchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let root = dataRoot.appendingPathComponent("native-updates", isDirectory: true)
                let feed = feedURL, app = bundle.bundleURL, id = identifier, executable = executableName
                let restored = try await Task.detached(priority: .utility) {
                    try NativeUpdatePackage.restore(updatesRoot: root, feedURL: feed, currentBundle: app,
                        bundleIdentifier: id, executableName: executable, architecture: NativeHost.architecture)
                }.value
                restoring = false
                if let restored, isNewer(restored.release.version) {
                    await strategy?.adoptVerified(restored)
                    staged = restored
                    set(.ready(version: restored.release.version))
                    return
                }
            } catch { restoring = false; set(.error(message: BackendAppUpdateError.describe(error).text)); return }
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            await check(automatic: true)
        }
        focusObserver = BackendAppWindowFocus.subscribe { [weak self] in
            Task { @MainActor in await self?.check(automatic: true) }
        }
    }

    func stop() {
        launchTask?.cancel(); launchTask = nil
        focusObserver?.cancel()
        focusObserver = nil
    }

    /// AppDelegate calls this before returning terminateNow. On failure the
    /// first quit is cancelled so the window can show the exact failure. A
    /// second ordinary quit succeeds, because an error is no longer ready.
    func prepareForQuit() -> Bool {
        guard case .ready = state, let staged, let helper else { return true }
        guard !helperArmed else { return true }
        do {
            try NativeUpdatePackage.armInstall(staged, currentBundle: bundle.bundleURL,
                executableName: executableName, helper: helper, relaunch: relaunchOnQuit)
            helperArmed = true
            return true
        } catch {
            relaunchOnQuit = false
            set(.error(message: BackendAppUpdateError.describe(error).text))
            return false
        }
    }

    private func check(automatic: Bool) async {
        guard !restoring, !["unsupported", "checking", "downloading", "ready"].contains(state.phase), let strategy else { return }
        if automatic {
            guard Date().timeIntervalSince(lastAutomaticCheck) >= 6 * 60 * 60 else { return }
            lastAutomaticCheck = Date()
        }
        let previous = state
        set(.checking)
        do {
            if let offer = try await strategy.check() {
                let release = offer.release
                offered = release
                set(.available(version: release.version, notes: release.releaseNotes, sizeBytes: Double(release.size)))
            } else {
                offered = nil
                set(.idle(checkedAt: Date().timeIntervalSince1970 * 1000))
            }
        } catch {
            // Routine automatic network errors do not flash a banner every
            // launch. A manual check always reports its actual failure.
            set(automatic ? previous : .error(message: BackendAppUpdateError.describe(error).text))
        }
    }

    private func download() async {
        guard case .available = state, let release = offered, let strategy else { return }
        set(.downloading(version: release.version, percent: 0, bytesPerSecond: 0))
        let result: NativeRPCValue
        do {
            result = try await strategy.download(version: release.version) { [weak self] percent, rate in
                Task { @MainActor in
                    guard let self, self.state.phase == "downloading", self.offered?.version == release.version else { return }
                    self.set(.downloading(version: release.version, percent: floor(percent), bytesPerSecond: max(0, rate)))
                }
            }
        } catch { set(.error(message: BackendAppUpdateError.describe(error).text)); return }
        guard result["ok"].bool == true, let receipt = await strategy.receipt(version: release.version) else {
            set(.error(message: BackendAppUpdateError.describe(result["message"]).text)); return
        }
        staged = receipt
        set(.ready(version: release.version))
    }

    private func isNewer(_ candidate: String) -> Bool {
        BackendAppManualUpdateStrategy.isNewer(candidate, than: currentVersion)
    }

    private func set(_ next: UpdateState) {
        guard next != state else { return }
        state = next
        onState?(rawState)
    }
}
