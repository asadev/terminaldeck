import AppKit
import Foundation
import TerminalDeckNativeCore
import TerminalDeckBackend

/// Owns the existing update IPC contract for the native app. Downloading is
/// explicit; a ready update installs only after normal application termination.
///
/// Release 27 (Asad 3 Nov): the source is the signed release manifest of the public GitHub repository, the
/// side panel shows the offer just above Settings (NativeUpdateCard), and "Restart to update" never cuts an
/// answer: while Hoot is answering, the restart waits for it and then goes by itself (or the person cancels).
@MainActor
final class NativeAppUpdater {
    static let shared: NativeAppUpdater = {
        let updater = NativeAppUpdater()
        // Hoot's own claude runs inside this app, so a restart would cut its answer. Sessions the session keeper
        // holds keep running through the restart; the app reconnects to them.
        updater.busyReason = { NativeHootChatModel.shared.busy ? "Hoot is answering" : nil }
        updater.card = .shared
        return updater
    }()
    static let channels: Set<String> = ["update:get", "update:check", "update:download", "update:install"]

    private(set) var state: UpdateState = .none
    var onState: (([String: Any]) -> Void)?
    private(set) var relaunchOnQuit = false
    /// Why the restart is waiting right now (nil: not waiting). Set by a "Restart to update" press while busy.
    private(set) var waitingFor: String?
    /// What would be cut by a restart right now (nil: nothing). Production: Hoot mid-answer.
    var busyReason: @MainActor () -> String? = { nil }
    /// The side panel's copy of this state (only the shared updater has one).
    var card: NativeUpdateCardModel?
    private var waitTask: Task<Void, Never>?

    private let bundle: Bundle
    private let feedURL: URL
    private let dataRoot: URL
    private let currentVersion: String
    private let identifier: String
    private let executableName: String
    private let injectedOperations: BackendAppManualUpdateStrategy.Operations?
    private let armForQuit: ((NativeStagedUpdate, Bool) throws -> Void)?
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
        if let injectedOperations { return BackendAppManualUpdateStrategy(currentVersion: currentVersion, operations: injectedOperations) }
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
            DispatchQueue.main.async {
                // One quit through the app's own path: sheets and dialogs close first, a quit AppKit refuses is
                // finished directly, kept sessions stay with the session keeper (NativeSVQuitRule .detach), and the
                // helper (already waiting) swaps and reopens the app from a clean environment. Never a kill.
                NativeQuit.terminate("the in-app update (it opens the new version)")
            }
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

    init(bundle: Bundle = .main, dataRoot: URL? = nil,
         operations: BackendAppManualUpdateStrategy.Operations? = nil,
         armForQuit: ((NativeStagedUpdate, Bool) throws -> Void)? = nil) {
        injectedOperations = operations
        self.armForQuit = armForQuit
        self.bundle = bundle
        self.dataRoot = dataRoot ?? InstalledTerminalDeck.configuration().dataRoot
        currentVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        identifier = bundle.bundleIdentifier ?? ""
        executableName = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? ""
        helper = bundle.resourceURL?.appendingPathComponent("native-updates/install-update.sh")
        // Release 27: the signed manifest of the newest public release (GitHub's "latest" = newest non-draft,
        // non-prerelease). An Info.plist TDNativeUpdateFeed still overrides it (a fork's own repository).
        let configured = bundle.object(forInfoDictionaryKey: "TDNativeUpdateFeed") as? String
        feedURL = configured.flatMap(URL.init(string:)) ?? NativeReleaseManifest.defaultURL
        if operations != nil {
            state = .idle(checkedAt: nil)
        } else if bundle.bundleURL.pathExtension != "app" || identifier.isEmpty || executableName.isEmpty {
            state = .unsupported(reason: "This is a development run. Packaged native apps check the native GitHub release feed.")
        } else if helper.map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
            state = .unsupported(reason: "This native build is missing its update helper. Download a complete native app or rebuild it.")
        } else if (try? NativeUpdateFeed.validateSourceURL(feedURL)) == nil {
            state = .unsupported(reason: "This native build has no valid GitHub release manifest to update from.")
        }
        let remembered = (try? String(contentsOf: dismissFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        dismissedVersion = remembered.isEmpty ? nil : remembered
    }

    // MARK: Dismissed for this version (the side panel's ×): kept across launches until a newer version.
    private(set) var dismissedVersion: String?
    private var dismissFile: URL { dataRoot.appendingPathComponent("native-updates/dismissed-version", isDirectory: false) }
    func dismiss(version: String) {
        dismissedVersion = version
        try? FileManager.default.createDirectory(at: dismissFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? Data(version.utf8).write(to: dismissFile, options: .atomic)
        card?.update(from: self)
    }
    private func clearDismissal() {
        guard dismissedVersion != nil else { return }
        dismissedVersion = nil; try? FileManager.default.removeItem(at: dismissFile)
    }

    /// The release page of the offer (or of the downloaded update), from the signed manifest.
    var notesURL: URL? { staged?.release.notesURL ?? offered?.notesURL }

    var rawState: [String: Any] {
        func value(_ optional: Any?) -> Any { optional ?? NSNull() }
        let notes: Any = value(notesURL?.absoluteString)
        switch state {
        case .idle(let checkedAt): return ["phase": "idle", "checkedAt": value(checkedAt)]
        case .checking: return ["phase": "checking"]
        case .available(let version, let text, let size): return ["phase": "available", "version": value(version), "notes": value(text), "sizeBytes": value(size), "notesUrl": notes]
        case .downloading(let version, let percent, let rate): return ["phase": "downloading", "version": value(version), "percent": value(percent), "bytesPerSecond": value(rate), "notesUrl": notes]
        case .ready(let version): return ["phase": "ready", "version": value(version), "notesUrl": notes, "waitingFor": value(waitingFor)]
        case .error(let message): return ["phase": "error", "message": message]
        case .unsupported(let reason): return ["phase": "unsupported", "reason": reason]
        }
    }

    func handle(_ channel: String) async -> [String: Any]? {
        guard Self.channels.contains(channel) else { return nil }
        switch channel {
        case "update:check": await check(automatic: false)
        case "update:download": await download()
        case "update:install": await requestRestart()
        default: break
        }
        return rawState
    }

    /// "Restart to update" (the side panel, Settings, updates.install). Never cuts an answer: while something
    /// that lives inside the app is answering, the restart waits and then goes by itself; cancelRestart stops that.
    func requestRestart() async {
        guard case .ready(let version?) = state, strategy != nil, waitTask == nil else { return }
        if let reason = busyReason() {
            waitingFor = reason; publish()
            NativeCompositionRoot.note("update: restart to \(version) waits — \(reason)")
            waitTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled else { return }
                    if let still = self.busyReason() {
                        if still != self.waitingFor { self.waitingFor = still; self.publish() }
                        continue
                    }
                    self.waitTask = nil; self.waitingFor = nil
                    await self.installNow(version)
                    return
                }
            }
            return
        }
        await installNow(version)
    }

