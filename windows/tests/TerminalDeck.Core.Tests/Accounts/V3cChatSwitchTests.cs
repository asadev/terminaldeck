using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tests.Chats;
using TerminalDeck.Core.Tests.Mcp;
using TerminalDeck.Core.Tests.Sessions;

namespace TerminalDeck.Core.Tests.Accounts;

public sealed class V3cChatSwitchTests
{
  [Theory]
  [InlineData("claude")]
  [InlineData("codex")]
  [InlineData("gemini")]
  public async Task StartedChatMovesOnlyItsTranscriptAndKeepsHistoryAcrossRestart(string provider)
  {
    await using var f = await Fixture.CreateAsync(provider);
    var before = f.Chats.Get(f.Id); var original = File.ReadAllText(f.Transcript(f.First));
    await f.Chats.SetAccountAsync(f.Id, f.Second.Id);
    var after = f.Chats.Get(f.Id);
    Assert.Equal(before.ConversationId, after.ConversationId); Assert.Equal(before.Events, after.Events); Assert.Equal(before.Messages, after.Messages);
    Assert.Equal(before.Definition.Options, after.Definition.Options); Assert.Equal(f.Second.HomeId, after.Definition.AccountHome);
    Assert.NotEqual(before.CreationKey, after.CreationKey); Assert.Equal(1, after.AccountRevision); Assert.Equal(1, f.Keeper.Quits);
    Assert.Equal(original, File.ReadAllText(f.Transcript(f.Second))); Assert.True(File.Exists(f.Transcript(f.First)));
    Assert.False(File.Exists(Path.Combine(f.Home(f.Second), "private-fixture.txt"))); Assert.Equal(0, f.Keeper.Sends);
    await f.RestartAsync(); Assert.Equal(JsonSerializer.Serialize(after), JsonSerializer.Serialize(f.Chats.Get(f.Id)));
    var journal = new JsonStateStore<AccountSwitchJournal>(f.Root, "chat-account-switches").Load()!;
    Assert.Equal(SwitchState.Committed, Assert.Single(journal.Entries).State);
  }

  [Theory]
  [InlineData("signed-out")]
  [InlineData("missing")]
  [InlineData("conflict")]
  [InlineData("busy")]
  [InlineData("uncertain")]
  [InlineData("approval")]
  [InlineData("model")]
  [InlineData("unknown-worker")]
  public async Task UnsafeSwitchKeepsTheOriginalAccount(string problem)
  {
    await using var f = await Fixture.CreateAsync("claude"); var before = f.Chats.Get(f.Id);
    if (problem == "signed-out") f.Provider.Statuses[f.Second.Id] = new(false, null);
    if (problem == "missing") File.Delete(f.Transcript(f.First));
    if (problem == "conflict") { Directory.CreateDirectory(Path.GetDirectoryName(f.Transcript(f.Second))!); File.WriteAllText(f.Transcript(f.Second), "different saved conversation"); }
    if (problem == "model") f.Provider.Models = [new("other-model", "Other", 0)];
    if (problem == "unknown-worker") f.Keeper.Presence = ProcessPresence.Unknown;
    if (problem == "busy") f.History.Save(before with { Busy = true });
    if (problem == "uncertain") f.History.Save(before with { Messages = [new(Guid.NewGuid().ToString(), "uncertain", [], ChatMessageState.Uncertain)] });
    if (problem == "approval") f.History.Save(before with { Events = [.. before.Events, new(3, "approval", "waiting")] });
    if (problem is "busy" or "uncertain" or "approval") await f.RestartAsync();
    var error = await Record.ExceptionAsync(async () => await f.Chats.SetAccountAsync(f.Id, f.Second.Id));
    Assert.NotNull(error); Assert.Equal(f.First.Id, f.Chats.Get(f.Id).Definition.AccountId); Assert.Equal(before.ConversationId, f.Chats.Get(f.Id).ConversationId);
    Assert.Equal(0, f.Keeper.Quits); Assert.Equal(0, f.Keeper.Sends);
    if (problem == "signed-out") Assert.IsType<SignInRequiredException>(error);
  }

