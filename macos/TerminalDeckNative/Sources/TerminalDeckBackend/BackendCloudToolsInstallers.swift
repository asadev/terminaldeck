import Foundation
import TerminalDeckNativeCore

public enum BackendCloudToolsInstallers {
  /// The existing official installers select their current release; they cannot promise an old pinned version.
  /// The caller supplies the same authorization callback used by the existing install actions.
  public static func codingAIs(_ installer: BackendAIToolInstaller) -> [String: CloudToolsInstaller] {
    Dictionary(uniqueKeysWithValues: BackendAIToolInstallPlan.tools.map { tool in
      (tool, CloudToolsInstaller(id: "ai-tools:" + tool, supportsVersion: { $0 == "*" }, perform: { _ in
        let status = try await installer.install(tool, upgrade: true)
        switch status.state {
        case "installed": return .completed
        case "running": return .started
        default: return .blocked
        }
      }))
    })
  }
}
