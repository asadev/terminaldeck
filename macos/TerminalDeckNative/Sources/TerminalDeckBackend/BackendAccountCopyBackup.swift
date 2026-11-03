import Foundation

/// Removing a second account copy preserves its whole folder. The primitive
/// is also used by an updated app attached to an older account owner.
public enum BackendAccountCopyBackup {
    public static func validate(_ profile: BackendAccountProfile, configuration: BackendAccountConfiguration) throws {
        guard !profile.system, BackendAccountFiles.descendant(profile.configDir, root: configuration.profilesRoot.path)
                || BackendAccountSignInStorage.ownsFolder(profile, configuration: configuration) else {
            throw BackendAccountFailure("This account folder is outside Terminal Deck. Keep the copy and move that folder yourself before removing it.")
        }
        let source = URL(fileURLWithPath: profile.configDir).standardizedFileURL
        let allowedRoots = [configuration.profilesRoot, BackendAccountSignInStorage.root(configuration)]
        guard allowedRoots.contains(where: { source.deletingLastPathComponent().path == $0.standardizedFileURL.path }) else {
            throw BackendAccountFailure("This account folder is shared or nested. Keep the copy and choose a separate account folder first.")
        }
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: source.path)) != nil
            || (try? fm.destinationOfSymbolicLink(atPath: source.deletingLastPathComponent().path)) != nil {
            throw BackendAccountFailure("This account folder is a link. Keep the copy and give it its own folder before removing it.")
        }
        if fm.fileExists(atPath: source.path) {
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw BackendAccountFailure("This account folder is a link or a file. Keep the copy and give it its own folder before removing it.")
            }
        }
        let backupRoot = configuration.dataDirectory.appendingPathComponent("account-backups", isDirectory: true)
        if (try? fm.destinationOfSymbolicLink(atPath: backupRoot.path)) != nil {
            throw BackendAccountFailure("The account backup folder is a link. Move it aside in Finder, then try Remove copy again.")
        }
        if fm.fileExists(atPath: backupRoot.path) {
            let values = try backupRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw BackendAccountFailure("The account backup folder is not a normal folder. Move it aside in Finder, then try Remove copy again.")
            }
        }
    }

    @discardableResult
    public static func archive(_ profile: BackendAccountProfile, configuration: BackendAccountConfiguration,
                               stamp: String = UUID().uuidString) throws -> URL? {
        try validate(profile, configuration: configuration)
        let source = URL(fileURLWithPath: profile.configDir).standardizedFileURL
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let root = configuration.dataDirectory.appendingPathComponent("account-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let safeStamp = stamp.filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        guard !safeStamp.isEmpty else { throw BackendAccountFailure("The account backup name could not be made. Try Remove copy again.") }
        let destination = root.appendingPathComponent(BackendAccountProfile.slugifyProfileID(profile.id) + "-" + safeStamp, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw BackendAccountFailure("That account backup already exists. Try Remove copy again to make a fresh backup.")
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    public static func restore(_ backup: URL?, profile: BackendAccountProfile) throws {
        guard let backup else { return }
        let source = URL(fileURLWithPath: profile.configDir).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: source.path) else {
            throw BackendAccountFailure("The account folder already exists. Its earlier copy is safe in account-backups.")
        }
        try FileManager.default.moveItem(at: backup, to: source)
    }
}
