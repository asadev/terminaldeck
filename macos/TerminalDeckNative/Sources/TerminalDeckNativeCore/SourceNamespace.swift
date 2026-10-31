/// Release switches are source-owned. They never read environment variables,
/// preferences, account configuration or session fields.
public enum SourceNamespace {
    /// Agent profiles and app defaults use the same installed settings/launch owner.
    public static let agentSettingsEnabled = true
}
