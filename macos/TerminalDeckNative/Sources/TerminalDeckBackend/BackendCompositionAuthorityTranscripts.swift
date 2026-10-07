import Foundation
import Darwin
import TerminalDeckNativeCore

/// Encoded Claude project directory names collide. A scoped caller also needs
/// the transcript's own bounded cwd metadata to prove project membership.
public enum BackendCompositionAuthorityTranscripts {
    public static func belongs(_ path: String, scope: NativeTranscriptScope,
                               cancellation: BackendMCPCancellation? = nil) async throws -> Bool {
        guard let folders = scope.projectFolders else { return true }
        let approved = try NativeTranscriptPaths.assertTranscript(path, scope: scope)
        return try await Task.detached(priority: .utility) {
            let descriptor = Darwin.open(approved, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { throw NativeRPCError(code: "transcript-read", message: "Transcript membership metadata could not be read") }
            defer { Darwin.close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw NativeRPCError(code: "transcript-read", message: "Transcript membership needs a regular file") }
            var buffer = [UInt8](repeating: 0, count: 32 * 1024), pending = Data(), bytes = 0, lines = 0
            while bytes < 4 * 1024 * 1024, lines < 256 {
                try Task.checkCancellation(); if cancellation?.isCancelled == true { throw CancellationError() }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw NativeRPCError(code: "transcript-read", message: "Transcript membership metadata could not be read") }
                if count == 0 { break }; bytes += count; pending.append(contentsOf: buffer.prefix(count))
                while let newline = pending.firstIndex(of: 10) {
                    lines += 1; let line = pending.prefix(upTo: newline); pending.removeSubrange(...newline)
                    guard line.count <= 1024 * 1024 else { continue }
                    if let value = try? NativeRPCValue.parseJSON(Data(line), maximumBytes: 1024 * 1024),
                       let cwd = value["cwd"].string, cwd.hasPrefix("/"), cwd.utf8.count <= 4096 {
                        return folders.contains { BackendCompositionAuthority.within(cwd, $0) }
                    }
                    if lines >= 256 { break }
                }
                guard pending.count <= 1024 * 1024 else { throw NativeRPCError(code: "transcript-membership", message: "Transcript membership metadata exceeds its bounded read") }
            }
            throw NativeRPCError(code: "transcript-membership", message: "This transcript has no bounded cwd metadata proving its granted project")
        }.value
    }
    public static func assertCwd(_ cwd: String, scope: NativeTranscriptScope) throws {
        guard let folders = scope.projectFolders else { return }
        guard !cwd.isEmpty, folders.contains(where: { BackendCompositionAuthority.within(cwd, $0) }) else {
            throw NativeRPCError(code: "access-denied", message: "This transcript belongs to a different project")
        }
    }
}

/// Uses the existing account-scoped discovery/parser and checks cwd before a
/// colliding directory's transcript can enter the artifacts index.
public struct BackendCompositionAuthorityArtifacts: BackendArtifactsTranscriptSource, Sendable {
    private let source: BackendArtifactsNativeTranscriptSource
    private let scopes: BackendCompositionFiles.ArtifactScopes
    public init(scopes: @escaping BackendCompositionFiles.ArtifactScopes) {
        self.scopes = scopes; source = BackendArtifactsNativeTranscriptSource(scopes: scopes)
    }
    public func transcripts(project: String, scope: BackendArtifactScope, context: NativeRPCContext) async throws -> [NativeTranscriptFile] {
        let granted = try await scopes(project, scope, context)
        var kept: [NativeTranscriptFile] = []
        for file in try await source.transcripts(project: project, scope: scope, context: context) {
            for grant in granted where (try? NativeTranscriptPaths.assertTranscript(file.path, scope: grant)) != nil {
                if try await BackendCompositionAuthorityTranscripts.belongs(file.path, scope: grant) { kept.append(file); break }
            }
        }
        return kept
    }
    public func authorizedPath(_ file: NativeTranscriptFile, project: String, scope: BackendArtifactScope, context: NativeRPCContext) async throws -> String {
        for grant in try await scopes(project, scope, context) where (try? NativeTranscriptPaths.assertTranscript(file.path, scope: grant)) != nil {
            if try await BackendCompositionAuthorityTranscripts.belongs(file.path, scope: grant) { return file.path }
        }
        throw NativeRPCError(code: "access-denied", message: "This artifact transcript no longer belongs to a granted project")
    }
}