  [Theory]
  [InlineData("signed-out", "Not signed in")]
  [InlineData("missing", "Choose one saved conversation")]
  [InlineData("conflict", "different copy")]
  [InlineData("busy", "Finish this answer")]
  [InlineData("uncertain", "Finish this answer")]
  [InlineData("approval", "Finish this answer")]
  [InlineData("model", "Automatic")]
  [InlineData("unknown-worker", "Reconnect")]
  public async Task SwitchPlanReportsTheSpecificRefusalBeforeTouchingTheWorker(string problem, string sentence)
  {
    await using var f = await Fixture.CreateAsync("claude"); var before = f.Chats.Get(f.Id);
    if (problem == "signed-out") f.Provider.Statuses[f.Second.Id] = new(false, null);
    if (problem == "missing") File.Delete(f.Transcript(f.First));
    if (problem == "conflict") { Directory.CreateDirectory(Path.GetDirectoryName(f.Transcript(f.Second))!); File.WriteAllText(f.Transcript(f.Second), "different saved conversation"); }
    if (problem == "model") f.Provider.Models = [new("other-model", "Other", 0)];
    if (problem == "unknown-worker") f.Keeper.Presence = ProcessPresence.Unknown;
    if (problem == "busy") f.History.Save(before with { Busy = true });
    if (problem == "uncertain") f.History.Save(before with { Messages = [new(Guid.NewGuid().ToString(), "uncertain", [], ChatMessageState.Uncertain)] });
    if (problem == "approval") f.History.Save(before with { Events = [.. before.Events, new(3, "approval", "waiting")] });
    if (problem is "busy" or "uncertain" or "approval") await f.RestartAsync();
    var error = await Record.ExceptionAsync(async () => await f.Chats.CanSwitchAccountAsync(f.Id, f.Second.Id));
    Assert.NotNull(error); Assert.Contains(sentence, error.Message); Assert.Equal(0, f.Keeper.Quits); Assert.Equal(0, f.Keeper.Sends);
    Assert.Equal(f.First.Id, f.Chats.Get(f.Id).Definition.AccountId);
  }

  [Theory]
  [InlineData(false)]
  [InlineData(true)]
  public async Task PendingSwitchRecoversBeforeOrAfterTheSavedAccountChange(bool applied)
  {
    await using var f = await Fixture.CreateAsync("codex"); var chat = f.Chats.Get(f.Id);
    var before = new ConversationBinding(f.Id, f.Id, chat.ConversationId!, "codex", f.First.Id, f.First.HomeId, 0);
    var after = before with { AccountId = f.Second.Id, HomeId = f.Second.HomeId, Revision = 1 };
    var plan = new AccountSwitchPlan(Guid.NewGuid().ToString("N"), before, after, before.ProviderConversationId);
    if (applied)
    {
      Directory.CreateDirectory(Path.GetDirectoryName(f.Transcript(f.Second))!); File.Copy(f.Transcript(f.First), f.Transcript(f.Second));
      f.History.Save(chat with { Definition = chat.Definition with { AccountId = after.AccountId, AccountHome = after.HomeId }, AccountRevision = 1, LastAccountSwitch = plan.TransactionId, CreationKey = Guid.NewGuid().ToString("N"), WorkerSequence = 0 });
    }
    new JsonStateStore<AccountSwitchJournal>(f.Root, "chat-account-switches").Save(new(1, [new(plan, SwitchState.Pending)]));
    f.Keeper.Presence = ProcessPresence.Dead;
    await f.RestartAsync(); await f.Chats.ReconnectAsync(f.Id);
    Assert.Equal(f.Second.Id, f.Chats.Get(f.Id).Definition.AccountId); Assert.Equal(chat.ConversationId, f.Chats.Get(f.Id).ConversationId);
    Assert.Equal(SwitchState.Committed, new JsonStateStore<AccountSwitchJournal>(f.Root, "chat-account-switches").Load()!.Entries.Single().State);
    Assert.Equal(0, f.Keeper.Sends);
  }

