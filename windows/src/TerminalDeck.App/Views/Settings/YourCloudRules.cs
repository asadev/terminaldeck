using System.Globalization;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Views.Settings;

// The Your Cloud page's rules (DESIGN-WINDOWS-CLOUD.md 2 and 3), plain .NET so Core.Tests run them without a window.
// The page draws exactly what these return: the places on the left, the top bar's actions for what is selected, the
// columns' words. Names and dates only; a row's `Id` routes and is never drawn.

/// One row on the left. `Code` opens the GitHub page; `Bin` sits at the bottom, set apart by space.
public sealed record YourCloudPlaceRow(string Key, string Title, string Count, CloudContentsKind? Kind, bool IsCode = false, bool IsBin = false);

/// The top bar's actions for the selection. A false action is not drawn, except Open and the two bins, which are drawn
/// greyed while nothing is selected (the design's "greyed with nothing selected").
public sealed record YourCloudActions(bool Open, bool BinCloud, bool BinEverywhere, bool BringBack, bool PutInCloudAgain, bool ShowBins);

public static class YourCloudRules
{
  public const string CodeTitle = "Code", BinTitle = "Bin", PutBackAll = "Put back all", DeleteForGood = "Delete for good",
    BringBack = "Bring back", PutInCloudAgain = "Put in Cloud again", BinCloud = "Cloud", BinEverywhere = "Everywhere", Open = "Open",
    BinInfo = "Items in the Bin are deleted for good after 30 days. Put back brings them back on every device.";

  public static bool Nameless(CloudContentsRow row) => row.State == CloudItemState.NotOnThisPc && (row.Kind is CloudContentsKind.Tasks or CloudContentsKind.Agents or CloudContentsKind.Projects)
    && (row.Name == CloudContentsWords.Title(row.Kind) || row.Name.Contains("not on this", StringComparison.OrdinalIgnoreCase));

  public static string MissingName(CloudContentsKind kind, int count) => count.ToString(CultureInfo.CurrentCulture) + " " + (kind switch { CloudContentsKind.Tasks => "tasks", CloudContentsKind.Agents => "agents", _ => "projects" }) + " that are not on this PC";

  /// Memory … Saved passwords in the page order (only kinds Core lists), then Code, then the Bin.
  public static IReadOnlyList<YourCloudPlaceRow> Places(CloudContentsSnapshot snapshot)
  {
    var rows = new List<YourCloudPlaceRow>();
    foreach (var kind in Enum.GetValues<CloudContentsKind>())
      if (snapshot.Places.FirstOrDefault(p => p.Kind == kind) is { } place)
        rows.Add(new(kind.ToString(), place.Title, place.Count > 0 ? place.Count.ToString(CultureInfo.CurrentCulture) : "", kind));
    rows.Add(new("Code", CodeTitle, "", null, IsCode: true));
    rows.Add(new("Bin", BinTitle, snapshot.BinCount > 0 ? snapshot.BinCount.ToString(CultureInfo.CurrentCulture) : "", null, IsBin: true));
    return rows;
  }

  /// What the top bar offers for the selected items of one place. Selected rows "Not on this PC" show only "Bring back"
  /// (in place of the bins); rows "Only on this PC" only "Put in Cloud again". No bins at all for a place whose delete
  /// rule is not open (Core says so per place). Folders are never acted on from here: only items count.
  /// The reading pane's header shows the note's name; its first heading is not drawn again when it says the same.
  public static bool RepeatsTitle(string? heading, string? title) =>
    heading is not null && title is not null && string.Equals(heading.Trim().Trim('*', '_').Trim(), title.Trim(), StringComparison.OrdinalIgnoreCase);

  public static YourCloudActions For(CloudContentsPlace? place, IReadOnlyList<CloudContentsRow> selected)
  {
    var canCloud = place?.CanBinCloud == true;
    var canEverywhere = place?.CanBinEverywhere == true;
    var showBins = canCloud || canEverywhere;
    if (selected.Count == 0) return new(false, false, false, false, false, showBins);
    if (selected.All(r => r.State == CloudItemState.NotOnThisPc)) return new(selected.Count == 1 && selected[0].CanOpen, false, false, true, false, false);
    if (selected.All(r => r.State == CloudItemState.OnlyOnThisPc)) return new(selected.Count == 1 && selected[0].CanOpen, false, false, false, true, false);
    var normal = selected.All(r => r.State == CloudItemState.InSync);
    return new(selected.Count == 1 && selected[0].CanOpen, normal && canCloud, normal && canEverywhere, false, false, showBins);
  }

  /// The secondary text after a row's name: a task's state, a setting's value; nothing for other kinds.
  public static string Detail(CloudContentsRow row) => row.Detail?.Trim() ?? "";

  /// "Today, 9:48 AM", "Yesterday, 6:02 PM", "12 Nov 2026".
  public static string Changed(long ms, DateTimeOffset? now = null)
  {
    if (ms <= 0) return "";
    var at = DateTimeOffset.FromUnixTimeMilliseconds(ms).ToLocalTime();
    var today = (now ?? DateTimeOffset.Now).ToLocalTime().Date;
    var time = at.ToString("t", CultureInfo.CurrentCulture);
    if (at.Date == today) return "Today, " + time;
    if (at.Date == today.AddDays(-1)) return "Yesterday, " + time;
    return at.ToString("d MMM yyyy", CultureInfo.CurrentCulture);
  }

  /// "12 KB", "3.4 MB"; empty when unknown.
  public static string Size(long? bytes)
  {
    if (bytes is not { } b || b < 0) return "";
    if (b < 1024) return b + " bytes";
    string[] units = ["KB", "MB", "GB", "TB"];
    double value = b; var unit = -1;
    do { value /= 1024; unit++; } while (value >= 1024 && unit < units.Length - 1);
    return (value >= 10 ? Math.Round(value).ToString("0", CultureInfo.CurrentCulture) : value.ToString("0.#", CultureInfo.CurrentCulture)) + " " + units[unit];
  }

  /// The page's own top bar and column titles show for every place except the Bin, which draws its ONE bar (back /
  /// forward, "Bin" with its info button, search, "Put back all").
  public static bool ShowsListBar(string placeKey) => placeKey != "Bin";

  /// The crumbs: the place, then each folder by name.
  public static IReadOnlyList<string> Crumbs(string place, IReadOnlyList<string> folder) => (string[])[place, .. folder];

  /// One Bin line: what it was, when, from which device by name.
  public static string BinWhen(CloudBinLine line, DateTimeOffset? now = null) => line.Title + " · " + Changed(line.At, now);
}
