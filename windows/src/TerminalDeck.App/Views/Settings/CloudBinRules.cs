using System.Globalization;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Views.Settings;

/// The Bin page's rules without a screen (DESIGN-WINDOWS-CLOUD.md section 3), so they are tested on any machine:
/// which lines are shown for a search, what the top bar's one action and the right-click menu offer for a selection,
/// and that each press is ONE call to the reader with every selected line. CloudBinPage only draws what this says.
public sealed class CloudBinRules
{
  public const string PutBack = "Put back", DeleteForGood = "Delete for good", Info = "About the Bin";
  /// Until Core carries `CloudContentsWords.BinEmpty` (requested in the result file), the one calm line of an empty Bin.
  public const string Empty = TerminalDeck.Core.Cloud.CloudContentsWords.BinEmpty;
  public const string NoMatch = "Nothing in the Bin matches.";
  public const string Failed = "Could not finish that. Nothing was changed.";

  private readonly Func<CancellationToken, Task<IReadOnlyList<CloudBinLine>>> read;
  private readonly Func<IReadOnlyList<CloudBinLine>, Task<CloudContentsResult>> putBack;
  private readonly Func<IReadOnlyList<CloudBinLine>, Task<CloudContentsResult>> deleteForGood;

  public CloudBinRules(Func<CancellationToken, Task<IReadOnlyList<CloudBinLine>>> read,
    Func<IReadOnlyList<CloudBinLine>, Task<CloudContentsResult>> putBack, Func<IReadOnlyList<CloudBinLine>, Task<CloudContentsResult>> deleteForGood)
  { this.read = read; this.putBack = putBack; this.deleteForGood = deleteForGood; }

  public static CloudBinRules For(CloudContents contents) => new(contents.BinAsync, contents.PutBackAllAsync, contents.DeleteForGoodAsync);

  public IReadOnlyList<CloudBinLine> Lines { get; private set; } = [];
  public string Search { get; set; } = "";
  public bool Working { get; private set; }
  /// The one plain line after a press that could not do everything (or failed); null otherwise.
  public string? Line { get; private set; }

  /// Newest removal first; the search looks at what it was and where it was removed, never at ids.
  public IReadOnlyList<CloudBinLine> Shown()
  {
    var search = Search.Trim();
    return Lines.Where(l => search.Length == 0 || l.What.Contains(search, StringComparison.CurrentCultureIgnoreCase) || l.Title.Contains(search, StringComparison.CurrentCultureIgnoreCase))
      .OrderByDescending(l => l.At).ToArray();
  }

  /// The one calm line when nothing is shown, or null when lines are shown.
  public string? EmptyLine() => Shown().Count > 0 ? null : Lines.Count == 0 ? Empty : NoMatch;

  /// The top bar's one action: greyed with nothing selected or while a press runs.
  public bool CanPutBackAll(IReadOnlyCollection<CloudBinLine> selected) => selected.Count > 0 && !Working;

  /// The right-click menu of a selection: every removal can be put back or deleted for good; nothing else.
  public IReadOnlyList<string> Menu(IReadOnlyCollection<CloudBinLine> selected) => selected.Count == 0 || Working ? [] : (string[])[PutBack, DeleteForGood];

  /// The standard confirm's question for "Delete for good" (asked once, for the whole selection).
  public static (string Title, string Text) DeleteForGoodQuestion(IReadOnlyList<CloudBinLine> selected) =>
    (selected.Count == 1 ? "Delete “" + selected[0].What + "” for good?" : "Delete " + selected.Count + " removals for good?",
     "It is removed from the Bin on every device and cannot be put back.");

  public async Task RefreshAsync(CancellationToken cancel = default)
  {
    try { Lines = await read(cancel); }
    catch (Exception ex) when (ex is not OutOfMemoryException and not OperationCanceledException) { Lines = []; Line = Failed; }
  }

  /// "Put back all" and the menu's "Put back": ONE call with every selected line, then the Bin is read again.
  public Task PutBackAsync(IReadOnlyList<CloudBinLine> selected) => PressAsync(selected, putBack);
  /// "Delete for good" after its one confirm: ONE call with every selected line, then the Bin is read again.
  public Task DeleteForGoodAsync(IReadOnlyList<CloudBinLine> selected) => PressAsync(selected, deleteForGood);

  private async Task PressAsync(IReadOnlyList<CloudBinLine> selected, Func<IReadOnlyList<CloudBinLine>, Task<CloudContentsResult>> press)
  {
    if (selected.Count == 0 || Working) return;
    Working = true; Line = null;
    try { Line = (await press(selected.ToArray())).Line; }
    catch (Exception ex) when (ex is not OutOfMemoryException) { Line = Failed; }
    finally { Working = false; }
    var line = Line;
    await RefreshAsync();
    Line ??= line;
  }

  /// When, as a person says it: "Today, 9:52 AM", "Yesterday, 9:53 AM", else "12 Nov 2026".
  public static string When(long atMs, DateTimeOffset now)
  {
    var at = DateTimeOffset.FromUnixTimeMilliseconds(atMs).ToLocalTime();
    var day = at.Date; var today = now.ToLocalTime().Date;
    var time = at.ToString("t", CultureInfo.CurrentCulture);
    if (day == today) return "Today, " + time;
    if (day == today.AddDays(-1)) return "Yesterday, " + time;
    return at.ToString("d MMM yyyy", CultureInfo.CurrentCulture);
  }
}
