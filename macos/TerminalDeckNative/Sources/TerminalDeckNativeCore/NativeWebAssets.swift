import Foundation

/// The processor this copy of the app runs on, as release feeds name it.
public enum NativeHost {
    public static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x64"
        #else
        "unsupported"
        #endif
    }
}

/// The Node-free standalone layout (night plan step 4, D14). The app ships no
/// engine, no Node runtime and no `node_modules`: its remaining web pages are
/// plain files under `Contents/Resources/web`, served by the in-process native
/// bridge, and every channel is answered by the native backend.
public struct NativeWebAssets: Equatable, Sendable {
    public let resourcesRoot: URL
    /// `web/renderer` — the React pages (`index.html` + assets).
    public let renderer: URL
    /// `web/native-web/shim.js` — the page-side `/__td` bridge.
    public let shim: URL
    /// `web/pwa` — the phone app the remote host serves.
    public let pwa: URL

    public enum Problem: Error, Equatable, Sendable, LocalizedError {
        case missing(String)
        case legacyPayload(String)
        case wrongArchitecture(String)
        case notNativeOnly
        public var errorDescription: String? {
            switch self {
            case .missing(let path): "This copy of the app is incomplete. Missing: \(path). Reinstall the app."
            case .legacyPayload(let path): "This copy still carries the old Node engine (\(path)). Install the current app."
            case .wrongArchitecture(let detail): "This copy of the app cannot run on this Mac: \(detail)."
            case .notNativeOnly: "This download is not the native app (it does not declare TDNativeOnly)."
            }
        }
    }

    /// Old payload roots. runtime/engine may contain only the inert updater bridge markers.
    public static let legacyPayloads = ["runtime", "engine", "app.asar", "app.asar.unpacked"]
    public static let required = ["web/renderer/index.html", "web/native-web/shim.js", "web/pwa/index.html"]

    private static func containsOnlyUpdaterPlaceholders(_ resources: URL) -> Bool {
        let fm = FileManager.default
        let directories = [("runtime", ["bin", "manifest.json"]), ("runtime/bin", ["node"]), ("engine", ["manifest.json"])]
        for (path, names) in directories {
            let directory = resources.appendingPathComponent(path)
            guard let attributes = try? fm.attributesOfItem(atPath: directory.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  let children = try? fm.contentsOfDirectory(atPath: directory.path), children.sorted() == names.sorted() else { return false }
        }
        let node = "#!/bin/sh\nprintf '%s\\n' 'Terminal Deck no longer uses Node; this placeholder only lets older updaters accept this version'\nexit 1\n"
        let manifest = "{\"removed\":true,\"reason\":\"native app; placeholder for older updaters\"}\n"
        for (path, bytes) in [("runtime/bin/node", node), ("runtime/manifest.json", manifest), ("engine/manifest.json", manifest)] {
            let file = resources.appendingPathComponent(path)
            guard let attributes = try? fm.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  (try? Data(contentsOf: file)) == Data(bytes.utf8) else { return false }
        }
        return fm.isExecutableFile(atPath: resources.appendingPathComponent("runtime/bin/node").path)
    }

    public static func discover(resources: URL) throws -> NativeWebAssets {
        let root = resources.standardizedFileURL
        for relative in required {
            var isDirectory: ObjCBool = false
            let path = root.appendingPathComponent(relative).path
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw Problem.missing("Contents/Resources/" + relative)
            }
        }
        let web = root.appendingPathComponent("web", isDirectory: true)
        return .init(resourcesRoot: root, renderer: web.appendingPathComponent("renderer", isDirectory: true),
                     shim: web.appendingPathComponent("native-web/shim.js"), pwa: web.appendingPathComponent("pwa", isDirectory: true))
    }

    /// Updater check for a downloaded app (no Node-bearing intermediate
    /// release exists, D14): the native layout, both native helpers, no
    /// legacy engine payload, and a main program built for this Mac.
    public static func validateApp(_ app: URL, executableName: String, architecture: String) throws {
        let fm = FileManager.default
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["TDNativeOnly"] as? Bool == true else { throw Problem.notNativeOnly }
        _ = try discover(resources: contents.appendingPathComponent("Resources", isDirectory: true))
        for name in ["TerminalDeckNativeHelper", "TerminalDeckJSCorePluginHelper", executableName] {
            let path = contents.appendingPathComponent("MacOS/" + name).path
            guard fm.isExecutableFile(atPath: path) else { throw Problem.missing("Contents/MacOS/" + name) }
        }
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        let onlyPlaceholders = containsOnlyUpdaterPlaceholders(resources)
        for legacy in legacyPayloads where fm.fileExists(atPath: resources.appendingPathComponent(legacy).path) {
            if onlyPlaceholders && (legacy == "runtime" || legacy == "engine") { continue }
            throw Problem.legacyPayload("Contents/Resources/" + legacy)
        }
        if fm.fileExists(atPath: contents.appendingPathComponent("Frameworks/Electron Framework.framework").path) {
            throw Problem.legacyPayload("Contents/Frameworks/Electron Framework.framework")
        }
        let program = contents.appendingPathComponent("MacOS/" + executableName)
        let found = try machOArchitectures(program)
        guard found.contains(architecture) else {
            throw Problem.wrongArchitecture("\(executableName) is built for \(found.sorted().joined(separator: ", ")), this Mac needs \(architecture)")
        }
    }

    /// Architectures in a thin or universal Mach-O executable ("arm64", "x64").
    public static func machOArchitectures(_ file: URL) throws -> Set<String> {
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw Problem.missing(file.lastPathComponent) }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        func little(_ at: Int) -> UInt32? {
            guard head.count >= at + 4 else { return nil }
            return head.subdata(in: at..<(at + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        }
        func big(_ at: Int) -> UInt32? { little(at).map { UInt32(bigEndian: $0) } }
        func name(_ cpu: UInt32) -> String? { cpu == 0x0100_000c ? "arm64" : cpu == 0x0100_0007 ? "x64" : nil }
        guard let magic = little(0) else { throw Problem.wrongArchitecture("\(file.lastPathComponent) is not a program") }
        if magic == 0xfeed_facf, let cpu = little(4), let arch = name(cpu) { return [arch] }
        if magic == 0xbeba_feca, let count = big(4), count > 0, count < 16 {
            var found = Set<String>()
            for index in 0..<Int(count) { if let cpu = big(8 + index * 20), let arch = name(cpu) { found.insert(arch) } }
            if !found.isEmpty { return found }
        }
        throw Problem.wrongArchitecture("\(file.lastPathComponent) is not a macOS program for arm64 or x64")
    }
}
