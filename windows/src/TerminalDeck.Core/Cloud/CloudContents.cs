namespace TerminalDeck.Core.Cloud;

// Lane U1 (15 Nov), the Mac's BackendCloudContents.swift + BackendCloudFiles.swift: "what is in your Cloud", as rows.
// One row per thing, by name and date; a row's "On" is empty in its normal state and says only "Not on this PC" or
// "Only on this PC". The Bin is one line per removal, with the device's NAME. The screens (lane U2) draw exactly this:
// no id, path, key or fingerprint ever reaches a row's visible text (`Id` and `Folder` route; `Name`, dates and the
// words in `CloudContentsWords` are what is shown).
//
// Every kind comes from ONE small provider (`ICloudContentsSource`). A kind with no provider has no place and no rows,
// so a kind joined later (saved passwords, project secret files, records v2) is registered, never rewritten in.

/// The places, in the order the page lists them (DESIGN-WINDOWS-CLOUD.md 2). "Code" is drawn by the screens only (it
/// opens the GitHub page); it has no rows here.
public enum CloudContentsKind { Memory, Projects, Agents, InstructionFiles, Tasks, Settings, Artifacts, CloudFolder, Sessions, Passwords }

/// A row's one state. `InSync` is the normal state: its "On" column is EMPTY.
public enum CloudItemState { InSync, NotOnThisPc, OnlyOnThisPc }

/// One place on the left: its title and how many items it holds. `CanBin*` say which bin actions the top bar offers for
/// rows of this place (none for a kind whose delete rule is not open, none for tasks' and agents' "Cloud").
public sealed record CloudContentsPlace(CloudContentsKind Kind, string Title, int Count, bool CanBinCloud, bool CanBinEverywhere);

/// One thing in his Cloud. `Id` routes (never shown). `Folder` is the folders it sits in inside its kind, by name
/// (empty = top of its kind). `Detail` is the secondary text after the name or at the right (a task's state, a
/// setting's value); nil for every other kind.
public sealed record CloudContentsRow(string Id, CloudContentsKind Kind, string Name, IReadOnlyList<string> Folder, long ChangedAt, string? ChangedBy,
  long? Bytes, CloudItemState State, string? Detail = null, bool CanOpen = true, bool IsSecret = false)
{
  /// The "On" column: empty for an item in its normal state.
  public string OnText => CloudContentsWords.On(State);
}

/// One folder inside a kind ("Deck Dev", "Lead"), with how many things it holds below it.
public sealed record CloudContentsFolderRow(CloudContentsKind Kind, IReadOnlyList<string> Path, string Name, int Items);

/// What one folder of a kind lists: folders first, then items.
public sealed record CloudContentsListing(IReadOnlyList<CloudContentsFolderRow> Folders, IReadOnlyList<CloudContentsRow> Items);

/// One read of his Cloud: the places (only kinds with a provider) and every row of them.
public sealed record CloudContentsSnapshot(IReadOnlyList<CloudContentsPlace> Places, IReadOnlyList<CloudContentsRow> Rows, int BinCount)
{
  /// What one folder of a kind lists, filtered by the search words (name or folder).
  public CloudContentsListing List(CloudContentsKind kind, IReadOnlyList<string> folder, string search = "") => CloudContents.Listing(Rows, kind, folder, search);
}

/// One line of the Bin: one removal (a group, across kinds when one press removed several). `Id` routes; `What` is the
/// name or "12 notes in Deck Dev"; `Device` is the device's NAME.
public sealed record CloudBinLine(string Id, IReadOnlyList<CloudContentsKind> Kinds, string What, long At, string Device, bool ByAi, int Count)
{
  /// "Removed on MacBook Pro", "Removed by an AI on MacBook Pro".
  public string Title => ByAi ? CloudDeleteWords.RemovedByAi(Device) : CloudDeleteWords.Removed(Device);
}

/// An opened item for the reading pane. A saved password or secret file carries its name and date only, never a value.
public sealed record CloudOpenedItem(string Name, long ChangedAt, string? Text, byte[]? Bytes, string? MediaType, string? WhereLine, bool IsSecret = false);

/// What an action did: how many rows it did and, when it could not do all of them, one plain line to show.
public sealed record CloudContentsResult(int Done, string? Line = null);

