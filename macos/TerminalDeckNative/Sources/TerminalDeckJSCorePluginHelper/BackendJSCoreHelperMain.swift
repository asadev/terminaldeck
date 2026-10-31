import TerminalDeckBackend

/// Isolated executable entry; the SwiftPM target is an integration-owned edit.
/// There is no fallback to a Node runtime or to the native SwiftUI application.
@main
struct BackendJSCoreHelperMain {
    static func main() {
        BackendJSCoreHelperRunner.run(bootstrap: BackendJSCorePluginBootstrap())
    }
}
