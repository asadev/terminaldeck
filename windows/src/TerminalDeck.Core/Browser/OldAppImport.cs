using System.Text.Json;
using System.Text.RegularExpressions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Browser;

// Reads the Electron Terminal Deck (0.15) data folder and brings over what the
// native app has a store for: browser history and the colour theme. It only reads
// the old folder. Cookies, passwords and keys are never read or copied.
public static partial class OldAppImport
{
  public sealed record AppearanceFile(string Theme);
  private sealed record OldVisit(string? ProfileId, string? Url, string? Title, long VisitedAt);
  private sealed record OldHistory(OldVisit[]? Entries);
  private sealed record OldPreferences(string? Theme);
  private sealed record OldState(OldPreferences? Preferences);
  private static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };

  [GeneratedRegex(@"[?&#](access_token|id_token|token|code|key|apikey|api_key|password|secret|sig|signature|auth)=", RegexOptions.IgnoreCase)]
  private static partial Regex SecretQuery();

  public static int History(IStateStore<BrowserState> store, string oldHistoryJson)
  {
    var state = store.Load() ?? throw new IOException("Open the new Terminal Deck once so its browser is set up, then import again.");
    var old = JsonSerializer.Deserialize<OldHistory>(oldHistoryJson, Json)?.Entries ?? [];
    var profiles = state.Profiles.Select(p => p.Id).ToHashSet(StringComparer.Ordinal);
    var seen = state.History.Select(v => v.Url + "|" + v.At.ToUnixTimeMilliseconds()).ToHashSet(StringComparer.Ordinal);
    var added = new List<BrowserVisit>();
    foreach (var visit in old.OrderBy(v => v.VisitedAt))
    {
      if (visit.Url is null || SecretQuery().IsMatch(visit.Url)) continue;
      Uri address; try { address = BrowserModel.Address(visit.Url); } catch (ArgumentException) { continue; }
      if (address.Scheme is not ("http" or "https")) continue;
      var at = DateTimeOffset.FromUnixTimeMilliseconds(visit.VisitedAt);
      if (!seen.Add(address.AbsoluteUri + "|" + visit.VisitedAt)) continue;
      var profile = visit.ProfileId is { } p && profiles.Contains(p) ? p : state.ActiveProfileId;
      var title = new string((visit.Title ?? "").Where(c => !char.IsControl(c)).Take(512).ToArray());
      added.Add(new(Guid.NewGuid().ToString("N"), profile, "imported", address.AbsoluteUri, title, at));
    }
    if (added.Count == 0) return 0;
    store.Save(state with { History = added.Concat(state.History).OrderBy(v => v.At).TakeLast(2000).ToArray() });
    return added.Count;
  }

  // Sets the theme only when the new app has none saved yet.
  public static string? Theme(IStateStore<AppearanceFile> store, string oldStateJson)
  {
    var theme = JsonSerializer.Deserialize<OldState>(oldStateJson, Json)?.Preferences?.Theme;
    if (theme is not ("light" or "dark" or "system") || store.Load() is not null) return null;
    store.Save(new(theme)); return theme;
  }
}
