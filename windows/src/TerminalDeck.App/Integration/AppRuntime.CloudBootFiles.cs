using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Integration;

/// 7C-3: the AI instruction files of each project (CLAUDE.md, AGENTS.md, GEMINI.md and the project's agents, skills and
/// commands folders) sync with the Macs, per account (`cloud\accounts\<account>`). Only a project's folder on this PC is
/// used, never the AI tools' own home folders (the Macs do not sync those either in this version).
public sealed partial class AppRuntime
{
  private ICloudSyncAdapter CloudBootFilesOwner(string subject, string deviceId) =>
    CloudBootFilesAdapter.ForAccount(CloudAccountFolder(subject), deviceId, CloudBootProjectFolders);

  /// Project id (the id every device shares) → this PC's folder for that project's instruction files. Wired from the
  /// project list once 7C-2 (projects and agents) is in; until then no project has a folder here, so every project's
  /// files wait (kept, nothing written, nothing sent). A folder is never guessed.
  private IReadOnlyDictionary<string, string> CloudBootProjectFolders() => new Dictionary<string, string>();
}
