import Foundation

/// Carries the authenticated dispatcher context through a domain's legacy
/// contextless callback seam. Task-local inheritance cannot grant a caller a
/// different identity; missing context is unavailable, never native-app.
public enum NativeCompositionCallContext {
    @TaskLocal public static var rpc: NativeRPCContext?
}