  [Fact]
  public async Task DestinationSignOutDuringTransferRollsBackTheChatBinding()
  {
    await using var f = await Fixture.CreateAsync("claude"); var before = f.Chats.Get(f.Id);
    f.Keeper.OnQuit = () => f.Provider.Statuses[f.Second.Id] = new(false, null);
    await Assert.ThrowsAsync<SignInRequiredException>(async () => await f.Chats.SetAccountAsync(f.Id, f.Second.Id));
    var chat = f.Chats.Get(f.Id); Assert.Equal(f.First.Id, chat.Definition.AccountId); Assert.Equal(before.ConversationId, chat.ConversationId);
    Assert.Equal(before.Definition.Options, chat.Definition.Options); Assert.Equal(0, chat.AccountRevision);
    Assert.Equal(SwitchState.RolledBack, new JsonStateStore<AccountSwitchJournal>(f.Root, "chat-account-switches").Load()!.Entries.Single().State);
  }

  [Fact]
  public async Task McpPlansAndSwitchesAStartedChatWithItsExistingAccountPermission()
  {
    await using var f = await Fixture.CreateAsync("gemini"); var permission = new FakePermission(); var door = new McpDoor(permission);
    using var tools = new ChatMcpTools(f.Chats); tools.Register(door);
    var caller = door.RegisterCaller(new("v3c", null, null, true, AiPermissionMode.Ask, ["sessions.account"], [McpTier.Read, McpTier.Act, McpTier.Alter], ["*"], DateTimeOffset.UtcNow.AddMinutes(5)), (_, _, _, _, _) => ValueTask.FromResult(true));
    JsonElement Args(string action) => JsonSerializer.SerializeToElement(new { sessionId = f.Id, action, account = f.Second.Id });
    var plan = await door.CallAsync(caller.Id, "sessions.account", Args("plan")); Assert.True(plan.GetProperty("canSwitch").GetBoolean()); Assert.Equal(0, f.Keeper.Quits);
    await door.CallAsync(caller.Id, "sessions.account", Args("switch"));
    Assert.Equal(f.Second.Id, f.Chats.Get(f.Id).Definition.AccountId); Assert.Single(permission.Requests);
  }

  [Fact]
  public async Task ReadinessUsesTheRegisteredDoorAndOnlyCountsGrantedAccounts()
  {
    var service = new AccountService(new MemoryState<AccountState>(), [new FakeAccountProvider("codex")]);
    var first = await service.CreateAsync("codex", "Allowed"); await service.CreateAsync("codex", "Hidden");
    var permission = new FakePermission(); var door = new McpDoor(permission);
    door.Register("accounts.status", (c, a, ct) => { c.Require("accounts", first.Id); return ValueTask.FromResult(JsonSerializer.SerializeToElement(first)); });
    AccountReadinessTools.Register(door, service);
    var caller = door.RegisterCaller(new("v3c", null, null, true, AiPermissionMode.Ask, ["accounts.status"], [McpTier.Read], ["accounts:" + first.Id], DateTimeOffset.UtcNow.AddMinutes(5)), (_, _, _, _, _) => ValueTask.FromResult(true));
    var status = await door.CallAsync(caller.Id, "accounts.status", JsonSerializer.SerializeToElement(new { accountId = first.Id }));
    Assert.Equal(first.Id, status.GetProperty("Id").GetString());
    var providers = status.GetProperty("readiness").GetProperty("Providers").EnumerateArray().ToArray();
    Assert.Equal(1, providers.Sum(p => p.GetProperty("Accounts").GetInt32())); Assert.Empty(permission.Requests);
  }

