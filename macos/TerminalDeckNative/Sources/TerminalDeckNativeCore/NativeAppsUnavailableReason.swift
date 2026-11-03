import Foundation

/// #597: the sentences the Apps backend refuses with when an action is unavailable, written once and used by
/// both sides. The backend throws these; the screen maps them to its own copy (NativeAppsContract.unavailableProblem),
/// so rewording one changes both and can never leave the screen with "cause could not be identified".
public enum NativeAppsUnavailableReason {
    public static let recoveryNotConnected = "This action is unavailable because recovery after an interrupted change is not connected yet."
    public static let engineNotConnected = "The app engine has not been connected in this build."
    public static let engineHasNoDocker = "The app engine has no Docker connection yet."
    public static let operationNotImplemented = "This app operation has no implementation."
    public static let dataActionUnavailable = "That app data action is unavailable."
    public static let operationUnavailableOnServer = "The requested app operation is unavailable on this server."
    public static let engineHasNoAddressManager = "The app engine has no private address-manager connection yet."
    public static let addressManagerNeedsPrivateConnection = "The existing address manager needs a private connection for Apps."
    public static let addressManagerUnreachable = "The server's address manager is not reachable. Install it or check the server connection."
    public static let addressManagerNotConfigured = "The address manager is not configured for Apps. Install it before deploying."
    public static let needsPublicIPv4 = "This server needs a public IPv4 address for an automatic web address. You can use your own domain instead."
    public static let publicAddressUnavailable = "The server's public address is unavailable."
    public static let addressCheckUnfinished = "The address check did not finish. Try again after checking the server connection."
    public static let dnsChecksUnavailable = "DNS checks are unavailable."
    public static let dnsNotFound = "DNS could not find this address."
    public static let gitHubSignInUnusable = "The GitHub connection could not supply a usable sign-in."
    public static let autoDeployNotConnected = "Automatic deploys need a trusted signed GitHub connection with approval for each push. It has not been connected yet."
    public static let noRunningService = "This app has no running service yet. Deploy it first."
    public static let liveLogsNeedEvents = "Live app logs need an event connection for this window."
    public static let liveLogsUnavailable = "Live app logs are unavailable."
    public static let liveLogsNeedCleanup = "Live app logs require an owned stream cleanup operation."
    public static let serverCommandUnfinished = "The server command did not finish. Check the server connection."
    public static let privateConnectionUnfinished = "The app's private server connection did not finish."
    public static let databaseConnectionUnfinished = "The database connection did not complete this action. Check the server connection."
    public static let databaseServiceUnfinished = "The database service connection did not finish. Check the saved server connection."
    public static let runningStateUnchecked = "The app's current running state could not be checked."
    public static let runningStatesUnchecked = "The apps' current running state could not be checked."
    public static let runningStateUnreadable = "An app's current running state could not be read safely."
    public static let restartStateUnchecked = "Restart was requested, but the app's current state could not be checked."
    public static let databaseSettingsManaged = "Database settings must be changed through their managed data controls."
    public static let buildsNeedRailpack = "Automatic builds need Railpack and a configured BuildKit builder on this server."
    public static let choosePort = "Choose the app's listening port before deploying. Its build file does not name one web port."
    public static let templateUpdateNeedsMaintenance = "Updating this app needs a safe maintenance window for its saved data. That path is not connected yet."
    public static let templateRollbackNeedsMaintenance = "Rolling this app back needs a safe maintenance window for its saved data. That path is not connected yet."
    public static let backupToolsWithAWS = "Backups need the server's database tools, systemd and AWS CLI. No software was installed."
    public static let scheduledBackupTools = "Scheduled backups need the server's database tools and systemd. No software was installed."
    public static let backupToolsWithChecksums = "Backups need the server's database tools, jq, gzip and sha256sum. No software was installed."
    public static let backupDatabaseVersionGone = "The exact database software used by this backup is no longer saved on the server."
    /// Every reason above, for the check that each one has screen copy.
    public static let all: [String] = [
        recoveryNotConnected, engineNotConnected, engineHasNoDocker, operationNotImplemented,
        dataActionUnavailable, operationUnavailableOnServer, engineHasNoAddressManager, addressManagerNeedsPrivateConnection,
        addressManagerUnreachable, addressManagerNotConfigured, needsPublicIPv4, publicAddressUnavailable,
        addressCheckUnfinished, dnsChecksUnavailable, dnsNotFound, gitHubSignInUnusable,
        autoDeployNotConnected, noRunningService, liveLogsNeedEvents, liveLogsUnavailable,
        liveLogsNeedCleanup, serverCommandUnfinished, privateConnectionUnfinished, databaseConnectionUnfinished,
        databaseServiceUnfinished, runningStateUnchecked, runningStatesUnchecked, runningStateUnreadable,
        restartStateUnchecked, databaseSettingsManaged, buildsNeedRailpack, choosePort,
        templateUpdateNeedsMaintenance, templateRollbackNeedsMaintenance, backupToolsWithAWS, scheduledBackupTools,
        backupToolsWithChecksums, backupDatabaseVersionGone
    ]
}
