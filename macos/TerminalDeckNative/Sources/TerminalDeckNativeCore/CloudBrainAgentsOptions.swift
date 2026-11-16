import Foundation

public enum CloudBrainAgentsOptions {
  public static func portable(_ settings: AGSAgentSettings) -> AGSAgentSettings {
    var result = settings
    result.environment = [:]; result.hooks = []; result.workingFolder = nil
    return result
  }
  public static func isPortable(_ settings: AGSAgentSettings) -> Bool {
    settings.environment.isEmpty && settings.hooks.isEmpty && settings.workingFolder == nil
  }
}
