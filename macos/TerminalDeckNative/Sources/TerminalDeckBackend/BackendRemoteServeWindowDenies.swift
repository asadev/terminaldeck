import Foundation
import TerminalDeckNativeCore

/// Source window-denies.ts, separate instances for server and machine id spaces.
public actor BackendRemoteServeWindowDenies {
    public static let serverFileName = "window-denies.json", machineFileName = "machine-window-denies.json"
    public nonisolated let file: URL
    private let writer: BackendRemoteServeWindowGrants.Writer
    private let report: @Sendable (String) -> Void
    private var denied: [String] = []
    private var opened = false
    public init(directory: URL, fileName: String, write: BackendRemoteServeWindowGrants.Writer? = nil,
                report: (@Sendable (String) -> Void)? = nil) {
        file = directory.appendingPathComponent(fileName); writer = write ?? { try BackendRemoteServeWindowFile.write($0, $1) }
        self.report = report ?? { BackendRemoteServeWindowFile.report($0) }
    }
    public func open() {
        guard !opened else { return }
        denied = BackendRemoteServeWindowFile.ids(BackendRemoteServeWindowFile.read(file,
            oversized: "[window-denies] \(file.path) is implausibly large; ignoring it",
            parseFailure: "[window-denies] could not read \(file.path):", report: report)["denied"])
        opened = true
    }
    public func has(_ id: String) throws -> Bool { try requireOpen(); return !id.isEmpty && denied.contains(id) }
    public func list() throws -> [String] { try requireOpen(); return denied }
    public func size() throws -> Int { try requireOpen(); return denied.count }
    @discardableResult public func set(_ rawID: NativeRPCValue, denied wanted: Bool) throws -> Bool {
        try requireOpen()
        guard let raw = rawID.string, let id = BackendRemoteServeWindowFile.validID(raw) else { return false }
        if denied.contains(id) == wanted { return false }
        if wanted && denied.count >= 64 { return false }
        var next = denied
        if wanted { next.append(id) } else { next.removeAll { $0 == id } }
        try writer(.object([.init("version", .number(1)), .init("denied", .array(next.map(NativeRPCValue.string)))]), file)
        denied = next; return true
    }
    @discardableResult public func forget(_ id: String) throws -> Bool { try set(.string(id), denied: false) }
    /// Backfills old record noes, restores stripped fields, and preserves all
    /// other row fields. A failed backfill must not prevent the store from opening.
    public func apply(rows: [NativeRPCValue], subject: String) throws -> [NativeRPCValue] {
        try requireOpen()
        let missing = rows.filter { $0["drivesWindows"].bool == false && $0["id"].string.map { !denied.contains($0) } == true }
        if !missing.isEmpty {
            do { for row in missing { try set(row["id"], denied: true) } }
            catch { report("[window-denies] \(missing.count) \(subject) refusal(s) could not be written to \(file.path); they still hold, but an older build could erase them: \(error.localizedDescription)") }
        }
        guard !denied.isEmpty else { return rows }
        var stripped = 0
        let out = rows.map { row in
            guard let id = row["id"].string, denied.contains(id) else { return row }
            if row["drivesWindows"].bool != false { stripped += 1 }
            return row.setting("drivesWindows", .bool(false))
        }
        if stripped > 0 { report("[window-denies] \(stripped) \(subject) refusal(s) were missing from the record and have been restored from \(file.path) — a build older than this one rewrote that file.") }
        return out
    }
    public func close() { opened = false; denied = [] }
    private func requireOpen() throws { guard opened else { throw NativeRPCError(code: "unavailable", message: "Open the durable window refusal store before reading or changing permissions") } }
}
