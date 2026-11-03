using TerminalDeck.Core.Browser;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Browser;

public sealed class OldAppImportTests : IDisposable
{
  private readonly string temp = Path.Combine(Path.GetTempPath(), "td-old-import-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { try { Directory.Delete(temp, true); } catch (IOException) { } }

  [Fact]
  public void BringsHistoryAndThemeOnceAndSkipsUnsafeAddresses()
  {
    var root = AppDataRoot.Explicit(temp);
    var store = new JsonStateStore<BrowserState>(root, "browser-core");
    var existing = new BrowserVisit(Guid.NewGuid().ToString("N"), "default", "t1", "https://example.com/new", "New", DateTimeOffset.FromUnixTimeMilliseconds(3000));
    store.Save(new BrowserState(1, [new("default", "Default")], [], "default", null, 1, [], [], []) { History = [existing] });
    var old = """
    { "version": 1, "entries": [
      { "profileId": "default", "url": "https://github.com/x/y", "title": "Repo", "visitedAt": 2000, "visits": 4 },
      { "profileId": "other", "url": "http://localhost:3005/app", "title": "Local\u0007", "visitedAt": 1000 },
      { "profileId": "default", "url": "https://site.test/cb?code=abc", "title": "Sign-in", "visitedAt": 1500 },
      { "profileId": "default", "url": "file:///C:/x.txt", "title": "File", "visitedAt": 1600 },
      { "profileId": "default", "url": "https://user:pw@site.test/", "title": "Creds", "visitedAt": 1700 } ] }
    """;
    Assert.Equal(2, OldAppImport.History(store, old));
    Assert.Equal(0, OldAppImport.History(store, old));
    var history = store.Load()!.History;
    Assert.Equal(["http://localhost:3005/app", "https://github.com/x/y", "https://example.com/new"], history.Select(v => v.Url));
    Assert.All(history, v => Assert.Equal("default", v.ProfileId));
    Assert.Equal("Local", history[0].Title);

    var appearance = new JsonStateStore<OldAppImport.AppearanceFile>(root, "appearance");
    Assert.Equal("dark", OldAppImport.Theme(appearance, """{ "preferences": { "theme": "dark" } }"""));
    Assert.Null(OldAppImport.Theme(appearance, """{ "preferences": { "theme": "light" } }"""));
    Assert.Equal("dark", appearance.Load()!.Theme);
  }
}