/// One kind's provider. Rows are read from the kind's owner; removals go through its `ICloudDeleteOwning` (null = the
/// kind offers no bin action, no bring back and no Bin lines).
public interface ICloudContentsSource
{
  CloudContentsKind Kind { get; }
  Task<IReadOnlyList<CloudContentsRow>> RowsAsync(CancellationToken cancel);
  Task<CloudOpenedItem?> OpenAsync(CloudContentsRow row, CancellationToken cancel);
  ICloudDeleteOwning? Removals { get; }
  /// Tasks and agents are always removed everywhere: no "Cloud" bin for them.
  bool OffersCloudOnly => true;
  CloudDeleteItem DeleteItem(CloudContentsRow row);
}

public static class CloudContentsWords
{
  public const string OpenButton = "Manage files", WindowTitle = "Your Cloud", Bin = "Bin", Open = "Open", NothingYet = "Nothing of this kind is in your Cloud yet.",
    SignedOut = "Sign in to see what is in your Cloud.", BinEmptiesAfter = "Items in the Bin are deleted for good after 30 days.";
  public static string On(CloudItemState state) => state switch
  {
    CloudItemState.NotOnThisPc => CloudDeleteWords.NotOnThisPc,
    CloudItemState.OnlyOnThisPc => CloudDeleteWords.OnlyOnThisPc,
    _ => ""
  };
  public static string Title(CloudContentsKind kind) => kind switch
  {
    CloudContentsKind.Memory => "Memory",
    CloudContentsKind.Projects => "Projects",
    CloudContentsKind.Agents => "Agents",
    CloudContentsKind.InstructionFiles => "Instruction files",
    CloudContentsKind.Tasks => "Tasks",
    CloudContentsKind.Settings => "Settings",
    CloudContentsKind.Artifacts => "Artifacts",
    CloudContentsKind.CloudFolder => "Cloud folder",
    CloudContentsKind.Sessions => "Sessions and chats",
    _ => "Saved passwords"
  };
  public static string Items(int count) => count == 1 ? "1 item" : count + " items";
}

/// The contents reader and its actions. The page's actions belong to the person ONLY (never an AI tool).
public sealed class CloudContents
{
  public CloudContents(Func<bool> deleteRuleOpen, Func<CloudDeleteActor> person) => throw new NotImplementedException("not yet");

  /// Adds (or replaces) the provider of one kind.
  public void Register(ICloudContentsSource source) => throw new NotImplementedException("not yet");

  /// Every place with a provider and every row of them. One failing provider leaves its place empty; the rest list.
  public Task<CloudContentsSnapshot> ReadAsync(CancellationToken cancel = default) => throw new NotImplementedException("not yet");

  public Task<CloudOpenedItem?> OpenAsync(CloudContentsRow row, CancellationToken cancel = default) => throw new NotImplementedException("not yet");

  /// Bin "Cloud": out of his Cloud and his other devices, kept on this PC ("Only on this PC").
  public Task<CloudContentsResult> RemoveFromCloudAsync(IReadOnlyList<CloudContentsRow> rows) => throw new NotImplementedException("not yet");

  /// Bin "Everywhere": into the Bin on every device.
  public Task<CloudContentsResult> RemoveEverywhereAsync(IReadOnlyList<CloudContentsRow> rows) => throw new NotImplementedException("not yet");

  /// "Bring back" for rows "Not on this PC".
  public Task<CloudContentsResult> BringBackAsync(IReadOnlyList<CloudContentsRow> rows) => throw new NotImplementedException("not yet");

  /// "Put in Cloud again" for rows "Only on this PC".
  public Task<CloudContentsResult> PutInCloudAgainAsync(IReadOnlyList<CloudContentsRow> rows) => throw new NotImplementedException("not yet");

  /// The Bin, newest removal first.
  public Task<IReadOnlyList<CloudBinLine>> BinAsync(CancellationToken cancel = default) => throw new NotImplementedException("not yet");

  /// "Put back all" for the selected lines.
  public Task<CloudContentsResult> PutBackAllAsync(IReadOnlyList<CloudBinLine> lines) => throw new NotImplementedException("not yet");

  /// "Delete for good" (right-click only).
  public Task<CloudContentsResult> DeleteForGoodAsync(IReadOnlyList<CloudBinLine> lines) => throw new NotImplementedException("not yet");

  public static CloudContentsListing Listing(IReadOnlyList<CloudContentsRow> rows, CloudContentsKind kind, IReadOnlyList<string> folder, string search) =>
    throw new NotImplementedException("not yet");
}
