import Foundation
import CryptoKit

/// The signed release manifest every public GitHub release carries from 0.21.0 on (release 27, Asad 3 Nov:
/// "every time something new comes in GitHub it will show that pop-up and we can directly update from here").
///
/// `release-manifest.json` names one Mac zip and one Windows MSIX with their sizes and hashes;
/// `release-manifest.json.sig` is an Ed25519 signature over the manifest's exact bytes. The key that signs it
/// lives only on the release machine (`~/private_keys/terminaldeck-release/`); the apps carry the public half.
/// A manifest the key did not sign is refused before anything is downloaded, so a changed GitHub asset alone
/// can never point the app at another file. The app is then checked on its own as well (Developer ID, Team ID,
/// notarization, hashes): either check failing stops the update.
public enum NativeReleaseManifest {
    public static let filename = "release-manifest.json"
    public static let signatureFilename = "release-manifest.json.sig"
    /// Ed25519 public keys (raw 32 bytes, base64) whose signature is accepted. A second key is added here one
    /// release BEFORE the publisher switches to it, so a key can be replaced without stranding anyone.
    public static let publicKeys = ["seyAiThAvnCyVp9CZR6MrBOyMxsEb1P9+Pe8M9YCP5A="]
    public static let defaultURL = URL(string: "https://github.com/asadev/terminaldeck/releases/latest/download/release-manifest.json")!
    public static let maximumBytes = 262_144

    public static func signatureURL(for manifest: URL) -> URL {
        manifest.deletingLastPathComponent().appendingPathComponent(signatureFilename)
    }

    public static func validateManifestURL(_ url: URL) throws {
        guard url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, url.lastPathComponent == filename,
              NativeUpdateFeed.repositoryPrefix(of: url) != nil,
              url.path.contains("/releases/latest/download/") || url.path.contains("/releases/download/") else {
            throw NativeUpdateFeed.Failure("This app needs the signed release-manifest.json of its GitHub repository.")
        }
    }

    /// The signature file holds base64 (one line); anything else is refused.
    public static func verify(_ manifest: Data, signatureFile: Data, keys: [String] = publicKeys) throws {
        guard manifest.count <= maximumBytes, signatureFile.count <= 1024,
              let text = String(data: signatureFile, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let signature = Data(base64Encoded: text), signature.count == 64 else {
            throw NativeUpdateFeed.Failure("The release manifest's signature is missing or unreadable. Nothing was downloaded.")
        }
        for raw in keys {
            guard let bytes = Data(base64Encoded: raw), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: bytes) else { continue }
            if key.isValidSignature(signature, for: manifest) { return }
        }
        throw NativeUpdateFeed.Failure("The release manifest is not signed by Terminal Deck's release key. Nothing was downloaded.")
    }