  private sealed class Fixture : IAsyncDisposable
  {
    public AppDataRoot Root { get; } = AppDataRoot.Explicit(Path.Combine(RealTemporaryDirectory(), "td-v3c-switch-" + Guid.NewGuid().ToString("N")));
    private static string RealTemporaryDirectory() => OperatingSystem.IsMacOS() && Path.GetTempPath().StartsWith("/var/", StringComparison.Ordinal) ? "/private" + Path.GetTempPath() : Path.GetTempPath();
    public FakeAccountProvider Provider = null!;
    public AccountService Accounts = null!;
    public AccountProfile First = null!, Second = null!;
    public ChatHistory History = null!;
    public ChatSessions Chats = null!;
    public readonly SwitchKeeper Keeper = new();
    public string Id = Guid.NewGuid().ToString();
    public string Home(AccountProfile account) => Path.Combine(Root.DirectoryPath, "accounts", account.HomeId, account.Provider);
    public string Transcript(AccountProfile account) => Path.Combine(Home(account), account.Provider switch { "claude" => "projects", "codex" => "sessions", _ => Path.Combine(".gemini", "tmp") }, "folder", "session-12345678-1234-1234-1234-123456789012" + (account.Provider == "gemini" ? ".json" : ".jsonl"));
    public static async Task<Fixture> CreateAsync(string provider)
    {
      var f = new Fixture { Provider = new(provider) }; Directory.CreateDirectory(f.Root.DirectoryPath);
      f.Accounts = new(new MemoryState<AccountState>(), [f.Provider]); f.First = await f.Accounts.CreateAsync(provider, "First"); f.Second = await f.Accounts.CreateAsync(provider, "Second");
      f.Provider.Statuses[f.First.Id] = new(true, "first@example.test"); f.Provider.Statuses[f.Second.Id] = new(true, "second@example.test");
      await f.Accounts.RefreshAsync(f.First.Id); await f.Accounts.RefreshAsync(f.Second.Id);
      f.History = new(f.Root); var conversation = "12345678-1234-1234-1234-123456789012";
      f.History.Save(new(1, new(f.Id, provider, f.Root.DirectoryPath, "Saved chat", f.First.Id, f.First.HomeId, new("ordinary")), Guid.NewGuid().ToString("N"), [new(1, "user", "message", "hello"), new(2, "message", "reply", "saved reply")], [], WorkerSequence: 2, ConversationId: conversation));
      Directory.CreateDirectory(Path.GetDirectoryName(f.Transcript(f.First))!);
      var metadata = new { id = conversation, sessionId = conversation, cwd = f.Root.DirectoryPath };
      File.WriteAllText(f.Transcript(f.First), JsonSerializer.Serialize(provider == "codex" ? (object)new { type = "session_meta", payload = metadata } : metadata) + "\n");
      File.WriteAllText(Path.Combine(f.Home(f.First), "private-fixture.txt"), "must stay in first home");
      f.Chats = new(f.History, f.Keeper, f.Accounts); return f;
    }
    public async Task RestartAsync() { await Chats.DisposeAsync(); Chats = new(History, Keeper, Accounts); }
    public async ValueTask DisposeAsync() { await Chats.DisposeAsync(); Directory.Delete(Root.DirectoryPath, true); }
  }

  private sealed class SwitchKeeper : IChatProcessKeeper
  {
    public ProcessPresence Presence = ProcessPresence.Live;
    public int Quits, Sends;
    public Action? OnQuit;
    public ValueTask<ProcessObservation> ObserveAsync(SessionRecord session, CancellationToken ct) => ValueTask.FromResult(new ProcessObservation(Presence));
    public ValueTask<ProcessObservation> EnsureAsync(SessionRecord session, bool resume, CancellationToken ct) => throw new InvalidOperationException("Switching must not send a message.");
    public ValueTask QuitAsync(string lease, CancellationToken ct) { Quits++; Presence = ProcessPresence.Dead; OnQuit?.Invoke(); return ValueTask.CompletedTask; }
    public ValueTask<ChatDelivery> SendAsync(ChatRecord chat, ChatMessage message, CancellationToken ct) { Sends++; throw new InvalidOperationException("No message requested."); }
    public ValueTask AnswerAsync(ChatRecord chat, string id, bool allow, JsonElement input, CancellationToken ct) => throw new NotSupportedException();
    public ValueTask InterruptAsync(ChatRecord chat, CancellationToken ct) => throw new NotSupportedException();
    public ValueTask WriteAsync(string lease, ReadOnlyMemory<byte> bytes, CancellationToken ct) => throw new NotSupportedException();
    public ValueTask ResizeAsync(string lease, TerminalSize size, CancellationToken ct) => ValueTask.CompletedTask;
    public async IAsyncEnumerable<ChatSignal> WatchAsync(ChatRecord chat, long after, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct) { await Task.CompletedTask; yield break; }
  }
}
