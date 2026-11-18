namespace TerminalDeck.Core.Browser;

public sealed record BrowserBookmark(string Id, string ProfileId, string Url, string Title, string? Icon, DateTimeOffset CreatedAt);

public sealed partial class BrowserModel
{
  private static void ValidateBookmarks(BrowserState state)
  {
    if (state.Bookmarks is null || state.BookmarkBarProfiles is null || state.Bookmarks.Length > 10000 ||
      state.Bookmarks.Any(b => b is null || !Guid.TryParseExact(b.Id, "N", out _) || !state.Profiles.Any(p => p.Id == b.ProfileId) || b.Title is null || b.Title.Length > 512 || b.Icon is not null && (!Uri.TryCreate(b.Icon, UriKind.Absolute, out var icon) || icon.Scheme is not ("http" or "https"))) ||
      state.Bookmarks.Select(b => b.Id).Distinct().Count() != state.Bookmarks.Length || state.BookmarkBarProfiles.Any(id => !state.Profiles.Any(p => p.Id == id)))
      throw new IOException("The saved bookmarks could not be read safely.");
    foreach (var bookmark in state.Bookmarks) _ = BookmarkAddress(bookmark.Url);
  }
  private static Uri BookmarkAddress(string url)
  {
    var address = Address(url);
    if (address.Scheme is not ("http" or "https") || address.Host == "start.deck.invalid") throw new ArgumentException("Open a website before saving a bookmark.");
    return address;
  }
  public BrowserBookmark[] Bookmarks(string profileId)
  { RequireProfile(profileId); return Read().Bookmarks.Where(b => b.ProfileId == profileId).OrderBy(b => b.CreatedAt).ToArray(); }
  public bool ShowsBookmarkBar(string profileId) => Read().BookmarkBarProfiles.Contains(profileId);
  public async ValueTask<BrowserBookmark> AddBookmarkAsync(string profileId, string url, string title, string? icon = null, CancellationToken cancellationToken = default)
  {
    var address = BookmarkAddress(url).AbsoluteUri;
    if (title.Length > 512 || title.Any(char.IsControl)) title = new string(title.Where(c => !char.IsControl(c)).Take(512).ToArray());
    if (!Uri.TryCreate(icon, UriKind.Absolute, out var iconAddress) || iconAddress.Scheme is not ("http" or "https")) icon = null;
    await gate.WaitAsync(cancellationToken);
    try
    {
      RequireOpen(); RequireProfile(profileId);
      if (state.Bookmarks.FirstOrDefault(b => b.ProfileId == profileId && b.Url == address) is { } existing) return existing;
      if (state.Bookmarks.Length >= 10000) throw new InvalidOperationException("Remove a bookmark before saving another.");
      var bookmark = new BrowserBookmark(Guid.NewGuid().ToString("N"), profileId, address, string.IsNullOrWhiteSpace(title) ? new Uri(address).Host : title.Trim(), icon, DateTimeOffset.UtcNow);
      Save(state with { Bookmarks = [.. state.Bookmarks, bookmark] }); return bookmark;
    }
    finally { gate.Release(); }
  }
  public async ValueTask RemoveBookmarkAsync(string profileId, string id, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try { RequireOpen(); RequireProfile(profileId); Save(state with { Bookmarks = state.Bookmarks.Where(b => b.ProfileId != profileId || b.Id != id).ToArray() }); }
    finally { gate.Release(); }
  }
  public async ValueTask ShowBookmarkBarAsync(string profileId, bool show, CancellationToken cancellationToken = default)
  {
    await gate.WaitAsync(cancellationToken);
    try { RequireOpen(); RequireProfile(profileId); Save(state with { BookmarkBarProfiles = state.BookmarkBarProfiles.Where(id => id != profileId).Concat(show ? [profileId] : Array.Empty<string>()).ToArray() }); }
    finally { gate.Release(); }
  }
}
