import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Proof P3 only (lean scope: two scratch copies of the app on one Mac, against the TEST service, with a synthetic
/// identity). DEBUG BUILDS ONLY: a release (shipped) build compiles none of the reading code below, never looks at
/// the variable, and `active` is the constant nil, so `NativeCloudBrainRegistration.enabledRows` is exactly
/// `provenRows` there.
///
/// ONE switch: the environment value `TD_CLOUD_SCRATCH` holds the absolute path of a small JSON file:
///
///     { "dataRoot": "<this copy's scratch data folder>",
///       "base": "https://td-cloud-test.terminaldeck.workers.dev/v1", "issuer": "<the TEST issuer>",
///       "start": "https://<any host that is not terminaldeck.dev>/…", "auth": "https://<same rule>/…", "key": "",
///       "memory": true, "passwords": true, "records": true, "bootFiles": true, "signIn": true,
///       "signInURLFile": "<a file in the same folder as this JSON file>" }
///
/// It is used only when EVERY check in `read` holds: the file names this very data folder, that folder is not under
/// `~/Library/Application Support` (where the real app and the dev copy keep their data), and the service is the
/// TEST worker. `memory` switches rows I01 to I06 on for this process. `passwords` switches saved passwords on
/// (`NativeCloudSecretsSwitch`): server passwords with their servers, and the voice key. `records` switches lane A2's
/// two rows on (I11 the project list, I10 agents with their instruction files). `signIn` asks "Sign in to Cloud?" once after
/// launch (the same question a sign-in link raises, so a scratch copy needs no URL scheme). With `signInURLFile` the
/// sign-in address is written to that file instead of opening a browser; the proof's script finishes the hand-off
/// against TEST and calls the loopback address back. Every confirmation and every Trust stays a press in the window.
enum NativeCloudScratch {
    static let variable = "TD_CLOUD_SCRATCH"
    struct Plan: Sendable, Equatable {
        let base: URL
        let issuer: String
        let start: URL
        let auth: URL
        let key: String
        let memory: Bool
        /// Saved passwords (lane V) for this scratch copy: server passwords with their servers, and the voice key.
        let passwords: Bool
        /// Projects and agents (lane A2) for this scratch copy: rows I11 and I10.
        let records: Bool
        /// Boot files (lane F) for this scratch copy: row I09, the chosen project folders only.
        let bootFiles: Bool
        let signIn: Bool
        let signInURLFile: URL?
        /// AUTOMATED TESTS ONLY (two-Mac proof, 13 Nov): the recovery-words sheet shows its words to the Accessibility
        /// tree in this throwaway copy, so the saved-passwords steps can be driven. Off unless the plan says
        /// `"wordsReadable": true`; impossible in the shipped flavour and in a release build (no plan exists there).
        var wordsReadable: Bool = false
    }
    /// The build flavour that ships: a release build, or a debug build with the ShippedHost trait (the flavour the
    /// published app is made from, `lane-build.sh … shipped`). Both define TD_HOST_INTEGRATED (Package.swift
    /// `hostReleaseSettings`); a plain debug build does not. A shipped build never honours a plan.
    static let shippedFlavour: Bool = {
        #if TD_HOST_INTEGRATED
        return true
        #else
        return false
        #endif
    }()
    /// The plan the app runs under: nil in the shipped flavour whatever the environment holds; otherwise `read`.
    /// The app's two call sites use this, never `read` directly (`read` stays the pure checker the tests drive).
    static func plan(environment: [String: String], dataRoot: URL, shipped: Bool = shippedFlavour) -> Plan? {
        #if DEBUG
        guard !shipped else { return nil }
        return read(environment: environment, dataRoot: dataRoot)
        #else
        return nil
        #endif
    }
    #if DEBUG
    /// The ONE service a plan may name (security review S10): the TEST worker, matched exactly, not any worker whose
    /// name merely starts and ends alike.
    static let testHost = "td-cloud-test.terminaldeck.workers.dev"
    /// A path as the disk sees it: symbolic links resolved (also when the last parts do not exist yet), and compared
    /// without letter case, because the disk does not tell `Library` from `library`.
    static func realPath(_ url: URL) -> String {
        var tail: [String] = []
        var current = url.standardizedFileURL
        while current.path != "/", !FileManager.default.fileExists(atPath: current.path) {
            tail.insert(current.lastPathComponent, at: 0)
            current = current.deletingLastPathComponent()
        }
        var resolved = current.resolvingSymlinksInPath()
        for part in tail { resolved.appendPathComponent(part) }
        return resolved.standardizedFileURL.path.lowercased()
    }
    /// A host in the one form hosts are compared in: lower case, no trailing dot.
    static func plainHost(_ url: URL) -> String? {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }
    static func plainIssuer(_ text: String) -> String {
        var value = text.lowercased()
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
    /// The plan for this data folder, or nil: then the app is the ordinary app.
    static func read(environment: [String: String], dataRoot: URL) -> Plan? {
        guard let path = environment[variable], path.hasPrefix("/") else { return nil }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let root = realPath(dataRoot)
        // Never a data folder a person uses: nothing under any "Library/Application Support" (the real app's and the
        // dev copy's homes), reached directly, through a symbolic link or in another letter case, and never a folder
        // with the real app's own name.
        guard !root.contains("/library/application support/"), !root.hasSuffix("/library/application support"),
              !root.hasSuffix("/terminaldeck") else { return nil }
        guard let data = try? Data(contentsOf: file), data.count <= 16_384, let raw = try? NativeRPCValue.parseJSON(data),
              let named = raw["dataRoot"].string, named.hasPrefix("/"), realPath(URL(fileURLWithPath: named)) == root,
              let baseText = raw["base"].string, let base = URL(string: baseText), base.scheme == "https", base.path == "/v1",
              plainHost(base) == testHost, base.port == nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              let issuer = raw["issuer"].string, !issuer.isEmpty, plainIssuer(issuer) != plainIssuer(CloudWire.issuer),
              let startText = raw["start"].string, let start = URL(string: startText),
              let authText = raw["auth"].string, let auth = URL(string: authText) else { return nil }
        for url in [start, auth] {
            guard url.scheme == "https", let other = plainHost(url), other != "terminaldeck.dev", !other.hasSuffix(".terminaldeck.dev") else { return nil }
        }
        var urlFile: URL?
        if let name = raw["signInURLFile"].string {
            let candidate = URL(fileURLWithPath: name).standardizedFileURL
            guard name.hasPrefix("/"), realPath(candidate.deletingLastPathComponent()) == realPath(file.deletingLastPathComponent()) else { return nil }
            urlFile = candidate
        }
        return Plan(base: base, issuer: issuer, start: start, auth: auth, key: raw["key"].string ?? "",
                    memory: raw["memory"].bool == true, passwords: raw["passwords"].bool == true, records: raw["records"].bool == true,
                    bootFiles: raw["bootFiles"].bool == true,
                    signIn: raw["signIn"].bool == true, signInURLFile: urlFile, wordsReadable: raw["wordsReadable"].bool == true)
    }
    private static let box = NativeCloudScratchBox()
    /// The plan this process runs under, once the account assembly accepted it for its data folder.
    static var active: Plan? { box.get() }
    static func adopt(_ plan: Plan) { if !shippedFlavour { box.set(plan) } }
    #else
    static var active: Plan? { nil }
    #endif
    /// The recovery words are readable by the Accessibility tree only under an accepted plan that asks for it, in a
    /// plain debug build. Always false in the shipped flavour and in every release build.
    static func wordsReadable(plan: Plan?, shipped: Bool = shippedFlavour) -> Bool {
        #if DEBUG
        return !shipped && plan?.wordsReadable == true
        #else
        return false
        #endif
    }
    static var readableWordsHere: Bool { wordsReadable(plan: active) }
    /// Rows the plan switches on. Empty in every release build and in every run without an accepted plan.
    static var memoryRows: Set<String> { active?.memory == true ? NativeCloudBrainRegistration.leanMemoryRows : [] }
    /// Lane A2's rows the plan switches on. Empty in every release build and in every run without an accepted plan.
    static var recordRows: Set<String> { active?.records == true ? BackendCloudLeanRecords.rows : [] }
    /// Lane F's row the plan switches on. Empty in every release build and in every run without an accepted plan.
    static var bootRows: Set<String> { active?.bootFiles == true ? [CloudBootFilesFormat.inventoryRow] : [] }
}

#if DEBUG
private final class NativeCloudScratchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var plan: NativeCloudScratch.Plan?
    func get() -> NativeCloudScratch.Plan? { lock.withLock { plan } }
    func set(_ next: NativeCloudScratch.Plan) { lock.withLock { plan = next } }
}
#endif
