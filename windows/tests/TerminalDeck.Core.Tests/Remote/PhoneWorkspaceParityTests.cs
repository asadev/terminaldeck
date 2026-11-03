using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Code;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Integration;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class PhoneWorkspaceParityTests : IDisposable
{
  private readonly string root = Path.Combine(Path.GetTempPath(), "td-phone-workspace-" + Guid.NewGuid().ToString("N"));
  public PhoneWorkspaceParityTests() => Directory.CreateDirectory(root);
  public void Dispose() => Directory.Delete(root, true);
  private static JsonElement Message(object value) => JsonSerializer.SerializeToElement(value);
  private readonly ApprovedDevice work = new("phone", "Phone", "ios", PhoneAccess.Work);

  [Fact] public void JunctionOrLinkInAnIntermediateComponentCannotEscapeFolderGrant()
  {
    var shared = Path.Combine(root, "shared"); var outside = Path.Combine(root, "outside");
    Directory.CreateDirectory(shared); Directory.CreateDirectory(outside);
    File.WriteAllText(Path.Combine(outside, "secret.txt"), "not shared");
    Directory.CreateSymbolicLink(Path.Combine(shared, "escape"), outside);
    Assert.Throws<PhoneRefusal>(() => PhoneWorkspacePaths.Require(Path.Combine(shared, "escape", "secret.txt"), [shared], false));
    Assert.Equal(Path.Combine(outside, "secret.txt"), PhoneWorkspacePaths.Require(Path.Combine(shared, "escape", "secret.txt"), [shared], true));
  }

  [Fact] public async Task FilesStayWithinGrantAndReadReportsTruncationAndBinary()
  {
    var host = new PhoneWorkspaceFeatures(_ => [root]);
    File.WriteAllText(Path.Combine(root, "note.txt"), new string('x', 20_000));
    var reply = Assert.Single(await host.HandleAsync("phone", work, "files.read", Message(new { path = Path.Combine(root, "note.txt"), max = 10 }), null, default));
    Assert.Equal("xxxxxxxxxx", reply["text"]!.GetValue<string>()); Assert.True(reply["truncated"]!.GetValue<bool>());
    File.WriteAllBytes(Path.Combine(root, "binary"), [0, 1, 2]);
    reply = Assert.Single(await host.HandleAsync("phone", work, "files.read", Message(new { path = Path.Combine(root, "binary") }), null, default));
    Assert.True(reply["binary"]!.GetValue<bool>()); Assert.Equal("", reply["text"]!.GetValue<string>());
    await Assert.ThrowsAsync<PhoneRefusal>(async () => await host.HandleAsync("phone", work, "files.list", Message(new { path = Path.GetDirectoryName(root) }), null, default));
  }

  [Fact] public async Task FolderPickerCannotNavigateAboveGrantAndDoesNotListFiles()
  {
    Directory.CreateDirectory(Path.Combine(root, "child")); File.WriteAllText(Path.Combine(root, "file.txt"), "hello");
    var host = new PhoneWorkspaceFeatures(_ => [root]);
    var reply = Assert.Single(await host.HandleAsync("phone", work, "folders.browse", Message(new { path = root }), null, default));
    Assert.Null(reply["parent"]); Assert.Equal("child", Assert.Single(reply["entries"]!.AsArray())!["name"]!.GetValue<string>());
  }

  [Fact] public async Task WriteBoundariesAndOwnerReadsAreEnforcedBeforeCallingAnOwnerService()
  {
    var called = 0;
    var host = new PhoneWorkspaceFeatures(_ => [root], (_, _, _, _, _) => { called++; return ValueTask.FromResult(new JsonObject()); });
    foreach (var type in new[] { "git.commit", "git.push", "usage.read", "account.switch", "devices.revoke" })
      await Assert.ThrowsAsync<PhoneRefusal>(async () => await host.HandleAsync("phone", work, type, Message(new { path = root }), null, default));
    Assert.Equal(0, called);
    Assert.True(host.Permits(PhoneAccess.Look, "git.status")); Assert.True(host.Permits(PhoneAccess.Full, "account.switch"));
  }

  [Fact] public void GitStatusUsesPhoneRepoBooleanAndReadableCounts()
  {
    var status = PhoneWorkspaceFeatures.Status(new(new(root, root, new("main"), [], [new("file.cs", GitFileGroup.Unstaged, GitChangeKind.Modified, Insertions: 3, Deletions: 2)], [], []), root));
    Assert.True(status["repo"]!.GetValue<bool>());
    Assert.Equal("modified", status["unstaged"]![0]!["kind"]!.GetValue<string>());
    Assert.Equal(3, status["unstaged"]![0]!["insertions"]!.GetValue<int>());
    Assert.False(PhoneWorkspaceFeatures.Status(new(null, root, GitUnavailableReason.NotARepo, "Not a repository."))["repo"]!.GetValue<bool>());
  }

  [Fact] public void EveryHootEventIncludingFailureHasPhoneRequiredProviderAndStringTurn()
  {
    var now = DateTimeOffset.UtcNow;
    var state = HootState.Empty with { Settings = new("codex", "account", root, new()), Lines = [new(1, "assistant", "message", "Hi", now)], Problem = "Disconnected." };
    using var page = JsonDocument.Parse(W9PhoneApplication.Page(state));
    var events = page.RootElement.GetProperty("events").EnumerateArray().ToArray();
    Assert.Equal(2, events.Length);
    foreach (var e in events) { Assert.Equal("codex", e.GetProperty("provider").GetString()); Assert.Equal(JsonValueKind.String, e.GetProperty("turnId").ValueKind); }
  }
}
