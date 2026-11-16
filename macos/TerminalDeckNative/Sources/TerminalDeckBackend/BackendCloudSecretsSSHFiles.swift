import Foundation
import Darwin
import TerminalDeckNativeCore

/// Existing owner calls this under its writer gate. The destination comes only
/// from its explicit local selections, never from an incoming record or path.
enum BackendCloudSecretsSSHFiles {
    static func add(_ bytes: Data, to file: URL) throws -> CloudApplyStatus {
        // A destination with ".." pieces is refused outright: the check below and
        // the write must look at the same path, never a tidied copy.
        guard file.isFileURL, file.path.hasPrefix("/"), !file.path.contains("\0"), !file.pathComponents.contains(".."),
              bytes.count <= CloudWire.maximumPlainChunkBytes else { throw CloudFailure.invalidRequest }
        let parent = file.deletingLastPathComponent()
        // The destination folder (or, while it does not exist yet, its nearest
        // existing ancestor) must be a real folder, not a symbolic link. The old
        // check compared the path with resolvingSymlinksInPath(), which also
        // drops "/private" and gives up on missing folders, so it refused honest
        // destinations under /var or not yet created. Links further up (system
        // ones such as /var) are not the destination and are allowed.
        var probe = parent
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" { probe = probe.deletingLastPathComponent() }
        var info = stat()
        guard lstat(probe.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw CloudFailure.invalidRequest }
        if let existing = try BackendAccountFiles.boundedRead(file, maximum: CloudWire.maximumPlainChunkBytes) {
            return existing == bytes ? .alreadyPresent : .keptBoth
        }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = parent.appendingPathComponent(".cloud-ssh-" + UUID().uuidString.lowercased())
        defer { try? FileManager.default.removeItem(at: temporary) }
        try BackendAccountFiles.writeAtomic(bytes, to: temporary)
        // link is atomic and never replaces a destination that appeared while
        // the private temporary was being written. No truncate/rename over it.
        if Darwin.link(temporary.path, file.path) != 0 {
            guard errno == EEXIST, let existing = try BackendAccountFiles.boundedRead(file, maximum: CloudWire.maximumPlainChunkBytes) else { throw CloudFailure.unavailable }
            return existing == bytes ? .alreadyPresent : .keptBoth
        }
        let descriptor = Darwin.open(parent.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CloudFailure.unavailable }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0,
              try BackendAccountFiles.boundedRead(file, maximum: CloudWire.maximumPlainChunkBytes) == bytes else { throw CloudFailure.checksumMismatch }
        return .applied
    }
}