    func cancelRestart() {
        guard waitTask != nil || waitingFor != nil else { return }
        waitTask?.cancel(); waitTask = nil; waitingFor = nil; publish()
        NativeCompositionRoot.note("update: the waiting restart was cancelled")
    }

    private func installNow(_ version: String) async {
        guard case .ready(let current?) = state, current == version, let strategy else { return }
        relaunchOnQuit = true
        publish()
        let result = await strategy.install(version: version)
        if result["ok"].bool != true {
            relaunchOnQuit = false
            set(.error(message: BackendAppUpdateError.describe(result["message"]).text))
        }
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
                // QUIT (9 Oct): drop leftover update copies now that this version is running.
                let keep = restored.flatMap { isNewer($0.release.version) ? $0.directory : nil }
                let tmp = URL(fileURLWithPath: NSTemporaryDirectory()), parent = app.deletingLastPathComponent()
                await Task.detached(priority: .utility) {
                    NativeUpdateSweep.nativeStaging(updatesRoot: root, keep: keep)
                    NativeUpdateSweep.installWork(appParent: parent)
                    NativeUpdateSweep.shipItStaging(tmp: tmp, bundleIdentifier: id, shipItRunning: NativeUpdateSweep.shipItIsRunning())
                }.value
                if let restored, isNewer(restored.release.version) {
                    await strategy?.adoptVerified(restored)
                    staged = restored
                    set(.ready(version: restored.release.version))
                    return
                }
            } catch {
                restoring = false; set(.error(message: BackendAppUpdateError.describe(error).text))
                // A staged update that cannot be restored is only disk space now (QUIT, 9 Oct).
                let root = dataRoot.appendingPathComponent("native-updates", isDirectory: true)
                await Task.detached(priority: .utility) { NativeUpdateSweep.nativeStaging(updatesRoot: root, keep: nil) }.value
                return
            }
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
        waitTask?.cancel(); waitTask = nil
        focusObserver?.cancel()
        focusObserver = nil
    }

    /// AppDelegate calls this before returning terminateNow. On failure the
    /// first quit is cancelled so the window can show the exact failure. A
    /// second ordinary quit succeeds, because an error is no longer ready.
    func prepareForQuit() -> Bool {
        guard case .ready = state, let staged else { return true }
        guard !helperArmed else { return true }
        do {
            if let armForQuit { try armForQuit(staged, relaunchOnQuit) }
            else if let helper {
                try NativeUpdatePackage.armInstall(staged, currentBundle: bundle.bundleURL,
                    executableName: executableName, helper: helper, relaunch: relaunchOnQuit)
            } else { return true }
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
            // Every 6 hours (and on window focus once that has passed): a new GitHub release shows within the day.
            guard Date().timeIntervalSince(lastAutomaticCheck) >= 6 * 60 * 60 else { return }
            lastAutomaticCheck = Date()
        } else {
            clearDismissal() // a check the person asked for brings a dismissed offer back
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
        if next.phase != "ready" { waitTask?.cancel(); waitTask = nil; waitingFor = nil }
        publish()
    }

    private func publish() {
        onState?(rawState)
        card?.update(from: self)
    }
}
