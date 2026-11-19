using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Integration;

/// 7C-3: the AI instruction files of each project (CLAUDE.md, AGENTS.md, GEMINI.md and the project's agents, skills and
/// commands folders) sync with the Macs, per account (`cloud\accounts\<account>`). Only a project's folder on this PC is
/// used, never the AI tools' own home folders (the Macs do not sync those either in this version).
public sealed partial class AppRuntime
{
  private ICloudSyncAdapter CloudBootFilesOwner(string subject, string deviceId, Func<bool> autoAccept, CloudAnnounce announce)
  {
    var adapter = CloudBootFilesAdapter.ForAccount(CloudAccountFolder(subject), deviceId, CloudBootProjectFolders, autoAccept, announce,
      deviceName: CloudDeviceName, thisDeviceName: Environment.MachineName);
    // One setup for every AI (19 Nov): before each project's files are looked at (AppRuntime.AiSetup.cs).
    adapter.SetupKeeper = AlignAiSetup;
    return adapter;
  }

  /// Project id (the id every device shares) → this PC's folder for that project's instruction files. The Mac's rule
  /// (NativeCloudBootPlaces, review S2): a project with exactly ONE folder on this PC uses that folder (also the folder
  /// made by itself when the project arrived from Cloud, 7C-2). A project with several folders is not given one: which
  /// folder gets the files is never guessed, so its files wait (kept, nothing written, nothing sent). Read again at
  /// every capture, so a project that just arrived or just got its folder is picked up.
  private IReadOnlyDictionary<string, string> CloudBootProjectFolders()
  {
    var found = new Dictionary<string, string>(StringComparer.Ordinal);
    foreach (var project in Projects.List())
      if (!project.Folders.IsDefaultOrEmpty && project.Folders.Length == 1) found[project.Id] = project.Folders[0];
    return found;
  }
}
