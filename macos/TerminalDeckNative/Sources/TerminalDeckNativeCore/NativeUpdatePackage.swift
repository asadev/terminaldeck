import Foundation
import CryptoKit
import Darwin

public struct NativeStagedUpdate: Codable, Sendable {
    public let release: NativeUpdateRelease
    public let directory: URL
    public let archive: URL
    public let bundle: URL
}

/// Disk work lives off the main actor. It only writes inside the private staging
/// directory; replacing a running app belongs exclusively to the quit helper.
public enum NativeUpdatePackage {
    public static func stage(release: NativeUpdateRelease, updatesRoot: URL, currentBundle: URL,
                             executableName: String, onProgress: @escaping @Sendable (Double, Double) -> Void) async throws -> NativeStagedUpdate {
        let fm = FileManager.default
        try fm.createDirectory(at: updatesRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directory = updatesRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let archive = directory.appendingPathComponent("update.zip")
        do {
            try await NativeArchiveDownload(url: release.url, destination: archive, expectedSize: release.size, onProgress: onProgress).start()
            return try await Task.detached(priority: .utility) {
                try verifyArchive(archive, release: release)
                try validateZip(archive)
                let extracted = directory.appendingPathComponent("unpacked", isDirectory: true)
                try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                _ = try command("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path])
                let apps = try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: [.isDirectoryKey])
                    .filter { $0.pathExtension == "app" }
                guard apps.count == 1, let app = apps.first else { throw NativeUpdateFeed.Failure("The native ZIP must contain one app bundle.") }
                try validateBundle(app, release: release, executableName: executableName, expectedTeam: signingTeam(currentBundle))
                let staged = NativeStagedUpdate(release: release, directory: directory, archive: archive, bundle: app)
                try JSONEncoder().encode(staged).write(to: updatesRoot.appendingPathComponent("pending.json"), options: .atomic)
                return staged
            }.value
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    public static func restore(updatesRoot: URL, feedURL: URL, currentBundle: URL,
                               bundleIdentifier: String, executableName: String, architecture: String) throws -> NativeStagedUpdate? {
        let pending = updatesRoot.appendingPathComponent("pending.json")
        guard FileManager.default.fileExists(atPath: pending.path) else { return nil }
        let data = try Data(contentsOf: pending)
        guard data.count < NativeUpdateFeed.maximumFeedBytes else { throw NativeUpdateFeed.Failure("The staged update record is invalid.") }
        let staged = try JSONDecoder().decode(NativeStagedUpdate.self, from: data)
        try NativeUpdateFeed.validate(staged.release, feedURL: feedURL, bundleIdentifier: bundleIdentifier, architecture: architecture)
        let root = updatesRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let directory = staged.directory.standardizedFileURL.resolvingSymlinksInPath().path
        guard directory.hasPrefix(root), staged.archive.standardizedFileURL.resolvingSymlinksInPath().path == directory + "/update.zip",
              staged.bundle.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(directory + "/unpacked/") else {
            throw NativeUpdateFeed.Failure("The staged update points outside its private folder.")
        }
        try verifyArchive(staged.archive, release: staged.release)
        try validateBundle(staged.bundle, release: staged.release, executableName: executableName, expectedTeam: signingTeam(currentBundle))
        return staged
    }

    public static func verifyArchive(_ archive: URL, release: NativeUpdateRelease) throws {
        let size = (try archive.resourceValues(forKeys: [.fileSizeKey])).fileSize
        guard Int64(size ?? 0) == release.size else { throw NativeUpdateFeed.Failure("The native update download has the wrong size. Download it again.") }
        let file = try FileHandle(forReadingFrom: archive)
        defer { try? file.close() }
        var hash = SHA512()
        while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
        guard Data(hash.finalize()).base64EncodedString() == release.sha512 else {
            throw NativeUpdateFeed.Failure("The native update failed its SHA512 check. Nothing was installed.")
        }
    }

    public static func validateBundle(_ app: URL, release: NativeUpdateRelease, executableName: String, expectedTeam: String?) throws {
        let fm = FileManager.default
        let root = app.standardizedFileURL.resolvingSymlinksInPath()
        guard root == app.standardizedFileURL, app.pathExtension == "app",
              let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw NativeUpdateFeed.Failure("The downloaded app does not match this native app's identity, version or program.")
        }
        // fetch-update.ts:755-775: the plist can never aim the program outside its own bundle, and a binary that lost its
        // permissions in extraction is its own sentence.
        if let named = info["CFBundleExecutable"] as? String {
            let label = app.lastPathComponent
            if named.contains("/") || named.contains("\\") { throw NativeUpdateFeed.Failure("\(label) names an executable outside its own bundle.") }
            var isDirectory: ObjCBool = false
            let binary = app.appendingPathComponent("Contents/MacOS/\(named)")
            guard fm.fileExists(atPath: binary.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw NativeUpdateFeed.Failure("\(label) has no binary at Contents/MacOS/\(named).")
            }
            if !fm.isExecutableFile(atPath: binary.path) { throw NativeUpdateFeed.Failure("\(label)'s binary is not executable, so the extraction lost its permissions.") }
        }
        guard info["CFBundleIdentifier"] as? String == release.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == release.version,
              info["CFBundleExecutable"] as? String == executableName,
              fm.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/\(executableName)").path),
              !fm.fileExists(atPath: app.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path) else {
            throw NativeUpdateFeed.Failure("The downloaded app does not match this native app's identity, version or program.")
        }
        // D14: the Node-free layout is accepted directly (no Node-bearing bridge release).
        try NativeWebAssets.validateApp(app, executableName: executableName, architecture: release.architecture)
        _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        if let expectedTeam, try signingTeam(app) != expectedTeam {
            throw NativeUpdateFeed.Failure("The downloaded app was signed by a different developer. Nothing was installed.")
        }
        // Bundle symlinks are valid (frameworks use them), provided they never
        // make the installed program depend on paths outside its own bundle.
        if let files = fm.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let file as URL in files {
                let target = file.resolvingSymlinksInPath().standardizedFileURL.path
                guard target.hasPrefix(root.path + "/") else { throw NativeUpdateFeed.Failure("The downloaded app contains a link outside its bundle.") }
            }
        }
    }

    public static func signingTeam(_ app: URL) throws -> String? {
        let text = try command("/usr/bin/codesign", ["-dv", "--verbose=4", app.path])
        return text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("TeamIdentifier=") })
            .map { String($0.dropFirst("TeamIdentifier=".count)) }.flatMap { $0 == "not set" || $0.isEmpty ? nil : $0 }
    }

    /// Start a detached helper while this app is alive; the helper acknowledges
    /// its checks, then waits for normal termination before copying or moving.
    public static func armInstall(_ staged: NativeStagedUpdate, currentBundle: URL, executableName: String,
                                  helper: URL, relaunch: Bool) throws {
        let fm = FileManager.default
        let current = currentBundle.standardizedFileURL.resolvingSymlinksInPath()
        guard current == currentBundle.standardizedFileURL, current.pathExtension == "app",
              !current.path.hasPrefix("/Volumes/"), !current.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath: current.deletingLastPathComponent().path), current != staged.bundle else {
            throw NativeUpdateFeed.Failure("This app cannot be updated at its current location. Move it to a writable folder first.")
        }
        _ = try command("/usr/bin/codesign", ["--verify", "--deep", "--strict", current.path])
        guard helper.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(current.path + "/Contents/Resources/") else {
            throw NativeUpdateFeed.Failure("The native update helper is missing from this app.")
        }
        // Revalidate at installation time, rather than trusting an earlier
        // download or a record restored from the previous app launch.
        try verifyArchive(staged.archive, release: staged.release)
        let team = try signingTeam(current)
        try validateBundle(staged.bundle, release: staged.release, executableName: executableName, expectedTeam: team)
        let script = staged.directory.appendingPathComponent("install-update.sh")
        if fm.fileExists(atPath: script.path) { try fm.removeItem(at: script) }
        try fm.copyItem(at: helper, to: script)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let marker = staged.directory.appendingPathComponent("helper-ready")
        let cancelled = staged.directory.appendingPathComponent("helper-cancelled")
        try? fm.removeItem(at: marker)
        try? fm.removeItem(at: cancelled)
        let log = staged.directory.appendingPathComponent("install.log")
        if !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let output = try FileHandle(forWritingTo: log)
        try output.seekToEnd()
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        process.arguments = ["/bin/bash", script.path, "--current", current.path, "--staged", staged.bundle.path,
            "--archive", staged.archive.path, "--sha512", staged.release.sha512, "--size", String(staged.release.size),
            "--version", staged.release.version, "--bundle-id", staged.release.bundleIdentifier,
            "--executable", executableName, "--parent-pid", String(getpid()), "--team", team ?? "",
            "--ready", marker.path, "--relaunch", relaunch ? "1" : "0"]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if fm.fileExists(atPath: marker.path) { return }
            if !process.isRunning { break }
            usleep(25_000)
        }
        // Closing a failed acknowledgement leaves the app running. The helper
        // has a finite wait and never kills the parent, even on this path.
        try? Data().write(to: cancelled, options: .atomic)
        if process.isRunning { process.terminate() }
        throw NativeUpdateFeed.Failure("The native update helper did not become ready. The app is still running; see \(log.path).")
    }

    @discardableResult
    static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NativeUpdateFeed.Failure("\(URL(fileURLWithPath: executable).lastPathComponent) could not validate the native update: \(String(data: data.prefix(2048), encoding: .utf8) ?? "unknown error")")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Inspect central-directory paths and Unix symlink contents before ditto
    /// can write a single extracted file. ZIP64/encrypted archives are refused.
    private static func validateZip(_ archive: URL) throws {
        let file = try FileHandle(forReadingFrom: archive)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        let tailOffset = size > 65_557 ? size - 65_557 : 0
        try file.seek(toOffset: tailOffset)
        let tail = try file.readToEnd() ?? Data()
        guard tail.count >= 22 else { throw NativeUpdateFeed.Failure("The native update ZIP is incomplete.") }
        let end = stride(from: tail.count - 22, through: 0, by: -1).first {
            tail.u32($0) == 0x06054b50 && $0 + 22 + Int(tail.u16($0 + 20)) == tail.count
        }
        guard let end, tail.u16(end + 4) == 0, tail.u16(end + 6) == 0,
              tail.u16(end + 8) == tail.u16(end + 10), tail.u16(end + 10) < 65_535,
              tail.u32(end + 12) < 16_777_216 else { throw NativeUpdateFeed.Failure("The native ZIP format is unsupported.") }
        let centralSize = Int(tail.u32(end + 12)), centralOffset = UInt64(tail.u32(end + 16))
        guard centralOffset + UInt64(centralSize) <= tailOffset + UInt64(end) else { throw NativeUpdateFeed.Failure("The native ZIP directory is invalid.") }
        try file.seek(toOffset: centralOffset)
        let central = try file.read(upToCount: centralSize) ?? Data()
        guard central.count == centralSize else { throw NativeUpdateFeed.Failure("The native ZIP directory is truncated.") }
        var offset = 0, expanded: UInt64 = 0
        var appName: String?
        for _ in 0..<tail.u16(end + 10) {
            guard offset + 46 <= central.count, central.u32(offset) == 0x02014b50, central.u16(offset + 8) & 1 == 0 else {
                throw NativeUpdateFeed.Failure("The native ZIP contains an invalid or encrypted entry.")
            }
            let nameLength = Int(central.u16(offset + 28)), extraLength = Int(central.u16(offset + 30)), commentLength = Int(central.u16(offset + 32))
            guard offset + 46 + nameLength + extraLength + commentLength <= central.count,
                  let name = String(data: central.subdata(in: offset + 46..<offset + 46 + nameLength), encoding: .utf8) else {
                throw NativeUpdateFeed.Failure("The native ZIP contains an unreadable filename.")
            }
            let localOffset = UInt64(central.u32(offset + 42))
            guard localOffset + 30 <= centralOffset else { throw NativeUpdateFeed.Failure("The native ZIP has an invalid local entry.") }
            try file.seek(toOffset: localOffset)
            let local = try file.read(upToCount: 30) ?? Data()
            guard local.count == 30, local.u32(0) == 0x04034b50, local.u16(6) == central.u16(offset + 8),
                  local.u16(8) == central.u16(offset + 10), Int(local.u16(26)) == nameLength else {
                throw NativeUpdateFeed.Failure("The native ZIP's local entry differs from its directory.")
            }
            let localName = try file.read(upToCount: nameLength) ?? Data()
            guard localName == central.subdata(in: offset + 46..<offset + 46 + nameLength),
                  localOffset + 30 + UInt64(nameLength) + UInt64(local.u16(28)) + UInt64(central.u32(offset + 20)) <= centralOffset else {
                throw NativeUpdateFeed.Failure("The native ZIP has inconsistent paths or entry lengths.")
            }
            let parts = name.split(separator: "/", omittingEmptySubsequences: false)
            guard !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"),
                  !parts.contains(".."), !parts.contains("."), let top = parts.first, !top.isEmpty,
                  top.hasSuffix(".app") || top == "__MACOSX" else { throw NativeUpdateFeed.Failure("The native ZIP contains a path outside its app bundle.") }
            if top.hasSuffix(".app") {
                guard appName == nil || appName == String(top) else { throw NativeUpdateFeed.Failure("The native ZIP contains more than one app.") }
                appName = String(top)
            }
            expanded += UInt64(central.u32(offset + 24))
            guard expanded <= 4_294_967_296 else { throw NativeUpdateFeed.Failure("The native ZIP expands beyond the allowed size.") }
            let unixMode = central.u32(offset + 38) >> 16
            if unixMode & 0o170000 == 0o120000 {
                guard central.u32(offset + 24) <= 4096, !name.contains("["), !name.contains("*"), !name.contains("?") else {
                    throw NativeUpdateFeed.Failure("The native ZIP contains an unsupported link.")
                }
                let target = try command("/usr/bin/unzip", ["-p", archive.path, name])
                guard !target.isEmpty, !target.hasPrefix("/"), !target.contains("\0"), !target.contains("\\") else {
                    throw NativeUpdateFeed.Failure("The native ZIP contains a link outside its app.")
                }
                var components = name.split(separator: "/").dropLast().map(String.init)
                for piece in target.split(separator: "/") {
                    if piece == ".." {
                        guard components.count > 1 else { throw NativeUpdateFeed.Failure("The native ZIP contains a link outside its app.") }
                        components.removeLast()
                    } else if piece != "." { components.append(String(piece)) }
                }
                guard components.first == String(top) else { throw NativeUpdateFeed.Failure("The native ZIP contains a link outside its app.") }
            } else if unixMode & 0o170000 != 0 && unixMode & 0o170000 != 0o100000 && unixMode & 0o170000 != 0o040000 {
                throw NativeUpdateFeed.Failure("The native ZIP contains an unsupported file type.")
            }
            offset += 46 + nameLength + extraLength + commentLength
        }
        guard appName != nil, offset == central.count else { throw NativeUpdateFeed.Failure("The native ZIP has an invalid app directory.") }
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
}

