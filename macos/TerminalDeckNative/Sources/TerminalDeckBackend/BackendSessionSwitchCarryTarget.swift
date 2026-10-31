import Foundation

/// 18 Oct (#427, #431): what a conversation carried to another account does to a copy of it already there.
/// A conversation record only grows, so a copy that begins with the other holds all of it:
/// - the copy there holds everything carried (the same, or more: later turns made under that account) → kept as it is;
/// - the copy there is an older start of what is carried → replaced, nothing is lost;
/// - the two went different ways → the copy there is kept beside it, one per conversation (`<name>.before-switch`),
///   never a new spare copy at every switch.
enum BackendSessionSwitchCarryTarget {
    enum Existing: Equatable { case none, holdsAll, older, differs }
    static let asideSuffix = ".before-switch"

    /// How the copy at `target` relates to `source`.
    static func existing(source: URL, target: URL) throws -> Existing {
        guard FileManager.default.fileExists(atPath: target.path) else { return .none }
        switch try relation(source, target) {
        case .same, .longer: return .holdsAll
        case .shorter: return .older
        case .differs: return .differs
        }
    }

    /// Moves a differing copy aside: to the conversation's one place for it, unless that place holds words this
    /// copy does not (then beside it under the time, so nothing is ever lost).
    static func setAside(_ target: URL, now: Date = Date()) throws {
        let files = FileManager.default
        let aside = target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + asideSuffix)
        if files.fileExists(atPath: aside.path) {
            let kept = try relation(aside, target)
            guard kept == .same || kept == .longer else {
                let stamped = aside.deletingLastPathComponent()
                    .appendingPathComponent(aside.lastPathComponent + "-" + String(Int64(now.timeIntervalSince1970 * 1000)))
                try files.moveItem(at: target, to: stamped); return
            }
            try files.removeItem(at: aside)
        }
        try files.moveItem(at: target, to: aside)
    }

    private enum Relation { case same, longer, shorter, differs }
    /// `b` compared with `a`, read in pieces so a long record is never held whole twice.
    private static func relation(_ a: URL, _ b: URL) throws -> Relation {
        let left = try FileHandle(forReadingFrom: a); defer { try? left.close() }
        let right = try FileHandle(forReadingFrom: b); defer { try? right.close() }
        let piece = 1024 * 1024
        while true {
            let x = try left.read(upToCount: piece) ?? Data(), y = try right.read(upToCount: piece) ?? Data()
            let shared = min(x.count, y.count)
            guard x.prefix(shared) == y.prefix(shared) else { return .differs }
            if x.count == y.count {
                if x.isEmpty { return .same }
                continue
            }
            // One ended inside this piece: it must really have ended, the other going on from there.
            if x.count < y.count {
                let more = try left.read(upToCount: 1) ?? Data()
                return more.isEmpty ? .longer : .differs
            }
            let more = try right.read(upToCount: 1) ?? Data()
            return more.isEmpty ? .shorter : .differs
        }
    }
}
