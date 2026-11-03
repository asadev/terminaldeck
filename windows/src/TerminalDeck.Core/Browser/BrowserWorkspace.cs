namespace TerminalDeck.Core.Browser;

public sealed partial class BrowserModel
{
  public async ValueTask TakeHumanControlAsync(string id, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      RequireOpen(); var tab = Get(id);
      ClearDriver(id);
      if (tab.AutomationOrigin is null) return;
      Save(state with { Tabs = state.Tabs.Select(t => t.Id == id ? t with { AutomationOrigin = null } : t).ToArray() });
      if (pages.TryGetValue(id, out var page)) await page.Surface.PerformAsync(BrowserPageAction.TakeOver, System.Text.Json.JsonSerializer.SerializeToElement(new { }), cancellationToken);
    }
    finally { gate.Release(); }
  }
  public BrowserVisit[] History(string profileId, string query = "")
  {
    RequireProfile(profileId);
    return Read().History.Where(v => v.ProfileId == profileId &&
      (v.Url.Contains(query, StringComparison.OrdinalIgnoreCase) || v.Title.Contains(query, StringComparison.OrdinalIgnoreCase)))
      .OrderByDescending(v => v.At).ToArray();
  }
  public async ValueTask ForgetHistoryAsync(string profileId, string? visitId = null, string? query = null, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      RequireOpen(); RequireProfile(profileId);
      var ids = History(profileId, query ?? "").Where(v => visitId is null || v.Id == visitId).Select(v => v.Id).ToHashSet();
      Save(state with { History = state.History.Where(v => !ids.Contains(v.Id)).ToArray() });
    }
    finally { gate.Release(); }
  }
  public async ValueTask SetStartUrlAsync(string url, CancellationToken cancellationToken = default)
  {
    var address = Address(url);
    await gate.WaitAsync(cancellationToken);
    try { RequireOpen(); Save(state with { StartUrl = address.AbsoluteUri }); }
    finally { gate.Release(); }
  }
  // A cookie-store switch necessarily recreates the WebView. Keep the logical
  // window, its position and session slot, and restore its old store on failure.
  public async ValueTask ChangeStoreAsync(string id, string profileId, bool isolated, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      RequireOpen(); RequireProfile(profileId); var previous = Get(id);
      if (previous.ProfileId == profileId && previous.Isolated == isolated) return;
      var next = previous with { ProfileId = profileId, Isolated = isolated };
      Save(state with { Tabs = state.Tabs.Select(t => t.Id == id ? next : t).ToArray() });
      try
      {
        await ReleasePageAsync(id, cancellationToken);
        await EnsurePageAsync(next, cancellationToken);
      }
      catch
      {
        Save(state with { Tabs = state.Tabs.Select(t => t.Id == id ? previous : t).ToArray() });
        await EnsurePageAsync(previous, CancellationToken.None);
        throw;
      }
    }
    finally { gate.Release(); }
  }
}

public sealed record BrowserViewport(string Name, int Width, int Height)
{
  public static IReadOnlyList<BrowserViewport> Presets { get; } = [
    new("Fill the window", 0, 0), new("Phone, small", 375, 667), new("Phone", 390, 844),
    new("Tablet", 768, 1024), new("Tablet, large", 1024, 1366),
    new("Laptop", 1280, 800), new("Desktop", 1440, 900)
  ];
  public BrowserViewport Landscape() => this with { Width = Height, Height = Width };
  public static BrowserViewport Custom(int width, int height) => width is >= 240 and <= 3840 && height is >= 240 and <= 3840
    ? new("Custom", width, height) : throw new ArgumentException("Choose a width and height between 240 and 3840.");
}
