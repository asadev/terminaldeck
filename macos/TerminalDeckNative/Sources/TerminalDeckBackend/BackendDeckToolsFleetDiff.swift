import Foundation
import TerminalDeckNativeCore

/// Reuses the existing fleet-diff port's Git execution, limits and attribution.
/// Corrects only the source sentence's singular/plural form. No second diff,
/// modification-time reader, session view or repository owner is introduced.
public enum BackendDeckToolsFleetDiff {
    public static let defaultMaxFiles = 25, maxFiles = 100, maxFileDiffCharacters = 12_000, maxTotalDiffCharacters = 60_000
    public static func collect(review: BackendGitReview, cwd: String, path: String? = nil, maxFiles: Int = 25,
                               context: NativeRPCContext) async throws -> NativeRPCValue {
        let result = try await review.collect(cwd: cwd, path: path, maxFiles: maxFiles, context: context)
        let rows = result["files"].elements ?? [], sessions = result["sessions"].elements ?? []
        if rows.count == 1, !sessions.isEmpty, let sentence = result["attributionNote"].string {
            return result.setting("attributionNote", .string(sentence.replacingOccurrences(of: "1 changed files:", with: "1 changed file:")))
        }
        return result
    }
}
