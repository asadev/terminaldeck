using System.Text.Json;
using System.Threading.Channels;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Browser;

public sealed record BrowserProfile(string Id, string Name, string Avatar = "");
public sealed record BrowserTab(string Id, string Window, string Url, string Title, string ProfileId, bool Isolated,
  string? SessionId = null, string? SessionSlot = null, string? AutomationOrigin = null);
public sealed record BrowserSlotCounter(string SessionId, int Next);
public sealed record BrowserVisit(string Id, string ProfileId, string TabId, string Url, string Title, DateTimeOffset At);
public sealed record BrowserState(int Version, BrowserProfile[] Profiles, BrowserTab[] Tabs, string ActiveProfileId,
  string? SelectedTabId, int NextWindow, BrowserSlotCounter[] SessionSlots, string[] PrivateStoresToClean, string[] ProfilesToDelete)
{
  public BrowserVisit[] History { get; init; } = [];
  public string StartUrl { get; init; } = "about:blank";
}
public sealed record BrowserSurfaceOptions(string TabId, string ProfileId, bool Isolated, string? PrivateStoreId, string? AutomationOrigin = null);
public enum BrowserPageAction { Back, Forward, Stop, Zoom, Find, FindStop, Print, DevTools, UserAgent, Inspect, Record, Recording, RecordClear, Screenshot, Reveal, Size, Send, Read, Step, Handover, WorkspaceRead, WorkspaceChange, TakeOver }
public interface IBrowserPage : IBrowserSurface
{
  ValueTask ReloadAsync(bool bypassCache, CancellationToken cancellationToken);
  // Named controls only. Implementations mask secret fields/captures, validate artifact
  // paths and never expose an arbitrary script-evaluation bridge to untrusted pages.
  ValueTask<JsonElement> PerformAsync(BrowserPageAction action, JsonElement arguments, CancellationToken cancellationToken);
}
public interface IBrowserSurfaceFactory
{
  ValueTask<IBrowserPage> CreateAsync(BrowserSurfaceOptions options, CancellationToken cancellationToken);
}
public interface IBrowserProfileStorage
{
  ValueTask EnsureProfileAsync(string id, CancellationToken cancellationToken);
  ValueTask CreatePrivateAsync(string id, CancellationToken cancellationToken);
  ValueTask DeletePrivateAsync(string id, CancellationToken cancellationToken);
  ValueTask DeleteProfileAsync(string id, CancellationToken cancellationToken);
}

