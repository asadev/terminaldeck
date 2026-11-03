import Foundation

/// The routine engine's folder hook returns a refusal message, or nil to arm.
/// Keep the same canonical project/Hoot boundary used by composition authority.
public enum BackendRoutinesFolderPolicy {
    public static func problem(_ path: String, allowedRoots: [String]) -> String? {
        guard allowedRoots.contains(where: { BackendCompositionAuthority.within(path, $0) }) else {
            return "This routine's folder is outside the known projects and Hoot folder. Add its project before running it."
        }
        return nil
    }
}
