using System.Collections.Immutable;
using System.Text.Json;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Integration;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tasks;
using TerminalDeck.Core.Tests.Tasks;

namespace TerminalDeck.Core.Tests.Integration;

public sealed class W9PhoneTests
{
  private sealed class Store<T>(T value) : IStateStore<T>
  { public T? Load() => value; public void Save(T next) => value = next; }
  private sealed class TrustStore : IDeviceTrustPersistence
  { private IReadOnlyList<StoredDevice> devices = []; public IReadOnlyList<StoredDevice> Load() => devices; public void Save(IReadOnlyList<StoredDevice> next) => devices = next; }
  private sealed class Sessions : IPhoneSessionView
  { public IReadOnlyList<JsonElement> Read(ApprovedDevice device) => [JsonSerializer.SerializeToElement(new { id = "granted-session", cwd = "C:/Work/Sample" })]; }
  private sealed class Hoot : IHoot
  {
    public HootState State = HootState.Empty with { Settings = new("codex", "account", "C:/Work/Sample", new()) };
    public HootState Read() => State;
    public event Action<HootState>? Changed;
    public string? LastTurn; public string? LastAnswer; public int Starts; public int Stops;
    public void Publish(HootState state) { State = state; Changed?.Invoke(state); }
    public ValueTask StartAsync(CancellationToken ct = default) { Starts++; return ValueTask.CompletedTask; }
    public ValueTask ConfigureAsync(HootSettings settings, CancellationToken ct = default) => throw new InvalidOperationException("Phone must not configure Hoot.");
    public ValueTask SayAsync(string clientId, string text, HootSource? source = null, CancellationToken cancellationToken = default)
    { LastTurn = clientId; Publish(State with { Lines = State.Lines.Add(new(State.Lines.Length + 1, "user", clientId, text, DateTimeOffset.UtcNow, clientId)) }); return ValueTask.CompletedTask; }
    public ValueTask<string> BackgroundTurnAsync(string clientId, string reason, string sourceId, string title, string text, string? compactLine = null, CancellationToken ct = default) => throw new NotSupportedException();
    public ValueTask CancelBackgroundAsync(string id, CancellationToken ct = default) => throw new NotSupportedException();
    public ValueTask StopAsync(CancellationToken ct = default) { Stops++; return ValueTask.CompletedTask; }
    public ValueTask AnswerAsync(string requestId, bool allow, CancellationToken ct = default) { LastAnswer = requestId; return ValueTask.CompletedTask; }
    public ValueTask RefreshAsync(CancellationToken ct = default) => throw new NotSupportedException();
    public ValueTask KeepUnconfirmedAsync(CancellationToken ct = default) => throw new NotSupportedException();
    public ValueTask ContinueAsync(CancellationToken ct = default) => ValueTask.CompletedTask;
    public ValueTask SaveMemoryAsync(string card, string playbook, CancellationToken ct = default) => throw new NotSupportedException();
    public ValueTask SaveBoardAsync(HootBoardRow row, CancellationToken ct = default) => throw new NotSupportedException();
    public ValueTask<HootHandoff> HandoffAsync(string clientId, string sessionId, string text, CancellationToken ct = default) => throw new NotSupportedException();
  }
  private sealed class Fixture : IDisposable
  {
    public DeviceTrust Trust { get; } = new(new TrustStore()); public Hoot Hoot { get; } = new();
    public byte[] Key { get; } = Enumerable.Repeat((byte)9, 32).ToArray();
    public PairingReceipt Pair { get; } public W9PhoneApplication App { get; } public bool Allowed = true;
    public Fixture(PhoneAccess access = PhoneAccess.Full, Func<IRelayPhoneApplication, DeviceTrust, IRelayPhoneApplication>? wrap = null,
      Func<Hoot, CancellationToken, ValueTask<HootState>>? read = null)
    {
      Pair = Trust.Redeem(Trust.Pairing.Create().Code, "Synthetic phone", "android", Key); Trust.Approve(Pair.DeviceId, access);
      var sessions = new Sessions(); IRelayPhoneApplication next = new PhoneLink(Trust, "Fixture", "test", sessions);
      if (wrap is not null) next = wrap(next, Trust);
      App = new(next, Trust, Hoot, sessions, (_, _) => Allowed, readHoot: read is null ? null : ct => read(Hoot, ct));
      App.SetPublisher((_, _, _) => ValueTask.CompletedTask);
    }
    public ValueTask<PhoneApplicationReply> Send(object value, string channel = "phone") => App.ReceiveAsync(channel, Key, JsonSerializer.SerializeToUtf8Bytes(value), default);
    public ValueTask<PhoneApplicationReply> Hello() => Send(new { t = "hello", protocol = 1, token = Pair.Credential, device = new { name = "Synthetic phone", platform = "android" }, capabilities = new[] { "hoot.events" } });
    public void Dispose() => App.Dispose();
  }
  private static JsonElement Parse(byte[] bytes) { using var doc = JsonDocument.Parse(bytes); return doc.RootElement.Clone(); }
  [Fact] public void HootEventIdentityAcknowledgesPhoneEchoAndPreservesSignInFailure()
  {
    static JsonElement[] Events(HootState state) => Parse(W9PhoneApplication.Page(state)).GetProperty("events").EnumerateArray().ToArray();
    static long Sequence(JsonElement value) => value.GetProperty("sequence").GetInt64();
    var now = DateTimeOffset.UtcNow; var turnId = Guid.NewGuid().ToString();
    const string text = "W9 scratch phone message.";
    const string reason = "Not signed in to Claude. Sign in to continue.";
    var empty = HootState.Empty;
    Assert.Empty(Events(empty));
    var line = new HootLine(1, "user", "user:" + turnId, text, now, turnId, Revision: 1);
    var turn = new HootTurn(turnId, text, new("person"), HootTurnState.Queued, now);
    var queued = empty with { Lines = [line], Turns = [turn], Revision = 1 };
    var echo = Assert.Single(Events(queued));
    Assert.Equal("user", echo.GetProperty("kind").GetString()); Assert.Equal(line.Id, echo.GetProperty("messageId").GetString());
    Assert.Equal(text, echo.GetProperty("value").GetProperty("text").GetString()); Assert.True(Sequence(echo) > 0);
    var running = queued with { Turns = [turn with { State = HootTurnState.Running }] };
    var repeated = Assert.Single(Events(running));
    Assert.Equal(echo.GetProperty("id").GetString(), repeated.GetProperty("id").GetString()); Assert.Equal(Sequence(echo), Sequence(repeated));
    var failed = queued with { Turns = [turn with { State = HootTurnState.Failed, Problem = reason }], Problem = reason };
    var rows = Events(failed);
    Assert.Single(rows, e => e.GetProperty("kind").GetString() == "user");
    // The Android link only acknowledges/follows events newer than its last
    // cursor. Its next events must be the real error, then completion.
    var newEvents = rows.Where(e => Sequence(e) > Sequence(echo)).ToArray();
    Assert.Equal(2, newEvents.Length); Assert.Equal("error", newEvents[0].GetProperty("kind").GetString());
    Assert.Equal(reason, newEvents[0].GetProperty("value").GetProperty("text").GetString());
    Assert.True(newEvents[0].GetProperty("value").GetProperty("isError").GetBoolean());
    Assert.Equal("completed", newEvents[1].GetProperty("kind").GetString()); Assert.True(Sequence(newEvents[1]) > Sequence(newEvents[0]));
    var secondId = Guid.NewGuid().ToString();
    var next = failed with { Problem = null, Revision = 2, Lines = failed.Lines.Add(new(2, "user", "user:" + secondId, "Next message", now, secondId, Revision: 2)),
      Turns = failed.Turns.Add(new(secondId, "Next message", new("person"), HootTurnState.Queued, now)) };
    var nextEcho = Assert.Single(Events(next), e => Sequence(e) > Sequence(newEvents[1]));
    Assert.Equal("user", nextEcho.GetProperty("kind").GetString()); Assert.Equal("Next message", nextEcho.GetProperty("value").GetProperty("text").GetString());
  }
  [Fact] public async Task WelcomeIncludesDeviceAccessBeforePanelReads()
  {
    var tasks = new TaskFixture(); var task = tasks.Create();
    using var f = new Fixture(wrap: (next, trust) => new TaskPhoneApplication(next, trust, new(tasks.Tasks, tasks.Projects, _ => null), (_, _, _) => true));
    var pushed = new List<JsonElement>();
    f.App.SetPublisher((_, bytes, _) => { pushed.Add(Parse(bytes)); return ValueTask.CompletedTask; });
    var hello = await f.Send(new { t = "hello", protocol = 1, token = f.Pair.Credential,
      device = new { name = "Synthetic phone", platform = "android" }, capabilities = new[] { "device.access", "hoot.events" } });
    Assert.Equal(2, hello.Messages.Count);
    var welcome = Parse(hello.Messages[0]); var access = Parse(hello.Messages[1]);
    Assert.Equal("welcome", welcome.GetProperty("t").GetString());
    Assert.Contains(welcome.GetProperty("capabilities").EnumerateArray(), c => c.GetString() == "device.access");
    Assert.Contains(welcome.GetProperty("capabilities").EnumerateArray(), c => c.GetString() == "panels.tasks");
    Assert.Equal("device.access", access.GetProperty("t").GetString()); Assert.Equal("full", access.GetProperty("level").GetString());
    var page = Parse(Assert.Single((await f.Send(new { t = "panel.read", panel = "tasks", path = "C:/Work/Sample" })).Messages));
    Assert.Equal(task.Id, Assert.Single(page.GetProperty("rows").EnumerateArray()).GetProperty("id").GetString());
    var state = Parse(Assert.Single((await f.Send(new { t = "hoot.state" })).Messages));
    Assert.True(state.GetProperty("state").GetProperty("grant").GetProperty("act").GetBoolean());
    f.Trust.Approve(f.Pair.DeviceId, PhoneAccess.Work);
    Assert.Equal("work", pushed.Single(p => p.GetProperty("t").GetString() == "device.access").GetProperty("level").GetString());
    Assert.False(pushed.Single(p => p.GetProperty("t").GetString() == "hoot.grant").GetProperty("link").GetProperty("grant").GetProperty("act").GetBoolean());
    await Assert.ThrowsAsync<ProtocolException>(async () => await f.Send(new { t = "hoot.say", text = "Cannot spend an owner turn" }));
    pushed.Clear(); f.Trust.Revoke(f.Pair.DeviceId);
    Assert.Equal(JsonValueKind.Null, pushed.Single(p => p.GetProperty("t").GetString() == "device.access").GetProperty("level").ValueKind);
    Assert.False(pushed.Single(p => p.GetProperty("t").GetString() == "hoot.grant").GetProperty("link").GetProperty("linked").GetBoolean());
    await Assert.ThrowsAsync<ProtocolException>(async () => await f.Send(new { t = "panel.read", panel = "tasks", path = "C:/Work/Sample" }));
    using var legacy = new Fixture();
    var oldHello = Parse(Assert.Single((await legacy.Hello()).Messages));
    Assert.DoesNotContain(oldHello.GetProperty("capabilities").EnumerateArray(), c => c.GetString() == "device.access");
  }
  [Fact] public async Task PhoneGetsTheSharedHootStreamUsingAndroidAliasesAndOnlyGrantedSessions()
  {
    using var f = new Fixture();
    var welcome = Parse(Assert.Single((await f.Hello()).Messages));
    Assert.Contains(welcome.GetProperty("capabilities").EnumerateArray(), c => c.GetString() == "hoot.events");
    var grant = Parse(Assert.Single((await f.Send(new { t = "copilot.hello" })).Messages));
    Assert.True(grant.GetProperty("link").GetProperty("grant").GetProperty("act").GetBoolean());
    await f.Send(new { t = "copilot.say", text = "Hello shared desk" });
    var page = Parse(Assert.Single((await f.Send(new { t = "copilot.attach" })).Messages));
    Assert.Equal("hoot.events", page.GetProperty("t").GetString()); Assert.Equal(f.Hoot.State.ConversationId, page.GetProperty("conversationId").GetString());
    Assert.Equal("Hello shared desk", page.GetProperty("events")[0].GetProperty("value").GetProperty("text").GetString());
    var sessions = Parse(Assert.Single((await f.Send(new { t = "hoot.sessions" })).Messages));
    Assert.Equal("granted-session", Assert.Single(sessions.GetProperty("sessions").EnumerateArray()).GetProperty("id").GetString());
  }
  [Fact] public async Task RecoveryCapabilityNamesComputerAndDoesNotOfferUnsupportedPhoneActions()
  {
    using var f = new Fixture(); var welcome = Parse(Assert.Single((await f.Hello()).Messages));
    Assert.Contains(welcome.GetProperty("capabilities").EnumerateArray(), value => value.GetString() == "hoot.recovery");
    var advertised = welcome.GetProperty("hoot").GetProperty("recovery");
    var response = Parse(Assert.Single((await f.Send(new { t = "copilot.recovery" })).Messages));
    Assert.Equal("hoot.recovery", response.GetProperty("t").GetString());
    var recovery = response.GetProperty("recovery");
    Assert.Equal(advertised.GetRawText(), recovery.GetRawText());
    Assert.False(recovery.GetProperty("retry").GetBoolean()); Assert.False(recovery.GetProperty("switchAccount").GetBoolean());
    Assert.False(recovery.GetProperty("options").GetBoolean()); Assert.Equal("computer", recovery.GetProperty("host").GetString());
    Assert.Equal("Sign in on this computer, then send your message again.", recovery.GetProperty("signInHint").GetString());
    foreach (var action in new[] { "hoot.retry", "hoot.account.set", "hoot.options.set" })
      await Assert.ThrowsAsync<ProtocolException>(async () => await f.Send(new { t = action }));
    Assert.Null(f.Hoot.LastTurn); Assert.Equal(0, f.Hoot.Starts);
  }
  [Fact] public async Task V3aReconnectUsesFreshStateAndNewIdentityWithoutReplayingATurn()
  {
    var connected = true;
    using var f = new Fixture(read: (hoot, _) => connected ? ValueTask.FromResult(hoot.State with { Lines = [] })
      : ValueTask.FromException<HootState>(new IOException("Synthetic keeper loss.")));
    var welcome = Parse(Assert.Single((await f.Hello()).Messages));
    var first = welcome.GetProperty("hoot").GetProperty("recovery").GetProperty("connectionId").GetString();
    f.Hoot.State = f.Hoot.State with { Lines = [new(1, "assistant", "cached", "Old cached answer", DateTimeOffset.UtcNow)] };
    var page = Parse(Assert.Single((await f.Send(new { t = "hoot.attach" })).Messages));
    Assert.Empty(page.GetProperty("events").EnumerateArray());
    Assert.Equal(first, page.GetProperty("recovery").GetProperty("connectionId").GetString());
    connected = false;
    var lost = await f.Send(new { t = "hoot.say", text = "Must not resend" }); Assert.True(lost.Close);
    var state = Parse(lost.Messages[0]).GetProperty("state");
    Assert.False(state.GetProperty("available").GetBoolean()); Assert.Equal(0, state.GetProperty("pending").GetInt32());
    Assert.False(state.GetProperty("grant").GetProperty("act").GetBoolean());
    Assert.Equal("reconnecting", state.GetProperty("recovery").GetProperty("state").GetString());
    Assert.True(state.GetProperty("recovery").GetProperty("retryConnection").GetBoolean());
    Assert.False(state.GetProperty("recovery").GetProperty("replayPending").GetBoolean());
    await f.App.DisconnectedAsync("phone"); connected = true;
    await Assert.ThrowsAsync<ProtocolException>(async () => await f.Send(new { t = "hoot.say", text = "Old channel" }));
    welcome = Parse(Assert.Single((await f.Hello()).Messages));
    Assert.NotEqual(first, welcome.GetProperty("hoot").GetProperty("recovery").GetProperty("connectionId").GetString());
    Assert.Null(f.Hoot.LastTurn); Assert.Equal(0, f.Hoot.Starts);
  }
  [Fact(Timeout = 10000)] public async Task V3aDisconnectDuringRefreshRefusesTheWaitingAction()
  {
    var waiting = new TaskCompletionSource<HootState>(TaskCreationOptions.RunContinuationsAsynchronously);
    var reading = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var hold = false;
    using var f = new Fixture(read: (hoot, _) =>
    { if (!hold) return ValueTask.FromResult(hoot.State); reading.TrySetResult(); return new(waiting.Task); });
    await f.Hello(); hold = true;
    var request = f.Send(new { t = "hoot.say", text = "Old connection" }).AsTask(); await reading.Task;
    await f.App.DisconnectedAsync("phone"); hold = false; await f.Hello(); waiting.SetResult(f.Hoot.State);
    await Assert.ThrowsAsync<ProtocolException>(async () => await request); Assert.Null(f.Hoot.LastTurn); Assert.Equal(0, f.Hoot.Starts);
  }
  [Fact] public async Task V3aKeeperLossDuringPushWithdrawsControlsAndPendingQuestions()
  {
    var connected = true;
    using var f = new Fixture(read: (hoot, _) => connected ? ValueTask.FromResult(hoot.State)
      : ValueTask.FromException<HootState>(new IOException("Synthetic keeper loss.")));
    var pushed = new List<JsonElement>(); f.App.SetPublisher((_, bytes, _) => { pushed.Add(Parse(bytes)); return ValueTask.CompletedTask; });
    await f.Hello(); await f.Send(new { t = "hoot.attach" }); connected = false;
    f.Hoot.Publish(f.Hoot.State with { Revision = 1 });
    var grant = pushed.Single(p => p.GetProperty("t").GetString() == "hoot.grant").GetProperty("link");
    Assert.False(grant.GetProperty("linked").GetBoolean()); Assert.False(grant.GetProperty("grant").GetProperty("act").GetBoolean());
    Assert.Equal("reconnecting", grant.GetProperty("recovery").GetProperty("state").GetString());
    Assert.Empty(pushed.Single(p => p.GetProperty("t").GetString() == "hoot.pending").GetProperty("questions").EnumerateArray());
    Assert.DoesNotContain(pushed, p => p.GetProperty("t").GetString() == "hoot.events");
  }
  [Theory] [InlineData(PhoneAccess.Look)] [InlineData(PhoneAccess.Work)]
  public async Task ReadAccessDoesNotSpendAnOwnerTurnWithoutRemoteCallerTiers(PhoneAccess access)
  {
    using var f = new Fixture(access); await f.Hello();
    var grant = Parse(Assert.Single((await f.Send(new { t = "hoot.hello" })).Messages));
    Assert.False(grant.GetProperty("link").GetProperty("grant").GetProperty("act").GetBoolean());
    await f.Send(new { t = "hoot.state" });
    await Assert.ThrowsAsync<ProtocolException>(async () => await f.Send(new { t = "hoot.say", text = "Spend a turn" }));
    Assert.Null(f.Hoot.LastTurn);
  }
  [Fact] public async Task GrantRemovalAndDeviceRevocationApplyToTheVeryNextRead()
  {
    using var f = new Fixture();
    await Assert.ThrowsAsync<ProtocolException>(async () => await f.Send(new { t = "hoot.state" }));
    await f.Hello(); f.Allowed = false;
    await Assert.ThrowsAsync<ProtocolException>(async () => await f.Send(new { t = "hoot.state" }));
    f.Allowed = true; f.Trust.Revoke(f.Pair.DeviceId);
    await Assert.ThrowsAsync<ProtocolException>(async () => await f.Send(new { t = "hoot.state" }));
  }
  [Fact] public async Task ChangesPushWithoutPollingAndDetachAndGrantRemovalStopDelivery()
  {
    using var f = new Fixture(); var pushed = new List<byte[]>();
    f.App.SetPublisher((channel, bytes, _) => { Assert.Equal("phone", channel); pushed.Add(bytes); return ValueTask.CompletedTask; });
    await f.Hello(); await f.Send(new { t = "hoot.attach" });
    f.Hoot.Publish(f.Hoot.State with { Revision = 1 }); Assert.Equal(2, pushed.Count);
    Assert.Equal("hoot.events", Parse(pushed[0]).GetProperty("t").GetString()); Assert.Equal("hoot.pending", Parse(pushed[1]).GetProperty("t").GetString());
    await f.Send(new { t = "hoot.detach" }); f.Hoot.Publish(f.Hoot.State with { Revision = 2 }); Assert.Equal(2, pushed.Count);
    await f.Send(new { t = "hoot.attach" }); f.Allowed = false; f.Hoot.Publish(f.Hoot.State with { Revision = 3 }); Assert.Equal(4, pushed.Count);
    var withdrawn = Parse(pushed[2]); Assert.Equal("hoot.grant", withdrawn.GetProperty("t").GetString());
    var link = withdrawn.GetProperty("link"); Assert.False(link.GetProperty("linked").GetBoolean()); Assert.False(link.GetProperty("open").GetBoolean());
    foreach (var tier in new[] { "read", "act", "alter" }) Assert.False(link.GetProperty("grant").GetProperty(tier).GetBoolean());
    var cleared = Parse(pushed[3]); Assert.Equal("hoot.pending", cleared.GetProperty("t").GetString()); Assert.Empty(cleared.GetProperty("questions").EnumerateArray());
    f.Hoot.Publish(f.Hoot.State with { Revision = 4 }); Assert.Equal(4, pushed.Count);
    await f.App.DisconnectedAsync("phone");
  }
  [Fact] public async Task OnlyThePhoneThatStartedATurnCanAnswerItsConfirmation()
  {
    using var f = new Fixture(); await f.Hello();
    await f.Send(new { t = "hoot.say", text = "A task" });
    var own = new HootLine(2, "approval", "own", "Allow owned action?", DateTimeOffset.UtcNow, f.Hoot.LastTurn, "own-request", true);
    var other = new HootLine(3, "approval", "other", "Desktop action", DateTimeOffset.UtcNow, "desktop-turn", "desktop-request", true);
    f.Hoot.Publish(f.Hoot.State with { Lines = f.Hoot.State.Lines.Add(own).Add(other) });
    var pending = Parse(Assert.Single((await f.Send(new { t = "hoot.pending" })).Messages));
    Assert.Equal("own-request", Assert.Single(pending.GetProperty("questions").EnumerateArray()).GetProperty("id").GetString());
    await Assert.ThrowsAsync<ProtocolException>(async () => await f.Send(new { t = "hoot.answer", id = "desktop-request", approved = true }));
    await f.Send(new { t = "hoot.answer", id = "own-request", approved = false }); Assert.Equal("own-request", f.Hoot.LastAnswer);
    await Assert.ThrowsAsync<ProtocolException>(async () => await f.Send(new { t = "hoot.options.set", model = "anything" }));
  }
  [Fact] public async Task TaskPanelReadsKeepTheirSeparateCurrentProjectGrantThroughTheWrapper()
  {
    var tasks = new TaskFixture(); var task = tasks.Create(); var allowed = true;
    using var f = new Fixture(wrap: (next, trust) => new TaskPhoneApplication(next, trust, new(tasks.Tasks, tasks.Projects, _ => null), (_, _, _) => allowed));
    await f.Hello();
    var page = Parse(Assert.Single((await f.Send(new { t = "panel.read", panel = "tasks", path = "C:/Work/Sample" })).Messages));
    Assert.Equal(task.Id, Assert.Single(page.GetProperty("rows").EnumerateArray()).GetProperty("id").GetString());
    allowed = false;
    await Assert.ThrowsAsync<ProtocolException>(async () => await f.Send(new { t = "panel.read", panel = "tasks", path = "C:/Work/Sample" }));
  }
  [Fact] public void BoundedEventPagesUsePhoneEventKindsAndStableOlderPositions()
  {
    var state = HootState.Empty with { Lines = Enumerable.Range(1, 700).Select(n => new HootLine(n, "assistant", "message:" + n, new string('界', 6000), DateTimeOffset.UtcNow)).ToImmutableArray() };
    var bytes = W9PhoneApplication.Page(state); Assert.True(bytes.Length <= PhoneWire.MaximumMessageBytes);
    var page = Parse(bytes); var first = page.GetProperty("first").GetInt32(); Assert.True(first > 0);
    var older = Parse(W9PhoneApplication.Page(state, first)); Assert.True(older.GetProperty("older").GetBoolean()); Assert.False(older.GetProperty("reset").GetBoolean());
    Assert.Equal(1, page.GetProperty("events")[0].GetProperty("version").GetInt32());
    Assert.Equal("message", page.GetProperty("events")[0].GetProperty("kind").GetString());
    Assert.All(page.GetProperty("events").EnumerateArray(), e => Assert.Equal(state.ConversationId, e.GetProperty("conversationId").GetString()));
  }
  [Fact] public void HootGrantIsBoundToItsCurrentFolderAndAccountAndDefaultsToNone()
  {
    var grants = new W9PhoneHootGrants(new Store<W9PhoneHootGrantState>(new([]))); var device = new ApprovedDevice("phone", "Fixture", "android", PhoneAccess.Full);
    var state = new Hoot().State; Assert.False(grants.Allows(device, state));
    grants.Set(new(device.Id, "C:/Work/Sample", "account", true)); Assert.True(grants.Allows(device, state));
    Assert.False(grants.Allows(device, state with { Settings = state.Settings! with { AccountId = "different" } }));
    Assert.False(grants.Allows(device, state with { Settings = state.Settings! with { Folder = "C:/Work/Other" } }));
  }
}
