using System.Text.Json;

namespace TerminalDeck.Core.Cloud;

// Lane F (15 Nov), the Mac's one file-engine owner run twice (td-mac-next2 CloudFileKind.swift): ONE owner
// (CloudFolderOwner) for every kind that travels as files of a folder: the Cloud folder (`%USERPROFILE%\Terminal Deck
// Cloud`, row I24) and his artifacts (an app-private store, row I23). What differs between them is only this
// description: the row, the source, the keeper's kind, the words on the page, and which files are counted as items.

/// The plain lines one kind says on the Cloud page (names and plain words only).
public sealed record CloudFileKindWords(Func<IReadOnlyList<string>, string> Gate, string RoomLow, string Full, string DayFull, Func<int, string> Busy,
  string DiskLow, Func<int, string> TooLarge, Func<IReadOnlyList<string>, string> Secret, Func<IReadOnlyList<string>, string> Spelling,
  Func<IReadOnlyList<string>, string> Clash, string FolderMissing, IReadOnlyList<string> Exclusions, string SafetyCopyFailed);

public sealed record CloudFileKind(string InventoryRow, string SourceId, string KeeperKind, string Label, string Feature, int Format,
  long MaximumFileBytes, long MaximumFolderBytes, Func<string, bool> Listed, bool ListsAll, CloudFileKindWords Words)
{
  /// `cloud-folder` (I24), `artifacts` (I23) or `project-folders` (I26): each kind has a domain of its own.
  public string Domain => CloudFolderFormat.DomainOf(InventoryRow);
  /// The kind's own path rule; null = the Cloud folder's (hidden, temporary, links' names, package folders, the
  /// never-send list).
  public Func<string, CloudFolderSkip?>? PathRule { get; init; }
  public CloudFolderSkip? Refusal(string relative) => PathRule is { } rule ? rule(relative) : CloudFolderRules.Refusal(relative);
  /// Bytes this PC may send of this kind a day; null = no cap of ours (project folders, Asad 19 Nov: "don't worry about
  /// cloud limits").
  public long? DailySendBytes { get; init; } = CloudFolderFormat.DailySendBytes;
  /// False: this kind keeps sending when the account's room is low (the service answers if it is really full).
  public bool ObeysRoomFloor { get; init; } = true;
  /// The most files one look carries; past it the look is not reliable (nothing is inferred) and the rest waits.
  public int MaximumFiles { get; init; } = CloudFolderFormat.MaximumFiles;
  /// The most bytes one look records; the rest goes in the next looks (a first upload of gigabytes goes in steps, so the
  /// PC and the other kinds' sends are never held up). Null = no pacing.
  public long? BytesPerLook { get; init; }
  /// Seconds between the owner's looks (2 for the Cloud folder; longer for a large tree).
  public int LookSeconds { get; init; } = 2;
  /// Free disk this kind always leaves (21 Nov, the Mac's 0.23.4 rule): below it nothing new is recorded and the rest
  /// waits in his own folders. Null = none.
  public long? RecordFloorBytes { get; init; }
  /// Bytes recorded but not yet handed to the sync; past it, recording waits for the upload, so the private copy never
  /// runs far ahead of the Cloud. Null = no cap.
  public long? UnsentCapBytes { get; init; }
  /// Bytes of file pieces one capture hands to the sync's queue (a large file goes in batches); the sync takes the next
  /// batch once the queue has gone. Null = the whole journal at once, as before.
  public long? CaptureBytes { get; init; }

  /// The Cloud folder, every value as the Mac's slice 1.
  public static readonly CloudFileKind CloudFolder = new(CloudFolderFormat.InventoryRow, "folder", "cloudFolder", "Cloud folder",
    CloudFolderFormat.Feature, CloudFolderFormat.Format, CloudFolderFormat.MaximumFileBytes, CloudFolderFormat.MaximumFolderBytes, _ => true, true,
    new(CloudFolderFormat.GateLine, CloudFolderFormat.RoomLowLine, CloudFolderFormat.FolderFullLine, CloudFolderFormat.DayFullLine, CloudFolderFormat.BusyLine,
      CloudFolderFormat.DiskLowLine, CloudFolderFormat.TooLargeLine, CloudFolderFormat.SecretLine, CloudFolderFormat.SpellingLine, CloudFolderFormat.ClashLine,
      "Your Cloud folder is not on this PC. Nothing was removed from your other devices.", CloudFolderFormat.Exclusions,
      "cloud folder: the safety copy of the Cloud folder could not be made, so nothing in it is replaced or removed by sync yet. It tries again by itself."));

  /// Folders that travel with a project (Asad, 19 Nov: "everything should travel ... including actually pictures and
  /// everything don't worry about cloud limits"): row I26, every top-level folder of every project on this PC, under one
  /// domain; a record's path is `<project key>/<folder>/<path in it>` (CloudProjectFoldersRules). NTFS has no clones, so
  /// the private copy is a plain second copy of what travels.
  public static readonly CloudFileKind ProjectFolders = new(CloudProjectFoldersRules.InventoryRow, "projects", "projectFolders", "Project folders",
    CloudProjectFoldersRules.Feature, CloudProjectFoldersRules.Format, long.MaxValue, long.MaxValue, _ => true, true,
    new(names => CloudFolderFormat.GateLine(names).Replace("Cloud folder", "project folders", StringComparison.Ordinal), "", "", "", CloudFolderFormat.BusyLine,
      CloudFolderFormat.DiskLowLine, _ => "", _ => "", CloudFolderFormat.SpellingLine, CloudFolderFormat.ClashLine,
      "A project's folder is not on this PC. Nothing was removed from your other devices.", CloudProjectFoldersRules.Exclusions,
      "project folders: the safety copy could not be made, so nothing in them is replaced or removed by sync yet. It tries again by itself."))
  {
    PathRule = CloudProjectFoldersRules.Refusal, DailySendBytes = null, ObeysRoomFloor = false, MaximumFiles = 2_000_000,
    BytesPerLook = 256L * 1_048_576, LookSeconds = 10,
    // 21 Nov (Mac 0.23.4 disk fault): never under 5 GB free, at most 256 MB ahead of the upload, 2 MB per hand-over
    // (the Windows sync queue is one file written whole at every change, so it must stay small).
    RecordFloorBytes = 5L * 1_073_741_824, UnsentCapBytes = 256L * 1_048_576, CaptureBytes = 2L * 1_048_576
  };

  /// His artifacts (row I23): the app's own store of them.
  public static readonly CloudFileKind Artifacts = new(CloudArtifactsFormat.InventoryRow, "artifacts", "artifacts", "Artifacts",
    CloudArtifactsFormat.Feature, CloudArtifactsFormat.Format, CloudArtifactsFormat.MaximumFileBytes, CloudArtifactsFormat.MaximumStoreBytes,
    p => !CloudArtifactsFormat.IsAbout(p), false,
    new(CloudArtifactsFormat.GateLine, CloudArtifactsFormat.RoomLowLine, CloudArtifactsFormat.FullLine, CloudArtifactsFormat.DayFullLine, CloudArtifactsFormat.BusyLine,
      CloudArtifactsFormat.DiskLowLine, CloudArtifactsFormat.TooLargeLine, CloudArtifactsFormat.SecretNameLine, CloudArtifactsFormat.SpellingLine,
      CloudArtifactsFormat.ClashLine, "Your artifacts kept for your other devices are not on this PC. Nothing was removed from your other devices.",
      CloudArtifactsFormat.Exclusions,
      "artifacts: the safety copy of the artifacts kept for your other devices could not be made, so none is replaced or removed by sync yet. It tries again by itself."));
}

/// The ONE daily send budget of the file kinds on this PC (200 MB a day, the Cloud folder and artifacts together). A
/// small file beside the account's Cloud state; a new day (on the Cloud's clock) starts at 0.
public sealed class CloudDayBudget(string file)
{
  private static readonly object Lock = new();
  private sealed class Held { public long Day { get; set; } public long Sent { get; set; } }
  private Held? Read()
  {
    try { return File.Exists(file) ? JsonSerializer.Deserialize<Held>(File.ReadAllBytes(file)) : null; }
    catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { return null; }
  }
  /// Bytes sent today by every file kind of this PC.
  public long Sent(long day) { lock (Lock) return Read() is { } h && h.Day == day ? h.Sent : 0; }
  public void Add(long bytes, long day)
  {
    lock (Lock)
    {
      var held = Read() is { } h && h.Day == day ? h : new Held { Day = day };
      new CloudFileSlot(file).Write(JsonSerializer.SerializeToUtf8Bytes(new Held { Day = day, Sent = held.Sent + bytes }));
    }
  }
}
