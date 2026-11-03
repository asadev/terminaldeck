import Foundation

// MARK: - Limits and fixed lists

/// The main process's own limits (`task-config.ts`), so a form can say them first.
public enum TasksLimits {
    // No cap on how many agents (Asad, 11 Oct: "there should not be any limit in the app").
    /// The highest "Tasks at once" a person can set. 0, the default, is no limit (Asad 12 Oct: parallel jobs, each in its own copy).
    public static let maxConcurrent = 5
    public static let maxMinutes = 24 * 60
    /// Asad, 12 Oct: "by default nothing should be selected, we can apply if we want to". A new agent has no
    /// "Longest run" limit (0 = no limit; the option stays on the profile and can be turned on).
    public static let defaultRunMinutes = 0
    /// "Keep open after finishing" for a new agent: the ONE place this default lives (screens, app tools, imports,
    /// the profile rules). 60 minutes until Asad confirms.
    public static let defaultKeepAliveMinutes = 60
    public static let maxHops = 5
    public static let defaultHops = 3
    /// The longest instructions file the main process saves.
    public static let maxInstructionsChars = 32_000
}

/// The effort levels a session's own control takes, and the label each shows.
public let EFFORT_CHOICES: [(id: String, label: String)] = AGSCapabilities.claudeEffortOptions.map { ($0.id, $0.label) }

/// The reference CRM's five statuses, which a new connection starts with.
public let DEFAULT_CRM_STATUSES = StatusConfig(
    statuses: TaskStatuses.all,
    initial: "To-Do", completed: "Done", onStarted: "Working on it", onVerified: "Done", onBlocked: "Stuck")

/// The assistant's name (`BRAND.assistant`).
public let BRAND_ASSISTANT = "Hoot"