private final class NativeArchiveDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let url: URL
    private let destination: URL
    private let expectedSize: Int64
    private let onProgress: @Sendable (Double, Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var downloaded = false
    private var failure: Error?
    private var lastAt = Date()
    private var lastBytes: Int64 = 0

    init(url: URL, destination: URL, expectedSize: Int64, onProgress: @escaping @Sendable (Double, Double) -> Void) {
        self.url = url; self.destination = destination; self.expectedSize = expectedSize; self.onProgress = onProgress
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 900
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
            session?.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.flatMap { NativeUpdateFeed.allowedNetworkURL($0) ? request : nil })
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= expectedSize else {
            failure = NativeUpdateFeed.Failure("The native update sent more bytes than its feed declared.")
            downloadTask.cancel(); return
        }
        let now = Date(), seconds = now.timeIntervalSince(lastAt)
        if seconds >= 0.25 || totalBytesWritten == expectedSize {
            onProgress(min(100, Double(totalBytesWritten) / Double(expectedSize) * 100), Double(totalBytesWritten - lastBytes) / max(seconds, 0.001))
            lastAt = now; lastBytes = totalBytesWritten
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
                  let url = response.url, NativeUpdateFeed.allowedNetworkURL(url) else {
                throw NativeUpdateFeed.Failure("GitHub did not return the native update archive.")
            }
            try FileManager.default.copyItem(at: location, to: destination)
            downloaded = true
        } catch { failure = error }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let failure = failure ?? error { continuation?.resume(throwing: failure) }
        else if downloaded { continuation?.resume() }
        else { continuation?.resume(throwing: NativeUpdateFeed.Failure("The native update download did not complete.")) }
        continuation = nil
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}
