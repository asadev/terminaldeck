import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Web dev keeper isolation")
struct WEBDevIsolationTests {
    @Test func scratchKeeperCannotInstallGlobalAgentConfiguration() throws {
        let root = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("web-dev-host-" + UUID().uuidString)
        let paths = try BackendHOSTPaths(dataDirectory: root)
        let plan = try BackendHOSTLaunchAgent(paths: paths, version: "web-proof", launchAgentsDirectory: root.appendingPathComponent("LaunchAgents"))
        let plist = try PropertyListSerialization.propertyList(from: plan.propertyList(), format: nil) as? [String: Any]
        let environment = plist?["EnvironmentVariables"] as? [String: String]
        #expect(environment?[NativeLaunchSwitches.agentConfigReadOnly] == "1")
        #expect(environment?[NativeLaunchSwitches.dataFolder] == root.path)
        #expect(plan.label.contains(".scratch-"))
        // Constructing and inspecting the launch plan must never create its data folder.
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
