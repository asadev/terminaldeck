import Foundation
import Darwin

/// QUIT (9 Oct 2026): update attempts left full app copies behind — 27 Squirrel/ShipIt staging
/// folders of 248 MB each in $TMPDIR from the 7 Oct attempts, plus the native updater's own
/// staged downloads. At launch (the running app proves the last swap finished) these go, and
/// only these: never anything another app owns, never while ShipIt itself is running.
public enum NativeUpdateSweep {
    /// `$TMPDIR/<bundle id>.ShipIt.<random>` folders, only when no ShipIt process is running.
    @discardableResult
    public static func shipItStaging(tmp: URL, bundleIdentifier: String, shipItRunning: Bool) -> [String] {
        guard !shipItRunning, !bundleIdentifier.isEmpty,
              let names = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) else { return [] }
        let prefix = bundleIdentifier + ".ShipIt."
        return names.filter { $0.hasPrefix(prefix) && $0.count > prefix.count }.sorted().compactMap { name in
            ownedDirectory(tmp.appendingPathComponent(name)) && remove(tmp.appendingPathComponent(name)) ? name : nil
        }
    }

    /// The native updater's `native-updates/<uuid>/` download folders, except the one a still
    /// pending (newer) update points at; a stale `pending.json` (not newer) goes with them.
    @discardableResult
    public static func nativeStaging(updatesRoot: URL, keep: URL?) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: updatesRoot.path) else { return [] }
        let kept = keep?.standardizedFileURL.resolvingSymlinksInPath().lastPathComponent
        var removed: [String] = []
        for name in names.sorted() where name != kept && UUID(uuidString: name) != nil {
            let folder = updatesRoot.appendingPathComponent(name, isDirectory: true)
            if ownedDirectory(folder), remove(folder) { removed.append(name) }
        }
        if keep == nil, (try? FileManager.default.removeItem(at: updatesRoot.appendingPathComponent("pending.json"))) != nil { removed.append("pending.json") }
        return removed
    }

    /// `.td-native-update.*` work folders the install helper made next to the app (its recovery
    /// copy of the previous version). This launch of the new app is the proof they are no longer needed.
    @discardableResult
    public static func installWork(appParent: URL) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: appParent.path) else { return [] }
        return names.filter { $0.hasPrefix(".td-native-update.") }.sorted().compactMap { name in
            ownedDirectory(appParent.appendingPathComponent(name)) && remove(appParent.appendingPathComponent(name)) ? name : nil
        }
    }

    /// Any process named ShipIt (Squirrel's installer) running as this user.
    public static func shipItIsRunning() -> Bool {
        var size = 0
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(geteuid())]
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return true } // unknown: assume running, sweep nothing
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return true }
        for index in 0..<(size / MemoryLayout<kinfo_proc>.stride) {
            var comm = procs[index].kp_proc.p_comm
            let name = withUnsafeBytes(of: &comm) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
            if name == "ShipIt" { return true }
        }
        return false
    }

    private static func ownedDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == geteuid()
    }
    private static func remove(_ url: URL) -> Bool { (try? FileManager.default.removeItem(at: url)) != nil }
}
