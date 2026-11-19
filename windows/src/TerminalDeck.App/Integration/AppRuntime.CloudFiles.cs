using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Integration;

/// Lane F: the Cloud folder (`%USERPROFILE%\Terminal Deck Cloud`) and his artifacts travel with his other devices, as on
/// the Mac: ONE file owner run twice, per account (`cloud\accounts\<account>\cloud-folder`, `...\artifacts`,
/// `...\artifacts-files`); a third time over every project's folders (`...\project-folders`, 19 Nov). This PC announces
/// `cloudfolder`, `artifacts` and `projectfolders` here, where it takes them.
/// Joined by the integrator: `CloudOwners` returns `.. CloudFilesOwners(subject, deviceId, announce, keeper, serviceNow)`
/// with the account's ONE CloudAnnounce and `CloudBin.ForAccount(folder)` (lane D; never a second Bin), and `RegisterCloudFilesTools()` is called once from
/// `InitializeCloud` (the two tool families need their McpCatalogue line).
public sealed partial class AppRuntime
{
  public CloudFolderOwner? CloudFolder { get; private set; }
  public CloudArtifacts? CloudArtifactsStore { get; private set; }
  /// Folders that travel with a project (19 Nov, row I26): one owner over every project folder of this PC.
  public CloudFolderOwner? CloudProjectFoldersOwner { get; private set; }

  private string? CloudDeviceName(string deviceId) =>
    Cloud.Snapshot.DeviceRows.FirstOrDefault(d => string.Equals(d.DeviceId, deviceId, StringComparison.OrdinalIgnoreCase))?.Name;

  private IReadOnlyList<ICloudSyncAdapter> CloudFilesOwners(string subject, string deviceId, CloudAnnounce announce, CloudBin keeper, Func<long?> serviceNow)
  {
    StopCloudFiles();
    var account = CloudAccountFolder(subject);
    long Now() => serviceNow() ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    var budget = new CloudDayBudget(Path.Combine(account, "file-day-budget.json"));
    IReadOnlyList<string> Waiting(string feature) => announce.DevicesWaiting(feature, 1).Select(d => CloudDeviceName(d) ?? CloudDeleteWords.AnotherDevice).ToArray();
    void Wire(CloudFolderOwner owner, string feature)
    {
      owner.SetWhoWaits(() => Waiting(feature));
      owner.SetDeviceName(CloudDeviceName);
      owner.SetDeleteRuleGate(announce.DeleteRuleIsOpen);
      owner.SetDeleteRuleAnnounced(announce.DeleteRuleAnnounced);
      owner.SetServiceNow(serviceNow);
      owner.SetDayBudget(budget);
      owner.Changed += () => _ = CloudSync?.SyncNowAsync();
    }

    // The Cloud folder is made once, when it first starts on this PC; a folder that is gone later is said on the Cloud
    // page ("Make it again"), never made again by itself.
    var folder = CloudFolderFormat.DefaultFolder();
    var made = Path.Combine(account, "cloud-folder", "folder-made");
    if (!File.Exists(made))
    {
      Directory.CreateDirectory(folder);
      new CloudFileSlot(made).Write("1"u8.ToArray());
    }
    var owner = new CloudFolderOwner(deviceId, folder, Path.Combine(account, "cloud-folder"), keeper,
      () => announce.EveryDeviceUnderstands(CloudFolderFormat.Feature, CloudFolderFormat.Format), now: Now, log: WriteCloudLog);
    Wire(owner, CloudFolderFormat.Feature);

    var artifacts = new CloudArtifacts(deviceId, Path.Combine(account, "artifacts-files"), Path.Combine(account, "artifacts"), keeper,
      () => announce.EveryDeviceUnderstands(CloudArtifactsFormat.Feature, CloudArtifactsFormat.Format), now: Now, log: WriteCloudLog);
    Wire(artifacts.Owner, CloudArtifactsFormat.Feature);
    artifacts.PrepareStore();

    // Folders that travel with a project (Asad, 19 Nov: "everything should travel ... don't worry about cloud limits"):
    // every top-level folder of each project whose one folder on this PC is inside the user's folder, all kinds of files,
    // no day cap of ours (so it never uses the Cloud folder's and artifacts' shared day budget), the Cloud folder's way
    // otherwise. Its private copy is a plain copy (NTFS has no clones).
    var projectFolders = new CloudFolderOwner(deviceId, Path.Combine(account, "project-folders-root"), Path.Combine(account, "project-folders"), keeper,
      () => announce.EveryDeviceUnderstands(CloudProjectFoldersRules.Feature, CloudProjectFoldersRules.Format), CloudFileKind.ProjectFolders, now: Now,
      log: WriteCloudLog, roots: new CloudFolderRoots(ProjectFolderRoots()));
    projectFolders.SetWhoWaits(() => Waiting(CloudProjectFoldersRules.Feature));
    projectFolders.SetDeviceName(CloudDeviceName);
    projectFolders.SetDeleteRuleGate(announce.DeleteRuleIsOpen);
    projectFolders.SetDeleteRuleAnnounced(announce.DeleteRuleAnnounced);
    projectFolders.SetServiceNow(serviceNow);
    projectFolders.Changed += () => _ = CloudSync?.SyncNowAsync();

    // This PC takes Cloud folder, artifacts and project folder records from here on.
    announce.Announce(CloudFolderFormat.Feature, CloudFolderFormat.Format, force: true);
    announce.Announce(CloudArtifactsFormat.Feature, CloudArtifactsFormat.Format, force: true);
    announce.Announce(CloudProjectFoldersRules.Feature, CloudProjectFoldersRules.Format, force: true);

    CloudFolder = owner;
    CloudArtifactsStore = artifacts;
    CloudProjectFoldersOwner = projectFolders;
    owner.StartWatching();
    artifacts.Owner.StartWatching();
    projectFolders.StartWatching();
    if (Artifacts is not null) Artifacts.Changed += FeedCloudArtifacts;
    Projects.Changed += FeedProjectFolderRoots;
    FeedCloudArtifacts();
    return [owner, artifacts.Owner, projectFolders];
  }

