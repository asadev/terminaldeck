import Darwin
import Foundation
import XCTest
@testable import TerminalDeckBackend

/// #26 (Security, 2 Nov). Claude Code 2.1.310 reads its login from the Keychain first. When it cannot save a renewal
/// there, it writes the new login to `.credentials.json`, tries to delete the Keychain copy and, when that fails too,
/// leaves the spent copy behind ("plaintext_fallback_primary_not_cleared"): the next ordinary Claude reads it and is
/// signed out. So the rule for every sandbox the app puts around a session: the owner's Keychain is reachable both
/// ways or not at all, never read without write. Below Full (a device's folder boundary) it is closed both ways, as a
/// service and as a file; under Hoot's records fence it is open both ways.
///
/// Measured on the real profiles: a live process is started inside each one and the kernel is asked what that
/// process may do (`sandbox_check`, no report). Nothing is read from or written to any keychain.
final class SEC26KeychainReachTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("sec26-keychain-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        scratch = URL(fileURLWithPath: BackendMacConfinement.kernelPath(made.path))
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: below Full

    func testBelowFullTheKeychainIsClosedAsAServiceAndAsAFile() throws {
        let folder = try directory("folder"), home = try directory("device-home"), project = try directory("project")
        // A read-only project that happens to hold keychain files (a granted ~/Library, a copied keychain).
        let projectKeychain = try file(project.appendingPathComponent("Library/Keychains/login.keychain-db"))
        let projectLoose = try file(project.appendingPathComponent("backup/old.keychain"))
        let projectOrdinary = try file(project.appendingPathComponent("README.md"))
        let plan = try BackendMacConfinement.plan(folder: folder.path, home: home.path, accountHome: NSHomeDirectory(),
            path: "/usr/bin:/bin", writable: [], files: [], projects: [project.path])
        let reach = try Reach(profile: BackendMacConfinement.profile(plan), cwd: folder)
        defer { reach.end() }

        // Controls: the probe really runs sandboxed, sees its own grants and is refused outside them.
        XCTAssertTrue(reach.sandboxed)
        XCTAssertTrue(reach.may("file-read-data", projectOrdinary.path), "a read-only project stays readable")
        XCTAssertTrue(reach.may("file-read-data", "/usr/bin/true"))
        // The Keychain's services: no lookup, no save, no prompt.
        for service in ["com.apple.SecurityServer", "com.apple.securityd.xpc", "com.apple.security.agent"] {
            XCTAssertFalse(reach.mayLookUp(service), service)
        }
        // A keychain inside a granted folder is not handed over as a file either (new credential deny, #26).
        XCTAssertFalse(reach.may("file-read-data", projectKeychain.path))
        XCTAssertFalse(reach.may("file-read-data", projectLoose.path))
        // The owner's own login keychain: neither way.
        let owner = try ownerKeychain()
        XCTAssertFalse(reach.may("file-read-data", owner))
        XCTAssertFalse(reach.may("file-write-data", owner))
        XCTAssertEqual(reach.keychainReadable(owner), reach.keychainWritable(owner), "never read without write")
    }

    // MARK: Hoot's records fence

    func testHootsRecordsFenceLeavesTheKeychainOpenBothWays() throws {
        let data = try directory("data")
        let log = URL(fileURLWithPath: BackendMacConfinement.recordsFencePaths(data)[2], isDirectory: true)
        let fenced = try file(log.appendingPathComponent("actions.jsonl"))
        let reach = try Reach(profile: BackendMacConfinement.recordsFenceProfile(data), cwd: data)
        defer { reach.end() }

        XCTAssertTrue(reach.sandboxed)
        XCTAssertFalse(reach.may("file-write-data", fenced.path), "control: the fence holds Hoot's own log")
        for service in ["com.apple.SecurityServer", "com.apple.securityd.xpc"] { XCTAssertTrue(reach.mayLookUp(service), service) }
        let owner = try ownerKeychain()
        XCTAssertTrue(reach.may("file-read-data", owner))
        XCTAssertTrue(reach.may("file-write-data", owner))
        XCTAssertTrue(reach.may("file-write-unlink", owner))
        XCTAssertEqual(reach.keychainReadable(owner), reach.keychainWritable(owner), "never read without write")
    }

    // MARK: helpers

    private func directory(_ name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func file(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: url.path, contents: Data()) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// The path is only named to the kernel's policy check; the file itself is never opened.
    private func ownerKeychain() throws -> String {
        let path = NSHomeDirectory() + "/Library/Keychains/login.keychain-db"
        guard FileManager.default.fileExists(atPath: path) else { throw XCTSkip("This account has no login keychain to ask about.") }
        return path
    }
}

/// A process held inside one Seatbelt profile, and the kernel's answers about it.
private final class Reach {
    let process = Process()
    let pid: pid_t

    init(profile: String, cwd: URL) throws {
        let out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        // sandbox-exec applies the profile, then `sh` (already inside it) says so and becomes `sleep`: same pid.
        process.arguments = ["-p", profile, "/bin/sh", "-c", "echo ready; exec /bin/sleep 60"]
        process.currentDirectoryURL = cwd
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        pid = process.processIdentifier
        let first = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
        guard first.hasPrefix("ready") else {
            process.terminate()
            throw NSError(domain: "SEC26", code: 1, userInfo: [NSLocalizedDescriptionKey: "The profile did not start: \(first)"])
        }
    }

    func end() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    var sandboxed: Bool { Self.check(pid, nil, type: 0, nil) == 1 }
    func may(_ operation: String, _ path: String) -> Bool { Self.check(pid, operation, type: 1, path) == 0 }
    func mayLookUp(_ service: String) -> Bool { Self.check(pid, "mach-lookup", type: 2, service) == 0 }
    /// What Claude Code's `security find-generic-password` needs: the Keychain's service and the keychain file.
    func keychainReadable(_ path: String) -> Bool { mayLookUp("com.apple.SecurityServer") && may("file-read-data", path) }
    /// What its `security add-generic-password -U` / `delete-generic-password` need on top: writing that file.
    func keychainWritable(_ path: String) -> Bool { mayLookUp("com.apple.SecurityServer") && may("file-write-data", path) }

    /// `int sandbox_check(pid_t, const char *operation, int type, ...)`. Swift cannot call a C variadic, so it is
    /// called through a fixed signature. Apple arm64 passes every variadic argument on the stack, so eight register
    /// arguments come first and the filter argument is the ninth (the first stack slot); x86_64 passes it in the
    /// fourth register like any other argument.
    private typealias StackCheck = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32, Int, Int, Int, Int, Int, UnsafePointer<CChar>?) -> Int32
    private typealias RegisterCheck = @convention(c) (pid_t, UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?) -> Int32
    static func check(_ pid: pid_t, _ operation: String?, type: Int32, _ argument: String?) -> Int32 {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "sandbox_check") else { return -1 } // RTLD_DEFAULT
        let flags = type == 0 ? 0 : type | 0x4000_0000 // SANDBOX_CHECK_NO_REPORT: a question, not a denial to log
        func call(_ op: UnsafePointer<CChar>?, _ arg: UnsafePointer<CChar>?) -> Int32 {
            #if arch(arm64)
            unsafeBitCast(symbol, to: StackCheck.self)(pid, op, flags, 0, 0, 0, 0, 0, arg)
            #else
            unsafeBitCast(symbol, to: RegisterCheck.self)(pid, op, flags, arg)
            #endif
        }
        return withOptionalCString(operation) { op in withOptionalCString(argument) { arg in call(op, arg) } }
    }

    private static func withOptionalCString<T>(_ text: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
        guard let text else { return body(nil) }
        return text.withCString { body($0) }
    }
}