    /// The Mac part of a verified manifest, as the release the updater stages. Every field is checked again by
    /// NativeUpdateFeed.validate (repository, asset name, version shape, hashes).
    public static func macRelease(from manifest: Data, manifestURL: URL, bundleIdentifier: String,
                                  architecture: String) throws -> NativeUpdateRelease {
        try validateManifestURL(manifestURL)
        guard let root = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any] else {
            throw NativeUpdateFeed.Failure("The release manifest is not valid JSON.")
        }
        func text(_ object: [String: Any], _ key: String) throws -> String {
            guard let value = object[key] as? String, !value.isEmpty else { throw NativeUpdateFeed.Failure("The release manifest is missing \(key).") }
            return value
        }
        guard root["schema"] as? Int == 1, root["product"] as? String == "terminaldeck" else {
            throw NativeUpdateFeed.Failure("The release manifest belongs to another product or a newer format. Update by hand from the releases page.")
        }
        guard let mac = root["mac"] as? [String: Any] else { throw NativeUpdateFeed.Failure("This release has no Mac app.") }
        let version = try text(root, "version")
        guard try text(mac, "teamIdentifier") == NativeUpdateTrust.teamIdentifier else {
            throw NativeUpdateFeed.Failure("This release names another developer. Nothing was downloaded.")
        }
        guard let url = URL(string: try text(mac, "url")), let sizeNumber = mac["size"] as? NSNumber,
              CFGetTypeID(sizeNumber) != CFBooleanGetTypeID() else {
            throw NativeUpdateFeed.Failure("The release manifest's Mac entry is incomplete.")
        }
        var notes = (root["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let current = notes { notes = current.isEmpty ? nil : String(decoding: Array(current.utf16.prefix(4000)), as: UTF16.self) }
        let release = NativeUpdateRelease(schemaVersion: 1, channel: "native-mac", version: version,
            bundleIdentifier: try text(mac, "bundleIdentifier"), architecture: try text(mac, "architecture"),
            url: url, sha512: try text(mac, "sha512"), size: sizeNumber.int64Value,
            releaseDate: (root["releaseDate"] as? String) ?? "", releaseNotes: notes,
            sha256: try text(mac, "sha256"), notesURL: (root["notesUrl"] as? String).flatMap(URL.init(string:)),
            notarized: mac["notarized"] as? Bool ?? false)
        try NativeUpdateFeed.validate(release, feedURL: manifestURL, bundleIdentifier: bundleIdentifier, architecture: architecture)
        return release
    }
}

/// Who may replace this app: only Asad Iqbal's Developer ID (Team 6U4VNX5W87), pinned here rather than read
/// from the running copy (a locally signed or ad-hoc copy would otherwise accept any signer), and once a
/// notarized version is installed, only notarized versions after it.
public enum NativeUpdateTrust {
    public static let teamIdentifier = "6U4VNX5W87"
    /// Apple's Developer ID rule: Apple's anchor, the Developer ID intermediate, a Developer ID Application leaf,
    /// and this team. The same text the swap helper tests again after the app has quit.
    public static let developerIDRequirement = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(teamIdentifier)\""

    public struct Gatekeeper: Equatable, Sendable {
        public let accepted: Bool
        public let notarized: Bool
        public let source: String?
    }

    /// `codesign --verify --deep --strict -R=<Developer ID requirement>`: throws with a plain sentence when the
    /// app is not signed by this team's Developer ID.
    public static func verifyDeveloperID(_ app: URL) throws {
        do { _ = try NativeUpdatePackage.command("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=" + developerIDRequirement, app.path]) }
        catch { throw NativeUpdateFeed.Failure("The downloaded app is not signed with Terminal Deck's Developer ID (Team \(teamIdentifier)). Nothing was installed.") }
    }

    /// Gatekeeper's own answer (`spctl --assess --type execute`). Notarized means Apple's notary ticket was found
    /// (stapled to the app or online). Rejected is a normal answer here, not an error.
    public static func assess(_ app: URL) -> Gatekeeper {
        guard let outcome = try? NativeChild.runBlocking(.init("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", app.path],
                environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"], errors: .merged), timeoutMilliseconds: 60_000, outputLimit: 1 << 16) else {
            return .init(accepted: false, notarized: false, source: nil)
        }
        let text = String(data: outcome.output, encoding: .utf8) ?? ""
        let source = text.split(whereSeparator: \.isNewline).first { $0.hasPrefix("source=") }.map { String($0.dropFirst("source=".count)) }
        return .init(accepted: outcome.succeeded && text.contains(": accepted"), notarized: source == "Notarized Developer ID", source: source)
    }

    /// The ratchet: a notarized running app accepts only notarized updates; a Developer ID app that Apple has not
    /// notarized (Team 6U4VNX5W87 cannot notarize until Apple configures it, code 7000) accepts a signed one.
    public static func requiresNotarization(currentBundle: URL) -> Bool { assess(currentBundle).notarized }

    /// Everything about the signer, in the order a person would want to hear the failure.
    public static func verify(_ app: URL, requireNotarized: Bool) throws {
        try verifyDeveloperID(app)
        guard requireNotarized else { return }
        let gatekeeper = assess(app)
        guard gatekeeper.accepted, gatekeeper.notarized else {
            throw NativeUpdateFeed.Failure("The downloaded app is not notarized by Apple (\(gatekeeper.source ?? "no answer from Gatekeeper")). This copy only installs notarized updates. Nothing was installed.")
        }
    }
}
