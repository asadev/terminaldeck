import CoreServices
import Foundation

/// 9 Nov: tells the device list (`BackendAppDeviceManager`) when this Mac's simulators or emulators changed, so the
/// list is kept between asks and read again only then. Watched, read only, with the system's file events (nothing
/// polls):
/// - CoreSimulator's device folder: a simulator added or removed (the folder itself), or one booting or shutting down
///   (CoreSimulator replaces `<udid>/device.plist`, which changes `<udid>/`). Writes deeper inside a simulator (its
///   apps and data) are ignored.
/// - `~/.android/avd`: an emulator added or removed.
/// - The emulators' running folder (`~/Library/Caches/TemporaryItems/avd/running`, or its parent while it does not
///   exist yet): an emulator starting or ending.
/// A cable phone has no event; the list's own `listFresh` covers it.
final class BackendAppDeviceListWatch: @unchecked Sendable {
    struct Roots: Sendable, Equatable {
        var simulators: String
        var avds: String
        var running: String
        init(home: String) {
            let base = URL(fileURLWithPath: home)
            simulators = base.appendingPathComponent("Library/Developer/CoreSimulator/Devices").path
            avds = base.appendingPathComponent(".android/avd").path
            running = base.appendingPathComponent("Library/Caches/TemporaryItems/avd/running").path
        }
    }

    /// Whether a file event at `path` (a folder whose entries changed) is a device change.
    static func matters(_ path: String, roots: Roots) -> Bool {
        var folder = path
        while folder.count > 1, folder.hasSuffix("/") { folder.removeLast() }
        if folder == roots.simulators || folder == roots.avds || folder == roots.running { return true }
        // A simulator's own folder (its device.plist was replaced), never deeper.
        if (folder as NSString).deletingLastPathComponent == roots.simulators { return true }
        // The running folder appearing in its parent.
        return folder == (roots.running as NSString).deletingLastPathComponent
    }

    private final class Box: @unchecked Sendable {
        let roots: Roots
        let changed: @Sendable () -> Void
        init(roots: Roots, changed: @escaping @Sendable () -> Void) { self.roots = roots; self.changed = changed }
    }

    private let queue = DispatchQueue(label: "dev.terminaldeck.device-list.events", qos: .utility)
    private var stream: FSEventStreamRef?
    private let box: Box

    /// nil when none of the folders exist (no Xcode simulators and no Android SDK) or events cannot start.
    init?(home: String, changed: @escaping @Sendable () -> Void) {
        let roots = Roots(home: home)
        box = Box(roots: roots, changed: changed)
        let fm = FileManager.default
        let running = fm.fileExists(atPath: roots.running) ? roots.running : (roots.running as NSString).deletingLastPathComponent
        let paths = [roots.simulators, roots.avds, running].filter { fm.fileExists(atPath: $0) }
        guard !paths.isEmpty else { return nil }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { pointer in
                guard let pointer else { return nil }
                _ = Unmanaged<Box>.fromOpaque(pointer).retain(); return pointer
            }, release: { pointer in
                if let pointer { Unmanaged<Box>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let box = Unmanaged<Box>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            if list.prefix(count).contains(where: { BackendAppDeviceListWatch.matters($0, roots: box.roots) }) { box.changed() }
        }
        guard let made = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, paths as CFArray,
                                             FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                             FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else { return nil }
        FSEventStreamSetDispatchQueue(made, queue)
        guard FSEventStreamStart(made) else { FSEventStreamInvalidate(made); FSEventStreamRelease(made); return nil }
        stream = made
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
    }
}