// A hidden/background page keeps the same surface. Only explicit close/shutdown
// disposes it; selection, binding and default-profile changes never reload it.
// An explicit current-tab cookie-store switch recreates that page by design.
public sealed partial class BrowserModel : IAsyncDisposable
{
  public const int MaximumRetainedPages = 12;
  public const string DefaultProfileId = "default";
  private sealed record Page(IBrowserPage Surface, string? PrivateStoreId, string? AutomationOrigin = null);
  private readonly IStateStore<BrowserState> store;
  private readonly IBrowserSurfaceFactory factory;
  private readonly IBrowserProfileStorage storage;
  private readonly SemaphoreSlim gate = new(1);
  private readonly Dictionary<string, Page> pages = [];
  private BrowserState state;
  private bool disposed;
  private readonly Channel<BrowserState> changes = Channel.CreateBounded<BrowserState>(new BoundedChannelOptions(1) { FullMode = BoundedChannelFullMode.DropOldest });
  public IAsyncEnumerable<BrowserState> Changes(CancellationToken cancellationToken = default) => changes.Reader.ReadAllAsync(cancellationToken);
  public BrowserModel(IStateStore<BrowserState> store, IBrowserSurfaceFactory factory, IBrowserProfileStorage storage)
  {
    this.store = store; this.factory = factory; this.storage = storage;
    state = store.Load() ?? new(1, [new(DefaultProfileId, "Default")], [], DefaultProfileId, null, 1, [], [], []);
    if (state.Version != 1 || !state.Profiles.Any(p => p.Id == DefaultProfileId) || !state.Profiles.Any(p => p.Id == state.ActiveProfileId) ||
      state.Profiles.Any(p => !ValidProfileId(p.Id)) || state.Profiles.Select(p => p.Id).Distinct().Count() != state.Profiles.Length ||
      state.SelectedTabId is not null && !state.Tabs.Any(t => t.Id == state.SelectedTabId) ||
      state.NextWindow < 1 || state.Tabs.Select(t => t.Window).Distinct().Count() != state.Tabs.Length ||
      state.Tabs.Any(t => !System.Text.RegularExpressions.Regex.IsMatch(t.Window, "^W[1-9][0-9]*$") || (t.SessionId is null) != (t.SessionSlot is null)) ||
      state.SessionSlots.Any(c => c.Next < 1) || state.SessionSlots.Select(c => c.SessionId).Distinct().Count() != state.SessionSlots.Length ||
      state.Tabs.Select(t => t.Id).Distinct().Count() != state.Tabs.Length || state.Tabs.Any(t => !Guid.TryParseExact(t.Id, "N", out _) || !state.Profiles.Any(p => p.Id == t.ProfileId)) ||
      state.PrivateStoresToClean.Any(id => !Guid.TryParseExact(id, "N", out _)) || state.ProfilesToDelete.Any(id => id == DefaultProfileId || !ValidProfileId(id)))
      throw new IOException("The saved browser windows could not be read safely.");
    _ = Address(state.StartUrl);
    if (state.History is null || state.History.Length > 2000 || state.History.Any(v => v is null || !state.Profiles.Any(p => p.Id == v.ProfileId) || !Guid.TryParseExact(v.Id, "N", out _)))
      throw new IOException("The saved browser history could not be read safely.");
    foreach (var visit in state.History) _ = Address(visit.Url);
    foreach (var tab in state.Tabs)
    {
      _ = Address(tab.Url);
      if (tab.AutomationOrigin is { } origin && Address(origin).GetLeftPart(UriPartial.Authority) != origin)
        throw new IOException("The saved browser origin is invalid.");
    }
    // Older versions could save more tabs through MCP. Keep the selected tab
    // and the oldest neighbours without restoring an unbounded set of surfaces.
    if (state.Tabs.Length > MaximumRetainedPages)
    {
      var keep = state.Tabs.Take(MaximumRetainedPages).ToArray();
      if (state.SelectedTabId is { } selected && !keep.Any(t => t.Id == selected)) keep[^1] = state.Tabs.Single(t => t.Id == selected);
      Save(state with { Tabs = keep });
    }
  }
  public BrowserState Read() => Copy(Volatile.Read(ref state));
  public BrowserTab Get(string id) => Read().Tabs.FirstOrDefault(t => t.Id == id) ?? throw new ArgumentException("Choose a browser window from the list.");

