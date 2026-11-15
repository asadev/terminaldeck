using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Integration;

/// Cloud on this PC. Built inert in the constructor (no request, key, file or listener); at start-up `ResumeAsync` only
/// reads the protected record if this PC already has one. Sign in starts from Settings → Cloud, or from a
/// `terminaldeck://cloud/signin` link after the person says yes; it finishes by itself when the website hands back
/// `terminaldeck://cloud/return/<token>` for the sign-in this copy started. Agents get the read-only `cloud.status` tool.
public sealed partial class AppRuntime
{
  private LazyCloudHttp? cloudHttp;
  private readonly object cloudLogGate = new();
  public CloudAccountClient Cloud { get; private set; } = null!;
  /// The bridge from the account to the sync engine. Builds nothing while signed out or while "Use Cloud on this PC" is
  /// off. 7C-1: Deck Memory syncs; 7C-2: projects and agents sync first; this PC keeps its copy per account in `cloud\accounts\<account>\memory` (nothing
  /// on Windows reads it yet). Removals do not travel to or from Windows yet and sync never deletes anything here.
  public CloudSyncBridge? CloudSync { get; private set; }

  private void InitializeCloud()
  {
    cloudHttp = new(() => new HttpClientCloudHttp());
    // Device trust: one protected list per account and the protected "How this PC trusts your other devices" choice,
    // both DPAPI files checked by a Credential Manager key; presses refused for two seconds after this app's own remote input.
    var trust = new CloudTrustPorts((issuer, subject) => new WindowsCloudTrustStore(Root, issuer, subject), WindowsCloudTrustStore.TrustMode(Root),
      () => WindowsRemoteInputGuard.JustNow);
    Cloud = CloudComposition.Create(CloudConfiguration.Today(Environment.MachineName, PhoneAppVersion), new WindowsCloudKeyStore(Root), new WindowsCloudBrowser(), cloudHttp,
      trust: trust);
    Cloud.StageLog = WriteCloudLog;
    // Lane C: this PC's machine (hashed MachineGuid, never sent) for the launch describe, set before ResumeCloudAsync.
    Cloud.Machine = CloudMachineFacts.System(Path.Combine(Root.DirectoryPath, "cloud", "machine.mark"),
      CloudMachineFacts.CopyName(Root.DirectoryPath, StableChannel.Root(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile)).DirectoryPath));
    CloudTools.Register(Cloud, Door, () => CloudChats?.Uploader?.StatusWire());
    CloudSync = new CloudSyncBridge(Cloud, new CloudSyncPlatform(
      subject => CloudSyncStore.InFolder(CloudAccountFolder(subject), subject),
      () => new HttpClientCloudSyncHttp(), new ClientWebSocketCloudSyncSockets(), new CloudSyncEndpoint(new Uri(CloudWire.ProductionBase), test: false),
      CloudOwners, Secrets: CloudSecretsPlatform()), WriteCloudLog);
    // Lane R: the account's socket events reach by sign-in needs (`devices`, `gate`, `hello`).
    CloudSync.AccountEvent += e =>
    {
      if (e.Type is not ("devices" or "gate" or "hello")) return;
      using var payload = System.Text.Json.JsonDocument.Parse(CloudCanonical.Encode(e.Payload));
      ReachEvent(e.Type, payload.RootElement.Clone());
    };
    // Lane D: the AI delete witness, once (until the hook envelope carries the tool fields every gone file counts as by hand).
    CloudWitness = new CloudAiDeleteWitness(Root.DirectoryPath, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), DateTimeOffset.UtcNow);
    CloudDeleteWitnessSlot.Shared.InstallOnce(CloudWitness);
    // Lane S3: project secret files' tool.
    CloudProjectSecretFilesTools.Register(CloudProjectSecretFilesHolder.Shared, Door);
    RegisterCloudFilesTools();
    InitializeCloudChats();
    CloudSync.Start();
  }

  /// THE ONE SWITCH for every announcement this PC would write (`deleterule` none, `cloudfolder` v1, `artifacts` v1 and
  /// their 12-hour renewals). OFF until the saved-passwords lane and the task/agent/project records lane are joined and
  /// Decker says so: a signed-in PC that announced half would hold back parts of sync on the Macs. While off, nothing is
  /// written and nothing is remembered for later.
  private const bool CloudAnnouncementsOn = false;
  private Timer? cloudAnnounceTimer;
  /// Lane D's AI delete witness (one per app); the MCP-servers store reads it for `claude mcp remove`.
  public CloudAiDeleteWitness? CloudWitness { get; private set; }
  /// The account's ONE announcer while signed in (lane S3's gate reads it).
  private CloudAnnounce? cloudAnnounce;
  /// The signed-in account's record owners (projects, agents): deletes made in the app go through them so they travel.
  public CloudRecordsForAccount? CloudRecords { get; private set; }

  /// The account's computers for the announcements (lowercased device ids), null while the list is not known.
  private IReadOnlyCollection<string>? CloudComputers() =>
    Cloud.Snapshot is { Phase: CloudPhase.SignedIn or CloudPhase.Paused, DeviceRows.Count: > 0 } s
      ? s.DeviceRows.Where(d => d.Trust is not { Removed: true }).Select(d => d.DeviceId.ToLowerInvariant()).ToArray() : null;

  /// At start and every hour: the announcements are renewed when 12 hours old (CloudAnnounce decides), the waiting ones
  /// retried, and once a day the Bin's 30-day sweep runs. With the switch off the announcement half writes nothing.
  private void StartCloudHousekeeping(CloudAnnounce announce, string folder)
  {
    cloudAnnounceTimer?.Dispose();
    long lastSweep = 0;
    cloudAnnounceTimer = new Timer(_ =>
    {
      try
      {
        // Lane R2's switch (CloudDeleteRuleSwitch.AnnounceV1, off) inside the one switch (CloudAnnouncementsOn, off).
        CloudDeleteRuleSwitch.Announce(announce);
        announce.Announce(CloudFolderFormat.Feature, CloudFolderFormat.Format);
        announce.Announce(CloudArtifactsFormat.Feature, CloudArtifactsFormat.Format);
        // Lane S3: also while saved passwords are locked (a PC waiting for the key must not hold the gate shut).
        announce.Announce(CloudProjectSecretFilesRules.Feature, CloudProjectSecretFilesRules.Format);
        announce.RetryPending();
        var now = CloudSync?.ServiceNow ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        if (now - lastSweep >= 86_400_000) { CloudBin.ForAccount(folder).Sweep(now); lastSweep = now; }
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { WriteCloudLog("cloud housekeeping: " + ex.GetType().Name); }
    }, null, TimeSpan.FromSeconds(30), TimeSpan.FromHours(1));
  }

  private string CloudAccountFolder(string subject) => Path.Combine(Root.DirectoryPath, "cloud", "accounts", subject);

  /// 7C-2: projects, then agents, then memory, then (7C-4) tasks and settings, then (7C-3) AI instruction files (the Mac's rule G: projects and agents go before anything else queued).
  /// A project that arrives gets its own folder by itself under `%USERPROFILE%\Terminal Deck\Projects`; project memory
  /// is placed once its project is on this PC. Widening agent fields apply under automatic trust (the default).
  private IReadOnlyList<ICloudSyncAdapter> CloudOwners(string subject, string deviceId)
  {
    var folder = CloudAccountFolder(subject);
    CloudProjectFolders.Installed ??= new CloudProjectFolders(Path.Combine(Root.DirectoryPath, "cloud", "project-folders.json"),
      Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), [Root.DirectoryPath]);
    var trustMode = new CloudTrustModeStore(WindowsCloudTrustStore.TrustMode(Root));
    CloudMemoryAdapter? memory = null;
    var records = new CloudRecordsForAccount(folder, subject, deviceId, Projects, Agents, CloudProjectFolders.Installed,
      () => trustMode.Load() == CloudTrustMode.Account, () => memory?.RetryProjects());
    memory = CloudMemoryAdapter.ForAccount(folder, deviceId, records.Projects.MemoryProject, deviceName: CloudDeviceName, thisDeviceName: Environment.MachineName);
    // Lane D: ONE announce per account, shared by memory, instruction files and the Cloud folder / artifacts owners.
    var announce = new CloudAnnounce(memory.Store, () => deviceId, () => CloudSync?.ServiceNow, CloudComputers,
      new CloudFileSlot(Path.Combine(folder, "sync", "announce-pending.json")), send: CloudAnnouncementsOn);
    memory.UseAnnounce(announce);
    cloudAnnounce = announce;
    // Lane S: saved passwords' removals follow the same gate (closed while nothing is announced).
    CloudSecretsDeleteRuleOpen = announce.DeleteRuleIsOpen;
    // Lane R2: tasks, agents and projects follow the delete rule (record version 2); gate closed = old-form removals only.
    records.ConfigureDeleteRule(announce.DeleteRuleIsOpen, CloudDeviceName, () => CloudSync?.ServiceNow);
    CloudRecords = records;
    CloudRecordDeletes.Current = () => Cloud.SyncIdentity is { } who && who.Subject == subject ? CloudRecords : null;
    // 7C-4: tasks and settings, in their own record store (the Mac keeps them apart from projects and agents).
    var kinds = new CloudKindsForAccount(folder, subject, deviceId, TerminalDeck.Core.Tasks.TaskStore.At(Root), Projects,
      CloudSettingsOwner.ForWindows(General, TerminalAppearance), () => trustMode.Load() == CloudTrustMode.Account);
    kinds.ConfigureDeleteRule(announce.DeleteRuleIsOpen, CloudDeviceName, () => CloudSync?.ServiceNow);
    // 7C-3: AI instruction files last (AppRuntime.CloudBootFiles.cs).
    var owners = new List<ICloudSyncAdapter>([.. records.Adapters, memory, .. kinds.Adapters,
      CloudBootFilesOwner(subject, deviceId, () => trustMode.Load() == CloudTrustMode.Account, announce)]);
    // Lane F: the Cloud folder and artifacts, on the account's ONE Bin.
    owners.AddRange(CloudFilesOwners(subject, deviceId, announce, CloudBin.ForAccount(folder), () => CloudSync?.ServiceNow));
    StartCloudHousekeeping(announce, folder);
    return owners;
  }

  /// One plain line per sign-in stage, in `logs\cloud.log` of this copy's own data folder. The lines never carry a token,
  /// code, key, e-mail or name (CloudAccountClient writes only stage names and error kinds).
  private void WriteCloudLog(string line)
  {
    try
    {
      lock (cloudLogGate)
      {
        var logs = Path.Combine(Root.DirectoryPath, "logs");
        Directory.CreateDirectory(logs);
        File.AppendAllText(Path.Combine(logs, "cloud.log"), DateTimeOffset.UtcNow.ToString("O") + " " + line + Environment.NewLine);
      }
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
  }

  private async Task ResumeCloudAsync()
  {
    // A damaged or unreadable record leaves Cloud signed out; it never stops the app from starting.
    try { await Cloud.ResumeAsync(); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { }
  }

  private void DisposeCloud() { cloudAnnounceTimer?.Dispose(); CloudChats?.Detach(); CloudSync?.Dispose(); Cloud?.Dispose(); cloudHttp?.Dispose(); }
}
