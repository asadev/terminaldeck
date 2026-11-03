using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Accounts;

public sealed class ConversationLibraryTests
{
  [Theory] [InlineData("claude")] [InlineData("codex")]
  public void DiscoversOnlyExactFolderMetadataAndPreviewsSupportedMessages(string provider)
  {
    using var fixture = new Fixture(provider);
    var first = fixture.Write(fixture.Scope.Cwd, "First recorded question", "Recorded answer");
    fixture.Write(Path.Combine(fixture.Directory, "other"), "Different project", "Other answer");
    var files = new ConversationFiles(fixture.Root); var found = Assert.Single(files.ListLibrary(fixture.Scope));
    Assert.Equal(first.Id, found.Id); Assert.Equal(first.Path, found.Path);
    Assert.Equal(first.Id, files.ResolveLibraryIdentity(fixture.Scope, first.Path));
    var preview = files.PreviewLibrary(fixture.Scope, first.Id);
    Assert.Contains("First recorded question", preview); Assert.Contains("Recorded answer", preview); Assert.DoesNotContain("SECRET_TOOL_INPUT", preview);
  }
  [Fact] public void OutsidePathsAndWrongFolderIdentitiesCannotBeLoaded()
  {
    using var fixture = new Fixture("claude"); var saved = fixture.Write(fixture.Scope.Cwd, "Question", "Answer"); var files = new ConversationFiles(fixture.Root);
    var outside = Path.Combine(fixture.Directory, "outside.jsonl"); File.WriteAllText(outside, "not a provider transcript");
    Assert.Throws<IOException>(() => files.ResolveLibraryIdentity(fixture.Scope, outside));
    Assert.Throws<IOException>(() => files.PreviewLibrary(fixture.Scope with { Cwd = Path.Combine(fixture.Directory, "other") }, saved.Id));
  }
  private sealed class Fixture : IDisposable
  {
    public readonly string Directory = Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "td-conversation-library-" + Guid.NewGuid().ToString("N"));
    public AppDataRoot Root { get; } public SessionDefinition Scope { get; }
    public Fixture(string provider)
    {
      Root = AppDataRoot.Explicit(Directory); Scope = new(Guid.NewGuid().ToString(), provider, Path.Combine(Directory, "project"), "Synthetic", Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N")); System.IO.Directory.CreateDirectory(Scope.Cwd);
    }
    public (string Id, string Path) Write(string folder, string question, string answer)
    {
      var id = Guid.NewGuid().ToString(); var path = Path.Combine(Directory, "accounts", Scope.AccountHome!, Scope.Provider, Scope.Provider == "claude" ? "projects" : "sessions", "synthetic", id + ".jsonl"); System.IO.Directory.CreateDirectory(Path.GetDirectoryName(path)!);
      var metadata = Scope.Provider == "codex" ? (object)new { type = "session_meta", payload = new { id, cwd = folder } } : new { sessionId = id, cwd = folder };
      File.WriteAllText(path, JsonSerializer.Serialize(metadata) + "\n" + JsonSerializer.Serialize(new { message = new { role = "user", content = question } }) + "\n" + JsonSerializer.Serialize(new { message = new { role = "assistant", content = new object[] { new { type = "text", text = answer }, new { type = "tool_use", input = "SECRET_TOOL_INPUT" } } } }) + "\n");
      return (id, path);
    }
    public void Dispose() { if (System.IO.Directory.Exists(Directory)) System.IO.Directory.Delete(Directory, true); }
  }
}
