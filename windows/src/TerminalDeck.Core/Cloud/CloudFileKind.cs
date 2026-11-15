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
  /// `cloud-folder` (I24) or `artifacts` (I23): each kind has a domain of its own.
  public string Domain => CloudFolderFormat.DomainOf(InventoryRow);
  /// The same path rules for both kinds (hidden, temporary, links' names, package folders, the never-send list).
  public CloudFolderSkip? Refusal(string relative) => CloudFolderRules.Refusal(relative);

  /// The Cloud folder, every value as the Mac's slice 1.
  public static readonly CloudFileKind CloudFolder = new(CloudFolderFormat.InventoryRow, "folder", "cloudFolder", "Cloud folder",
    CloudFolderFormat.Feature, CloudFolderFormat.Format, CloudFolderFormat.MaximumFileBytes, CloudFolderFormat.MaximumFolderBytes, _ => true, true,
    new(CloudFolderFormat.GateLine, CloudFolderFormat.RoomLowLine, CloudFolderFormat.FolderFullLine, CloudFolderFormat.DayFullLine, CloudFolderFormat.BusyLine,
      CloudFolderFormat.DiskLowLine, CloudFolderFormat.TooLargeLine, CloudFolderFormat.SecretLine, CloudFolderFormat.SpellingLine, CloudFolderFormat.ClashLine,
      "Your Cloud folder is not on this PC. Nothing was removed from your other devices.", CloudFolderFormat.Exclusions,
      "cloud folder: the safety copy of the Cloud folder could not be made, so nothing in it is replaced or removed by sync yet. It tries again by itself."));

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