  /// Project key -> this PC's folder of that project: the instruction files' project mapping (one folder per project),
  /// only folders inside the user's folder (never the user's folder itself).
  private Dictionary<string, string> ProjectFolderRoots() =>
    CloudProjectFoldersRules.Roots(CloudBootProjectFolders(), Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
  /// A project added, moved or given a folder: the owner looks at the new set next.
  private void FeedProjectFolderRoots() => CloudProjectFoldersOwner?.SetRoots(ProjectFolderRoots());

  /// The Artifacts page's list (the Receiver's recorded outputs) feeds the store: only artifacts inside a project's one
  /// folder on this PC, read, never written.
  private void FeedCloudArtifacts()
  {
    if (CloudArtifactsStore is not { } store || Artifacts is not { } catalogue) return;
    var entries = CloudArtifacts.EntriesFrom(catalogue.Roots().SelectMany(r => catalogue.List(r.Path, null, 2000)).DistinctBy(a => a.Id), id =>
      Projects.List().FirstOrDefault(p => p.Id == id) is { } project && project.Folders.Length == 1 ? (project.Name, project.Folders[0]) : null);
    _ = Task.Run(async () =>
    {
      try { await store.FeedAsync(entries); }
      catch (Exception e) when (e is CloudFailure or IOException or UnauthorizedAccessException) { WriteCloudLog("artifacts: feed failed: " + e.GetType().Name); }
    });
  }

  /// Sign-out, a closed gate or another account: the watchers stop. Nothing is deleted.
  private void StopCloudFiles()
  {
    if (Artifacts is not null) Artifacts.Changed -= FeedCloudArtifacts;
    Projects.Changed -= FeedProjectFolderRoots;
    CloudFolder?.StopWatching();
    CloudArtifactsStore?.Owner.StopWatching();
    CloudProjectFoldersOwner?.StopWatching();
    CloudFolder = null;
    CloudArtifactsStore = null;
    CloudProjectFoldersOwner = null;
  }

  /// The two tool families (cloud.folder, cloud.folder_add, cloud.artifacts), registered once.
  private void RegisterCloudFilesTools()
  {
    CloudFolderTools.Register(Door, () => CloudFolder);
    CloudArtifactsTools.Register(Door, () => CloudArtifactsStore, CloudDeviceName);
  }
}
