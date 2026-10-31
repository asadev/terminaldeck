import Foundation
import TerminalDeckNativeCore

/// Core CopilotIdentity already owns reading, cleaning, composing and rewriting
/// the identity format. Only this byte-exact legacy paragraph lift was missing.
public enum BackendCopilotIdentity {
    public static func withCurrentDefaultName(_ instructions: String) -> String {
        let old = ["They have not named you yet, and until they do you should not pick a name",
            "for yourself. If they ask what you are called, say exactly that. In the",
            "meantime this app calls you the Copilot, which is a description", "rather than a name."].joined(separator: "\n")
        let new = ["They have not given you a name of their own, so you go by the one this app",
            "gives you: **\(BackendSharedBrand.assistant)**. Do not pick a different name for yourself; if",
            "they give you one, it replaces this paragraph."].joined(separator: "\n")
        guard let range = instructions.range(of: old) else { return instructions }
        var result = instructions; result.replaceSubrange(range, with: new); return result
    }
}
