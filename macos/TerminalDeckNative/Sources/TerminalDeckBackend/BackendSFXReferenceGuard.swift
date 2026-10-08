import Foundation
import TerminalDeckNativeCore

/// A comparison reference must contain something the checker actually saw.
/// Bundled 0.15 can cut an empty recording; enforce this at the shared app
/// service before both native and deck-tools mark-good calls reach that engine.
public enum BackendSFXReferenceGuard {
    public static func refusal(_ project: String) -> NativeRPCValue? {
        let file = URL(fileURLWithPath: project).appendingPathComponent(".staysfixed/v2/last-check.json")
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 16 * 1024 * 1024,
              let data = try? Data(contentsOf: file),
              let envelope = try? NativeRPCValue.parseJSON(data) else {
            return refused("Run a check first, then review its result before marking this build as good.")
        }
        let raw: NativeRPCValue
        if let encoded = envelope["result"].string {
            guard let parsed = try? NativeRPCValue.parseJSON(Data(encoded.utf8)) else {
                return refused("The saved check could not be read. Run a new check, then try again.")
            }
            raw = parsed
        } else { raw = envelope["result"].fields != nil ? envelope["result"] : envelope }
        if let refusal = refusalForResult(raw) { return refusal }
        guard let id = raw["candidate"]["id"].string,
              id != ".", id != "..", !id.isEmpty,
              id.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil,
              hasProductRecording(project: project, buildID: id) else {
            return refused("The last check did not record this product running. Choose a runnable check, run it, then review its result before marking a good build.")
        }
        return nil
    }

    public static func refusalForResult(_ raw: NativeRPCValue) -> NativeRPCValue? {
        guard raw["error"].isNullish, raw["blocked"].bool != true else {
            return refused("The last check could not run. Fix the reported problem and run it again before marking a good build.")
        }
        guard let paths = raw["coverage"]["paths"].number, paths.isFinite, paths > 0 else {
            return refused("The last check observed nothing, so it cannot become a good build. Choose a runnable check for this project, run it, then review the result.")
        }
        return nil
    }

    private static func hasProductRecording(project: String, buildID: String) -> Bool {
        let root = URL(fileURLWithPath: project).resolvingSymlinksInPath()
        let build = root.appendingPathComponent(".staysfixed/v2/builds/" + buildID).resolvingSymlinksInPath()
        guard build.path.hasPrefix(root.path + "/"),
              let journeys = try? FileManager.default.contentsOfDirectory(at: build,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        for journey in journeys {
            guard let properties = try? journey.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  properties.isDirectory == true, properties.isSymbolicLink != true,
                  let files = try? FileManager.default.contentsOfDirectory(at: journey,
                      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  let latest = files.filter({ $0.pathExtension == "jsonl" })
                      .max(by: { $0.lastPathComponent < $1.lastPathComponent }) else { continue }
            if recordsProduct(latest) { return true }
        }
        return false
    }

    private static func recordsProduct(_ file: URL) -> Bool {
        guard let properties = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              properties.isRegularFile == true, properties.isSymbolicLink != true,
              (properties.fileSize ?? Int.max) <= 16 * 1024 * 1024,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        var header = false, ended = false, observed = false, count = 0
        var expected: Double?
        let channels: Set<String> = ["meaning", "effects", "complaints", "results", "pixels"]
        for line in text.split(separator: "\n") {
            guard let value = try? NativeRPCValue.parseJSON(Data(line.utf8)) else { return false }
            if value["kind"].string == "capture" { header = true; continue }
            if value["kind"].string == "end" { ended = true; expected = value["count"].number; continue }
            guard value["path"].string != nil, let channel = value["channel"].string else { return false }
            count += 1
            let refused = value["meta"]["refused"].bool == true || value["value"]["kind"].string == "refused"
                || value["value"].string?.lowercased().hasPrefix("not checked") == true
            if channels.contains(channel) && !refused { observed = true }
        }
        return header && ended && observed && (expected == nil || expected == Double(count))
    }

    private static func refused(_ message: String) -> NativeRPCValue {
        .object([.init("ok", .bool(false)), .init("marked", .bool(false)), .init("already", .bool(false)),
                 .init("refused", .string(message)), .init("refusedFor", .string("unchecked")), .init("summary", .string(message))])
    }
}
