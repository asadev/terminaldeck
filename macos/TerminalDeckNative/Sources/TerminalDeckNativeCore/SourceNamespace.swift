/// Release switches are source-owned. They never read environment variables,
/// preferences, account configuration or session fields.
public enum SourceNamespace {
    /// AGS stays compiled for its fixtures, but has no production owner in this release.
    public static let agentSettingsEnabled = false
}
