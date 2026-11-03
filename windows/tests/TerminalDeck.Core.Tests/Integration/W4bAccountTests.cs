using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Integration;

public sealed class W4bAccountTests : IDisposable
{
  private readonly AppDataRoot root = AppDataRoot.Explicit(Path.Combine(RealTemporaryDirectory(), "td-w4b-" + Guid.NewGuid().ToString("N")));
  // /var is a system link on macOS; use its real target so link-refusal tests
  // exercise transcript links rather than rejecting the fixture's parent.
  private static string RealTemporaryDirectory() => OperatingSystem.IsMacOS() && Path.GetTempPath().StartsWith("/var/", StringComparison.Ordinal) ? "/private" + Path.GetTempPath() : Path.GetTempPath();
  public W4bAccountTests() => Directory.CreateDirectory(root.DirectoryPath);
  private SessionDefinition Definition(string provider = "codex") => new(Guid.NewGuid().ToString(), provider, root.DirectoryPath, "Conversation", Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString("N"), Guid.NewGuid().ToString());
  [Fact]
  public async Task SwitchKeepsSessionReplayAndDoesNotRepeatAnAcknowledgedTransaction()
  {
    var store = new Store<SessionLedger>(); var processes = new Processes(); var keeper = new SessionKeeper(store, processes);
    var source = Definition(); var row = await keeper.CreateAsync(source); await keeper.AppendOutputAsync(source.Id, "previous output");
    var destination = source with { AccountId = Guid.NewGuid().ToString("N"), AccountHome = Guid.NewGuid().ToString("N") }; var transaction = Guid.NewGuid().ToString("N");
    var changed = await keeper.SwitchAccountAsync(destination, 0, transaction);
    Assert.Equal(source.Id, changed.Definition.Id); Assert.Equal(source.ConversationId, changed.Definition.ConversationId);
    Assert.Equal(1, changed.AccountRevision); Assert.Equal("previous output", changed.Replay); Assert.True(changed.Resume);
    Assert.Equal(2, processes.Launches); Assert.Single(processes.Stopped);
    Assert.Equal(changed, await keeper.SwitchAccountAsync(destination, 0, transaction)); Assert.Equal(2, processes.Launches);
    await keeper.RestoreWorkerReplayAsync(source.Id, changed.CreationKey, "new output", false, null);
    Assert.Equal("previous outputnew output", keeper.Get(source.Id).Replay);
    await keeper.AppendWorkerOutputAsync(source.Id, row.CreationKey, "stale data"); Assert.DoesNotContain("stale", keeper.Get(source.Id).Replay);
  }
  [Fact]
  public async Task CrashWhileRetiringOldLeaseRecoversTheSamePendingIntent()
  {
    var store = new Store<SessionLedger>(); var processes = new Processes { FailQuit = true }; var keeper = new SessionKeeper(store, processes);
    var original = Definition(); await keeper.CreateAsync(original); var destination = original with { AccountId = Guid.NewGuid().ToString("N") };
    var transaction = Guid.NewGuid().ToString("N");
    await Assert.ThrowsAsync<IOException>(() => keeper.SwitchAccountAsync(destination, 0, transaction).AsTask());
    Assert.Equal(original, keeper.Get(original.Id).Definition); Assert.Equal(destination, keeper.Get(original.Id).PendingAccount);
    processes.FailQuit = false;
    var restarted = new SessionKeeper(store, processes); await restarted.RecoverAsync();
    Assert.Equal(destination, restarted.Get(original.Id).Definition); Assert.Equal(transaction, restarted.Get(original.Id).CreationKey); Assert.Null(restarted.Get(original.Id).PendingAccount);
    Assert.Equal(2, processes.Launches);
  }
  [Fact]
  public async Task RestartedSessionFollowsItsAccountsCurrentLoginFolder()
  {
    var store = new Store<SessionLedger>(); var keeper = new SessionKeeper(store, new Processes());
    var original = Definition("claude"); await keeper.CreateAsync(original);
    var current = Guid.NewGuid().ToString("N");
    // The worker died (keeper/app restart); signing in again had moved the account's login.
    var restarted = new SessionKeeper(store, new Processes()) { CurrentLogin = d => d.AccountId == original.AccountId ? current : null };
    await restarted.RecoverAsync();
    var row = restarted.Get(original.Id);
    Assert.Equal(current, row.Definition.AccountHome); Assert.Equal(original.ConversationId, row.Definition.ConversationId); Assert.Equal(SessionState.Running, row.State);
    var shell = new SessionKeeper(new Store<SessionLedger>(), new Processes()) { CurrentLogin = _ => current };
    var plain = Definition("claude") with { ConversationId = null }; await shell.CreateAsync(plain);
    Assert.Equal(plain.AccountHome, shell.Get(plain.Id).Definition.AccountHome);
  }
  [Fact]
  public async Task UnknownLeaseAndStaleRevisionCannotLaunchAnotherProcess()
  {
    var processes = new Processes(); var keeper = new SessionKeeper(new Store<SessionLedger>(), processes); var original = Definition(); await keeper.CreateAsync(original);
    var destination = original with { AccountId = Guid.NewGuid().ToString("N") };
    await Assert.ThrowsAsync<InvalidOperationException>(() => keeper.SwitchAccountAsync(destination, 5, Guid.NewGuid().ToString("N")).AsTask());
    processes.Unknown = true;
    await Assert.ThrowsAsync<IOException>(() => keeper.SwitchAccountAsync(destination, 0, Guid.NewGuid().ToString("N")).AsTask());
    Assert.Equal(original, keeper.Get(original.Id).Definition); Assert.Equal(1, processes.Launches); Assert.Empty(processes.Stopped);
  }
  [Fact]
  public async Task FailedNewLaunchCanReopenOriginalConversation()
  {
    var processes = new Processes(); var keeper = new SessionKeeper(new Store<SessionLedger>(), processes); var original = Definition(); await keeper.CreateAsync(original);
    var destination = original with { AccountId = Guid.NewGuid().ToString("N") }; var transaction = Guid.NewGuid().ToString("N");
    processes.FailLaunch = true; await Assert.ThrowsAsync<IOException>(() => keeper.SwitchAccountAsync(destination, 0, transaction).AsTask());
    processes.FailLaunch = false; var restored = await keeper.RollbackAccountAsync(original, transaction);
    Assert.Equal(original, restored.Definition); Assert.Equal(SessionState.Running, restored.State); Assert.True(restored.Resume);
  }
  [Theory]
  [InlineData("claude")]
  [InlineData("codex")]
  public void TransferCopiesOnlyTheSelectedTranscriptAndPreservesOriginal(string provider)
  {
    var source = Definition(provider); var path = Transcript(source); var original = File.ReadAllBytes(path);
    File.WriteAllText(Path.Combine(Home(source), "auth.json"), "private fixture"); File.WriteAllText(Path.Combine(Home(source), "settings.json"), "private config fixture");
    var destination = source with { AccountId = Guid.NewGuid().ToString("N"), AccountHome = Guid.NewGuid().ToString("N") }; var files = new ConversationFiles(root);
    files.Validate(source, destination); files.Copy(source, destination); files.Copy(source, destination);
    Assert.Equal(original, File.ReadAllBytes(path)); Assert.Equal(original, File.ReadAllBytes(Path.Combine(Home(destination), Path.GetRelativePath(Home(source), path))));
    Assert.False(File.Exists(Path.Combine(Home(destination), "auth.json"))); Assert.False(File.Exists(Path.Combine(Home(destination), "settings.json")));
  }
  [Fact]
  public void DivergentDestinationAndAmbiguousConversationKeepFilesUntouched()
  {
    var source = Definition(); var path = Transcript(source); var files = new ConversationFiles(root);
    var destination = source with { AccountHome = Guid.NewGuid().ToString("N") }; var target = Path.Combine(Home(destination), Path.GetRelativePath(Home(source), path));
    Directory.CreateDirectory(Path.GetDirectoryName(target)!); File.WriteAllText(target, "different conversation");
    Assert.Throws<IOException>(() => files.Copy(source, destination)); Assert.Equal("different conversation", File.ReadAllText(target));
    var other = source with { ConversationId = Guid.NewGuid().ToString() }; Transcript(other);
    Assert.Throws<IOException>(() => files.FindConversation(new(source with { ConversationId = null }, "test", SessionState.Running, CreatedAt: 1)));
  }
  [Fact]
  public async Task LaunchPlannerSupportsBriefAndExactResumeWithoutChangingAccount()
  {
    var source = Definition(); Transcript(source);
    var account = new AccountProfile(source.AccountId!, "codex", "Fixture", "fixture@example.invalid", AccountAuthentication.Subscription, true, source.AccountHome!);
    var planner = new IntegratedSessionLaunch(root);
    var resumed = await planner.PrepareAsync(JsonSerializer.SerializeToElement(new { cwd = root.DirectoryPath, provider = "codex", resume = true }), account, default);
    Assert.Equal(source.ConversationId, resumed.ConversationId); Assert.Equal(account.HomeId, resumed.AccountHome);
    var brief = new string('x', 40);
    var started = await planner.PrepareAsync(JsonSerializer.SerializeToElement(new { cwd = root.DirectoryPath, brief, title = "Scoped change" }), account, default);
    Assert.Equal(brief, started.InitialPrompt); Assert.Null(started.ConversationId);
    await Assert.ThrowsAsync<McpRefusal>(() => planner.PrepareAsync(JsonSerializer.SerializeToElement(new { cwd = root.DirectoryPath, conversation = "../../other" }), account, default).AsTask());
  }
  private string Home(SessionDefinition source) => Path.Combine(root.DirectoryPath, "accounts", source.AccountHome!, source.Provider);
  private string Transcript(SessionDefinition source)
  {
    var folder = Path.Combine(Home(source), source.Provider == "claude" ? "projects/project" : "sessions/2026/10/29"); Directory.CreateDirectory(folder);
    var path = Path.Combine(folder, (source.Provider == "claude" ? "" : "rollout-") + source.ConversationId + ".jsonl");
    File.WriteAllText(path, source.Provider == "claude" ? JsonSerializer.Serialize(new { sessionId = source.ConversationId, cwd = source.Cwd, type = "user", message = "fixture conversation" }) : JsonSerializer.Serialize(new { type = "session_meta", payload = new { id = source.ConversationId, cwd = source.Cwd } }));
    return path;
  }
  private sealed class Store<T> : IStateStore<T> { private T? value; public T? Load() => value; public void Save(T next) => value = next; }
  private sealed class Processes : ISessionProcessKeeper
  {
    private readonly HashSet<string> live = [];
    public bool FailQuit; public bool FailLaunch; public bool Unknown; public int Launches; public List<string> Stopped { get; } = [];
    public ValueTask<ProcessObservation> ObserveAsync(SessionRecord row, CancellationToken ct) => ValueTask.FromResult(new ProcessObservation(Unknown ? ProcessPresence.Unknown : live.Contains(row.CreationKey) ? ProcessPresence.Live : ProcessPresence.Dead, row.CreationKey));
    public ValueTask<ProcessObservation> EnsureAsync(SessionRecord row, bool resume, CancellationToken ct) { if (FailLaunch) throw new IOException("fixture"); if (live.Add(row.CreationKey)) Launches++; return ValueTask.FromResult(new ProcessObservation(ProcessPresence.Live, row.CreationKey)); }
    public ValueTask QuitAsync(string lease, CancellationToken ct) { if (FailQuit) throw new IOException("fixture"); Stopped.Add(lease); live.Remove(lease); return ValueTask.CompletedTask; }
    public ValueTask WriteAsync(string lease, ReadOnlyMemory<byte> bytes, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask ResizeAsync(string lease, TerminalSize size, CancellationToken ct) => ValueTask.CompletedTask;
  }
  public void Dispose() => Directory.Delete(root.DirectoryPath, true);
}
