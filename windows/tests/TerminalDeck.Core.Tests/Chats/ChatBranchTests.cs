using System.Reflection;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Code;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Chats;

public sealed class ChatBranchTests
{
  [Fact] public async Task CodexForkUsesProviderCopyAndPreservesSourceAccountSettingsAndParent()
  {
    using var fixture = new Fixture("codex"); var result = await fixture.Service.CreateAsync(fixture.Parent.Definition.Id, true, false, null, "Copied conversation", default);
    Assert.True(result.Forked); Assert.True(result.Confirmed); Assert.Equal(1, fixture.Forks); Assert.NotEqual(fixture.Parent.ConversationId, result.Chat.ConversationId);
    Assert.Equal(fixture.Parent.Definition.AccountId, result.Chat.Definition.AccountId); Assert.Equal(fixture.Parent.Definition.Options, result.Chat.Definition.Options); Assert.Equal(fixture.Parent.Definition.Instructions, result.Chat.Definition.Instructions);
    Assert.Equal("parent-conversation", fixture.Backend.Parent.ConversationId); Assert.Empty(fixture.Runner.Calls);
  }
  [Fact] public async Task ClaudeUsesRealLaunchForkAndRefusesCrossFolderConversationFork()
  {
    using var fixture = new Fixture("claude"); var result = await fixture.Service.CreateAsync(fixture.Parent.Definition.Id, true, false, null, null, default);
    Assert.True(result.Chat.Definition.ForkSession); Assert.False(result.Confirmed); Assert.Equal(fixture.Parent.ConversationId, result.Chat.ConversationId);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await fixture.Service.CreateAsync(fixture.Parent.Definition.Id, true, true, null, null, default)); Assert.Empty(fixture.Runner.Calls);
  }
  [Fact] public async Task WorktreeCleanupKeepsDirtyActiveAndUnrelatedWorktreesAndNeverDeletesBranch()
  {
    using var fixture = new Fixture("codex"); var result = await fixture.Service.CreateAsync(fixture.Parent.Definition.Id, false, true, null, null, default); var folder = result.Chat.Definition.Cwd;
    fixture.Runner.Dirty = true; await Assert.ThrowsAsync<InvalidOperationException>(async () => await fixture.Service.RemoveAsync(fixture.Parent.Definition.Id, result.Chat.Definition.Id, default)); Assert.True(Directory.Exists(folder));
    fixture.Runner.Dirty = false; fixture.Live.Add(folder); await Assert.ThrowsAsync<InvalidOperationException>(async () => await fixture.Service.RemoveAsync(fixture.Parent.Definition.Id, result.Chat.Definition.Id, default)); fixture.Live.Clear();
    await Assert.ThrowsAsync<UnauthorizedAccessException>(async () => await fixture.Service.RemoveAsync("unrelated-chat", result.Chat.Definition.Id, default));
    await fixture.Service.RemoveAsync(fixture.Parent.Definition.Id, result.Chat.Definition.Id, default); Assert.False(Directory.Exists(folder));
    Assert.DoesNotContain(fixture.Runner.Calls, c => c.Contains("--force") || c.Contains("-D") || c.Contains("--delete"));
  }
  [Fact] public async Task RevocationBeforeCreateDoesNotOpenAForkedChat()
  {
    using var fixture = new Fixture("codex"); var checks = 0;
    await Assert.ThrowsAsync<UnauthorizedAccessException>(async () => await fixture.Service.CreateAsync(fixture.Parent.Definition.Id, true, false, null, null, default, _ => ++checks == 1 ? ValueTask.CompletedTask : ValueTask.FromException(new UnauthorizedAccessException("Revoked"))));
    Assert.Empty(fixture.Backend.Created); Assert.Equal("parent-conversation", fixture.Backend.Parent.ConversationId);
  }
  [Fact] public void EarlierTurnRequiresARecordedFinishedProviderIdentity()
  {
    using var fixture = new Fixture("codex"); var parent = fixture.Parent with { Events = [new(1, "providerTurnComplete", "provider-turn", ClientId: "app-turn")] };
    Assert.Equal("provider-turn", ChatBranchService.ProviderTurn(parent, "app-turn")); Assert.Throws<InvalidOperationException>(() => ChatBranchService.ProviderTurn(parent, "unknown-turn"));
  }
  private sealed class Fixture : IDisposable
  {
    public string DirectoryPath { get; } = Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "td-branch-test-" + Guid.NewGuid().ToString("N"));
    public BranchProxy Backend { get; } public ChatRecord Parent => Backend.Parent; public Runner Runner { get; } public ChatBranchService Service { get; } public List<string> Live { get; } = []; public int Forks;
    public Fixture(string provider)
    {
      Directory.CreateDirectory(DirectoryPath); var sessions = DispatchProxy.Create<IChatSessions, BranchProxy>(); Backend = (BranchProxy)sessions;
      Backend.Parent = new(1, new(Guid.NewGuid().ToString(), provider, DirectoryPath, "Synthetic parent", Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N"), new("model", "high"), "Recorded instructions"), Guid.NewGuid().ToString("N"), [], [], ConversationId: "parent-conversation");
      Runner = new(DirectoryPath); Service = new(AppDataRoot.Explicit(DirectoryPath), new Store(), () => sessions, (_, _, _) => { Forks++; return ValueTask.FromResult("separate-provider-conversation"); }, () => Live, Runner);
    }
    public void Dispose() { if (Directory.Exists(DirectoryPath)) Directory.Delete(DirectoryPath, true); }
  }
  private sealed class Store : IStateStore<ChatWorktreeState> { private ChatWorktreeState state = new([]); public ChatWorktreeState Load() => state; public void Save(ChatWorktreeState value) => state = value; }
  public sealed class Runner(string root) : ICodeProcessRunner
  {
    public bool Dirty; public List<string[]> Calls { get; } = [];
    public Task<CodeProcessResult> RunAsync(string executable, IReadOnlyList<string> arguments, string cwd, TimeSpan timeout, CancellationToken ct, string? input = null)
    {
      Calls.Add(arguments.ToArray()); string output = "";
      if (arguments.Contains("--show-toplevel")) output = root;
      else if (arguments.Contains("--git-common-dir")) output = Path.Combine(root, ".git");
      else if (arguments.Contains("--verify")) output = "commit";
      else if (arguments.Contains("status")) output = Dirty ? "?? uncommitted.txt" : "";
      else if (arguments.Contains("add")) Directory.CreateDirectory(arguments[^2]);
      else if (arguments.Contains("remove")) { Assert.StartsWith(root + Path.DirectorySeparatorChar, Path.GetFullPath(arguments[^1])); Directory.Delete(arguments[^1], true); }
      return Task.FromResult(new CodeProcessResult(0, output, ""));
    }
  }
}
public class BranchProxy : DispatchProxy
{
  public ChatRecord Parent = null!; public List<ChatRecord> Created { get; } = [];
  protected override object? Invoke(MethodInfo? method, object?[]? arguments)
  {
    if (method?.Name == nameof(IChatSessions.ReadAsync)) return ValueTask.FromResult(Parent);
    if (method?.Name == nameof(IChatSessions.CreateAsync) && arguments![0] is ChatDefinition definition)
    {
      definition.Validate(); var result = new ChatRecord(1, definition, Guid.NewGuid().ToString("N"), [], [], ConversationId: arguments[1] as string); Created.Add(result); return ValueTask.FromResult(result);
    }
    throw new NotSupportedException("Unexpected synthetic branch operation.");
  }
}