  public async ValueTask RestoreAsync(CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      RequireOpen(); await CleanupAsync(cancellationToken);
      foreach (var tab in state.Tabs) await EnsurePageAsync(tab, cancellationToken);
    }
    finally { gate.Release(); }
  }
  public async ValueTask<BrowserTab> OpenAsync(string url, bool isolated = false, string? profileId = null, string? sessionId = null, CancellationToken cancellationToken = default, string? automationOrigin = null)
  {
    var address = Address(url);
    RequireNavigation(automationOrigin, address);
    await gate.WaitAsync(cancellationToken);
    try
    {
      RequireOpen();
      if (state.Tabs.Length >= MaximumRetainedPages) throw new InvalidOperationException("Close a browser tab before adding another. Up to 12 tabs can stay open.");
      var profile = profileId ?? state.ActiveProfileId; RequireProfile(profile);
      var tab = new BrowserTab(Guid.NewGuid().ToString("N"), "W" + state.NextWindow, address.AbsoluteUri, "", profile, isolated, AutomationOrigin: automationOrigin);
      var ordered = state.Tabs.ToList();
      var after = ordered.FindIndex(t => t.Id == state.SelectedTabId);
      ordered.Insert(after < 0 ? ordered.Count : after + 1, tab);
      var next = state with { Tabs = ordered.ToArray(), SelectedTabId = tab.Id, NextWindow = checked(state.NextWindow + 1) };
      if (sessionId is not null) (tab, next) = Bind(next, tab, sessionId);
      var previousSelection = state.SelectedTabId;
      Save(next);
      try { await EnsurePageAsync(tab, cancellationToken); return tab; }
      catch
      {
        // Failed or origin-blocked first navigation must not leave a saved
        // phantom tab that consumes capacity and fails every later restore.
        Save(state with { Tabs = state.Tabs.Where(t => t.Id != tab.Id).ToArray(), SelectedTabId = previousSelection });
        throw;
      }
    }
    finally { gate.Release(); }
  }
  public ValueTask<BrowserTab> OpenPopupAsync(string sourceId, string url, CancellationToken cancellationToken = default)
  {
    var source = Get(sourceId);
    RequireNavigation(source.AutomationOrigin, Address(url));
    return OpenAsync(url, source.Isolated, source.ProfileId, source.SessionId, cancellationToken, source.AutomationOrigin);
  }
  private static void RequireNavigation(string? origin, Uri address)
  {
    if (origin is not null && (address.Scheme is not ("http" or "https") || address.GetLeftPart(UriPartial.Authority) != origin))
      throw new InvalidOperationException("The page tried to leave the origin granted to its driver.");
  }
  public async ValueTask SelectAsync(string id, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try { RequireOpen(); var tab = Get(id); Save(state with { SelectedTabId = id }); await EnsurePageAsync(tab, cancellationToken); }
    finally { gate.Release(); }
  }
  public async ValueTask MoveAsync(string id, int index, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      RequireOpen(); var tab = Get(id); if (index < 0 || index >= state.Tabs.Length) throw new ArgumentOutOfRangeException(nameof(index));
      var tabs = state.Tabs.Where(t => t.Id != id).ToList(); tabs.Insert(index, tab); Save(state with { Tabs = tabs.ToArray() });
    }
    finally { gate.Release(); }
  }
  public async ValueTask AttachAsync(string id, string? sessionId, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      RequireOpen(); var tab = Get(id);
      if (tab.SessionId == sessionId) return;
      if (sessionId is null) Save(state with { Tabs = state.Tabs.Select(t => t.Id == id ? t with { SessionId = null, SessionSlot = null } : t).ToArray() });
      else { var (_, next) = Bind(state, tab, sessionId); Save(next); }
    }
    finally { gate.Release(); }
  }
  public async ValueTask NavigateAsync(string id, string url, CancellationToken cancellationToken = default)
  {
    var address = Address(url);
    await gate.WaitAsync(cancellationToken);
    try
    {
      RequireOpen(); var tab = Get(id); RequireNavigation(tab.AutomationOrigin, address); var page = await EnsurePageAsync(tab, cancellationToken);
      await page.Surface.NavigateAsync(address, cancellationToken);
      Save(state with { Tabs = state.Tabs.Select(t => t.Id == id ? t with { Url = address.AbsoluteUri } : t).ToArray() });
    }
    finally { gate.Release(); }
  }
  // WebView navigation/title callbacks update metadata, never call back into navigation.
  public async ValueTask ObserveNavigationAsync(string id, string url, string title, CancellationToken cancellationToken = default)
  {
    var address = Address(url);
    await gate.WaitAsync(cancellationToken);
    try
    {
      RequireOpen(); var tab = Get(id);
      var cleanTitle = new string(title.Where(c => !char.IsControl(c)).Take(512).ToArray());
      var history = state.History;
      if (!tab.Isolated && address.Scheme is "http" or "https" && address.Host != "start.deck.invalid")
      {
        var last = history.LastOrDefault(v => v.TabId == id);
        history = last?.Url == address.AbsoluteUri && tab.Url == address.AbsoluteUri
          ? history.Select(v => v.Id == last.Id ? v with { Title = cleanTitle } : v).ToArray()
          : history.Append(new(Guid.NewGuid().ToString("N"), tab.ProfileId, id, address.AbsoluteUri, cleanTitle, DateTimeOffset.UtcNow)).TakeLast(2000).ToArray();
      }
      Save(state with { Tabs = state.Tabs.Select(t => t.Id == id ? t with { Url = address.AbsoluteUri, Title = cleanTitle } : t).ToArray(), History = history });
    }
    finally { gate.Release(); }
  }
  public async ValueTask ReloadAsync(string id, bool bypassCache = false, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try { RequireOpen(); var page = await EnsurePageAsync(Get(id), cancellationToken); await page.Surface.ReloadAsync(bypassCache, cancellationToken); }
    finally { gate.Release(); }
  }
  public async ValueTask<JsonElement> PerformAsync(string id, BrowserPageAction action, JsonElement arguments, CancellationToken cancellationToken = default)
  {
    if (!Enum.IsDefined(action)) throw new ArgumentException("Choose an available browser action.");
    await gate.WaitAsync(cancellationToken);
    try
    {
      RequireOpen(); var tab = Get(id);
      if (action == BrowserPageAction.Step)
      {
        var origin = Address(tab.Url).GetLeftPart(UriPartial.Authority);
        tab = tab with { AutomationOrigin = origin };
        Save(state with { Tabs = state.Tabs.Select(t => t.Id == id ? tab : t).ToArray() });
      }
      var page = await EnsurePageAsync(tab, cancellationToken);
      return await page.Surface.PerformAsync(action, arguments, cancellationToken);
    }
    finally { gate.Release(); }
  }
  public async ValueTask CloseAsync(string id, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      RequireOpen(); _ = Get(id); var index = Array.FindIndex(state.Tabs, t => t.Id == id); var tabs = state.Tabs.Where(t => t.Id != id).ToArray();
      var selected = state.SelectedTabId != id ? state.SelectedTabId : tabs.Length == 0 ? null : tabs[Math.Min(index, tabs.Length - 1)].Id;
      Save(state with { Tabs = tabs, SelectedTabId = selected });
      await ReleasePageAsync(id, cancellationToken); await CleanupAsync(cancellationToken);
    }
    finally { gate.Release(); }
  }
  public async ValueTask<BrowserProfile> CreateProfileAsync(string name, CancellationToken cancellationToken = default)
  {
    ValidateName(name);
    await gate.WaitAsync(cancellationToken);
    try
    {
      RequireOpen(); var profile = new BrowserProfile(Guid.NewGuid().ToString("N"), name.Trim());
      Save(state with { Profiles = [.. state.Profiles, profile] }); return profile;
    }
    finally { gate.Release(); }
  }
  public async ValueTask UpdateProfileAsync(string id, string? name = null, string? avatar = null, CancellationToken cancellationToken = default)
  {
    if (name is not null) ValidateName(name);
    if (avatar is not null && (System.Globalization.StringInfo.ParseCombiningCharacters(avatar).Length > 1 || avatar.Any(char.IsControl))) throw new ArgumentException("Choose one character for the profile badge.");
    await gate.WaitAsync(cancellationToken);
    try
    {
      RequireOpen(); RequireProfile(id);
      Save(state with { Profiles = state.Profiles.Select(p => p.Id == id ? p with { Name = name?.Trim() ?? p.Name, Avatar = avatar ?? p.Avatar } : p).ToArray() });
    }
    finally { gate.Release(); }
  }
  public async ValueTask ActivateProfileAsync(string id, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try { RequireOpen(); RequireProfile(id); Save(state with { ActiveProfileId = id }); }
    finally { gate.Release(); }
  }
  public async ValueTask DeleteProfileAsync(string id, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try
    {
      RequireOpen(); RequireProfile(id);
      if (id == DefaultProfileId) throw new InvalidOperationException("The default browser profile cannot be deleted.");
      if (state.Tabs.Any(t => t.ProfileId == id)) throw new InvalidOperationException("Close the browser windows using this profile before deleting it.");
      Save(state with { ProfilesToDelete = state.ProfilesToDelete.Append(id).Distinct().ToArray(), ActiveProfileId = state.ActiveProfileId == id ? DefaultProfileId : state.ActiveProfileId });
      await CleanupAsync(cancellationToken);
    }
    finally { gate.Release(); }
  }
  public async ValueTask RetryCleanupAsync(CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try { RequireOpen(); await CleanupAsync(cancellationToken); }
    finally { gate.Release(); }
  }
  private async ValueTask<Page> EnsurePageAsync(BrowserTab tab, CancellationToken ct)
  {
    if (pages.TryGetValue(tab.Id, out var existing)) return existing;
    await CleanupAsync(ct);
    string? privateId = null;
    if (tab.Isolated)
    {
      privateId = Guid.NewGuid().ToString("N"); Save(state with { PrivateStoresToClean = [.. state.PrivateStoresToClean, privateId] });
      await storage.CreatePrivateAsync(privateId, ct);
    }
    else await storage.EnsureProfileAsync(tab.ProfileId, ct);
    IBrowserPage? surface = null;
    try
    {
      surface = await factory.CreateAsync(new(tab.Id, tab.ProfileId, tab.Isolated, privateId, tab.AutomationOrigin), ct);
      if (surface.TabId != tab.Id) throw new IOException("The browser surface belongs to another window.");
      await surface.NavigateAsync(Address(tab.Url), ct);
      var page = new Page(surface, privateId); pages.Add(tab.Id, page); return page;
    }
    catch
    {
      if (surface is not null) await surface.DisposeAsync();
      // An unfinished private store stays on the durable cleanup list.
      throw;
    }
  }
  private async ValueTask ReleasePageAsync(string id, CancellationToken ct)
  {
    if (!pages.Remove(id, out var page)) return;
    await page.Surface.DisposeAsync();
    if (page.PrivateStoreId is { } privateId)
    {
      await storage.DeletePrivateAsync(privateId, ct);
      Save(state with { PrivateStoresToClean = state.PrivateStoresToClean.Where(s => s != privateId).ToArray() });
    }
  }
  private async ValueTask CleanupAsync(CancellationToken ct)
  {
    var live = pages.Values.Select(p => p.PrivateStoreId).Where(p => p is not null).ToHashSet();
    foreach (var id in state.PrivateStoresToClean.Where(id => !live.Contains(id)).ToArray())
    {
      await storage.DeletePrivateAsync(id, ct);
      Save(state with { PrivateStoresToClean = state.PrivateStoresToClean.Where(s => s != id).ToArray() });
    }
    foreach (var id in state.ProfilesToDelete.ToArray())
    {
      if (state.Tabs.Any(t => t.ProfileId == id)) throw new IOException("A browser profile waiting for deletion still has an open window.");
      await storage.DeleteProfileAsync(id, ct);
      Save(state with { Profiles = state.Profiles.Where(p => p.Id != id).ToArray(), ProfilesToDelete = state.ProfilesToDelete.Where(p => p != id).ToArray(), History = state.History.Where(v => v.ProfileId != id).ToArray() });
    }
  }
  private static (BrowserTab, BrowserState) Bind(BrowserState s, BrowserTab tab, string sessionId)
  {
    if (string.IsNullOrWhiteSpace(sessionId) || sessionId.Length > 128 || sessionId.Any(char.IsControl)) throw new ArgumentException("Choose a session for this browser window.");
    var counter = s.SessionSlots.FirstOrDefault(c => c.SessionId == sessionId)?.Next ?? 1;
    var bound = tab with { SessionId = sessionId, SessionSlot = "B" + counter };
    return (bound, s with { Tabs = s.Tabs.Select(t => t.Id == tab.Id ? bound : t).ToArray(), SessionSlots = s.SessionSlots.Where(c => c.SessionId != sessionId).Append(new(sessionId, checked(counter + 1))).ToArray() });
  }
  private void RequireProfile(string id)
  {
    if (!state.Profiles.Any(p => p.Id == id) || state.ProfilesToDelete.Contains(id)) throw new ArgumentException("Choose an available browser profile.");
  }
  private void RequireOpen() { ObjectDisposedException.ThrowIf(disposed, this); }
  private static void ValidateName(string name) { if (string.IsNullOrWhiteSpace(name) || name.Length > 40 || name.Any(char.IsControl)) throw new ArgumentException("Choose a profile name of up to 40 characters."); }
  private static bool ValidProfileId(string id) => id == DefaultProfileId || Guid.TryParseExact(id, "N", out _);
  public static Uri Address(string url) => Uri.TryCreate(url, UriKind.Absolute, out var address) && (address.Scheme is "https" or "http" || url == "about:blank") && address.UserInfo.Length == 0
    ? address : throw new ArgumentException("Choose an HTTP or HTTPS page address.");
  private void Save(BrowserState next)
  {
    store.Save(Copy(next)); Volatile.Write(ref state, next);
    changes.Writer.TryWrite(Copy(next));
  }
  private static BrowserState Copy(BrowserState s) => s with { Profiles = [.. s.Profiles], Tabs = [.. s.Tabs], SessionSlots = [.. s.SessionSlots], PrivateStoresToClean = [.. s.PrivateStoresToClean], ProfilesToDelete = [.. s.ProfilesToDelete], History = [.. s.History] };
  public async ValueTask DisposeAsync()
  {
    await gate.WaitAsync();
    try
    {
      if (disposed) return; disposed = true; changes.Writer.TryComplete(); var failed = false;
      foreach (var id in pages.Keys.ToArray())
      {
        try { await ReleasePageAsync(id, CancellationToken.None); }
        catch { failed = true; }
      }
      try { await CleanupAsync(CancellationToken.None); } catch { failed = true; }
      if (failed) throw new IOException("Some private browser data is waiting for cleanup. It will be retried at the next start.");
    }
    finally { gate.Release(); }
  }
}
