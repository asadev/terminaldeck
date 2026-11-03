using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Sessions;

public sealed class MemoryState<T> : IStateStore<T>
{
  public T? Value { get; set; }
  public bool FailSave { get; set; }
  public T? Load() => Value;
  public void Save(T value) { if (FailSave) throw new IOException("Synthetic disk failure."); Value = value; }
}

public sealed class FakeProcessKeeper : ISessionProcessKeeper
{
  public Dictionary<string, ProcessObservation> Observations { get; } = [];
  public List<string> Calls { get; } = [];
  public Dictionary<string, string> Leases { get; } = [];
  public bool LoseReply { get; set; }
  public Action<SessionRecord>? BeforeStart { get; set; }
  public ValueTask<ProcessObservation> ObserveAsync(SessionRecord s, CancellationToken ct)
  {
    Calls.Add("observe:" + s.Definition.Id);
    return ValueTask.FromResult(Observations.GetValueOrDefault(s.Definition.Id, new(ProcessPresence.Dead)));
  }
  public ValueTask<ProcessObservation> EnsureAsync(SessionRecord s, bool resume, CancellationToken ct)
  {
    BeforeStart?.Invoke(s);
    Calls.Add((resume ? "resume:" : "start:") + s.Definition.Id);
    if (!Leases.TryGetValue(s.CreationKey, out var lease)) Leases[s.CreationKey] = lease = Guid.NewGuid().ToString();
    var live = new ProcessObservation(ProcessPresence.Live, lease);
    Observations[s.Definition.Id] = live;
    if (LoseReply) { LoseReply = false; throw new IOException("Synthetic lost reply."); }
    return ValueTask.FromResult(live);
  }
  public ValueTask WriteAsync(string leaseIdentity, ReadOnlyMemory<byte> bytes, CancellationToken ct) { Calls.Add("write:" + leaseIdentity); return ValueTask.CompletedTask; }
  public ValueTask ResizeAsync(string leaseIdentity, TerminalSize size, CancellationToken ct) { Calls.Add("resize:" + leaseIdentity); return ValueTask.CompletedTask; }
  public ValueTask QuitAsync(string leaseIdentity, CancellationToken ct) { Calls.Add("quit:" + leaseIdentity); return ValueTask.CompletedTask; }
}

public sealed class SessionKeeperTests
{
  private static SessionDefinition Definition(string provider = "codex", string? conversation = "conversation-1") => new(Guid.NewGuid().ToString(), provider, "C:\\work", "A session", ConversationId: conversation);

  [Fact] public async Task IdentityIsSavedBeforeStartAndDuplicateCreateDoesNotSpawn()
  {
    var store = new MemoryState<SessionLedger>(); var process = new FakeProcessKeeper(); var keeper = new SessionKeeper(store, process); var d = Definition();
    process.BeforeStart = row => Assert.Equal(row.CreationKey, Assert.Single(store.Value!.Sessions).CreationKey);
    var row = await keeper.CreateAsync(d);
    Assert.Equal(row, await keeper.CreateAsync(d)); Assert.Single(process.Leases);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await keeper.CreateAsync(d with { Cwd = "C:\\other" }));
  }

  [Fact] public async Task FailedJournalNeverStartsAProcess()
  {
    var process = new FakeProcessKeeper(); var keeper = new SessionKeeper(new MemoryState<SessionLedger> { FailSave = true }, process);
    await Assert.ThrowsAsync<IOException>(async () => await keeper.CreateAsync(Definition())); Assert.Empty(process.Calls);
  }

  [Fact] public async Task LostCreateReplyIsRecoveredWithoutDuplicate()
  {
    var store = new MemoryState<SessionLedger>(); var process = new FakeProcessKeeper { LoseReply = true }; var keeper = new SessionKeeper(store, process); var d = Definition();
    await Assert.ThrowsAsync<IOException>(async () => await keeper.CreateAsync(d));
    Assert.Equal("resume:" + d.Id, Assert.Single(process.Calls));
    var pending = keeper.Get(d.Id); var lease = Assert.Single(process.Leases).Value; process.Calls.Clear();
    var restarted = new SessionKeeper(store, process); await restarted.RecoverAsync();
    Assert.Equal(SessionState.Running, restarted.Get(d.Id).State); Assert.Single(process.Leases);
    Assert.Equal(pending.CreationKey, restarted.Get(d.Id).CreationKey); Assert.Equal(lease, restarted.Get(d.Id).LeaseIdentity);
    Assert.Equal("observe:" + d.Id, Assert.Single(process.Calls));
  }

  [Fact] public async Task AppRestartOnlyReattachesAndKeeperRestartAdoptsTheSameLease()
  {
    var store = new MemoryState<SessionLedger>(); var process = new FakeProcessKeeper(); var keeper = new SessionKeeper(store, process); var d = Definition();
    var original = await keeper.CreateAsync(d); await keeper.AppendOutputAsync(d.Id, "hello");
    await using (var app = await keeper.AttachAsync(d.Id)) Assert.Equal("hello", app.Snapshot.Replay);
    await using (var nextApp = await keeper.AttachAsync(d.Id)) Assert.Equal(original.LeaseIdentity, nextApp.Snapshot.Session.LeaseIdentity);
    var restarted = new SessionKeeper(store, process); await restarted.RecoverAsync();
    Assert.Equal(original.LeaseIdentity, restarted.Get(d.Id).LeaseIdentity); Assert.Equal("hello", restarted.Get(d.Id).Replay); Assert.Single(process.Leases);
  }

  [Fact] public async Task AllLiveSessionsAreDiscoveredBeforeAnyResume()
  {
    var store = new MemoryState<SessionLedger>(); var process = new FakeProcessKeeper(); var keeper = new SessionKeeper(store, process);
    var dead = await keeper.CreateAsync(Definition()); var live = await keeper.CreateAsync(Definition());
    process.Observations[dead.Definition.Id] = new(ProcessPresence.Dead); process.Calls.Clear();
    var restarted = new SessionKeeper(store, process); await restarted.RecoverAsync();
    Assert.Equal(new[] { "observe:" + dead.Definition.Id, "observe:" + live.Definition.Id, "resume:" + dead.Definition.Id }, process.Calls);
    Assert.Equal(live.LeaseIdentity, restarted.Get(live.Definition.Id).LeaseIdentity);
    Assert.Equal(dead.Definition.ConversationId, restarted.Get(dead.Definition.Id).Definition.ConversationId);
    Assert.NotEqual(dead.CreationKey, restarted.Get(dead.Definition.Id).CreationKey);
  }

  [Fact] public async Task UnknownProcessesAreHeldAndNeverResumedOrDropped()
  {
    var store = new MemoryState<SessionLedger>(); var process = new FakeProcessKeeper(); var keeper = new SessionKeeper(store, process); var row = await keeper.CreateAsync(Definition());
    process.Observations[row.Definition.Id] = new(ProcessPresence.Unknown); process.Calls.Clear();
    var restarted = new SessionKeeper(store, process); await restarted.RecoverAsync();
    Assert.Equal(SessionState.Held, Assert.Single(restarted.List()).State); Assert.Single(process.Calls);
  }

  [Theory] [InlineData("shell", "ignored")] [InlineData("codex", null)]
  public async Task ProvenDeadSessionWithoutResumeKeepsItsRow(string provider, string? conversation)
  {
    var store = new MemoryState<SessionLedger>(); var process = new FakeProcessKeeper(); var keeper = new SessionKeeper(store, process); var row = await keeper.CreateAsync(Definition(provider, conversation));
    process.Observations[row.Definition.Id] = new(ProcessPresence.Dead); var restarted = new SessionKeeper(store, process); await restarted.RecoverAsync();
    Assert.Equal(SessionState.Exited, Assert.Single(restarted.List()).State); Assert.Single(process.Leases);
  }

  [Theory] [InlineData(false, 0, true)] [InlineData(true, 0, false)] [InlineData(false, 1, false)] [InlineData(false, 5, false)]
  public async Task IdleIncludesBackgroundDescendants(bool busy, int children, bool expected)
  {
    var process = new FakeProcessKeeper(); var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), process); var row = await keeper.CreateAsync(Definition());
    process.Observations[row.Definition.Id] = new(ProcessPresence.Live, row.LeaseIdentity, busy, children);
    Assert.Equal(expected, await keeper.IsIdleAsync(row.Definition.Id));
  }

  [Fact] public async Task SnapshotAndEventsHaveAnExactBoundary()
  {
    var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), new FakeProcessKeeper()); var row = await keeper.CreateAsync(Definition());
    await keeper.AppendOutputAsync(row.Definition.Id, "before"); await using var attach = await keeper.AttachAsync(row.Definition.Id);
    await keeper.AppendOutputAsync(row.Definition.Id, "after"); using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(2));
    await using var events = attach.Events(ct.Token).GetAsyncEnumerator(); Assert.True(await events.MoveNextAsync());
    var change = events.Current; Assert.True(change.Sequence > attach.Snapshot.Sequence);
    var replay = new SessionReplay(); replay.Receive(change); replay.Receive(new(attach.Snapshot.Sequence, row.Definition.Id, "data", "duplicate"));
    replay.Restore(attach.Snapshot); replay.Receive(change); Assert.Equal("beforeafter", replay.Text);
  }

  [Fact] public async Task ReplayIsBoundedWithoutSplittingUnicode()
  {
    var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), new FakeProcessKeeper()); var row = await keeper.CreateAsync(Definition());
    await keeper.AppendOutputAsync(row.Definition.Id, new string('a', SessionKeeper.MaximumReplayBytes) + "🙂");
    var text = keeper.Get(row.Definition.Id).Replay; Assert.True(Encoding.UTF8.GetByteCount(text) <= SessionKeeper.MaximumReplayBytes); Assert.EndsWith("🙂", text);
  }

  [Fact] public async Task RestartedInstanceRefusesOldWritesAndOnlyExplicitStopQuits()
  {
    var store = new MemoryState<SessionLedger>(); var process = new FakeProcessKeeper(); var old = new SessionKeeper(store, process); var row = await old.CreateAsync(Definition());
    var keeper = new SessionKeeper(store, process); await keeper.RecoverAsync();
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await keeper.WriteAsync(row.Definition.Id, old.Instance, new byte[] { 1 }));
    Assert.DoesNotContain(process.Calls, c => c.StartsWith("quit:"));
    await keeper.StopAsync(row.Definition.Id, keeper.Instance); Assert.Single(process.Calls, c => c.StartsWith("quit:")); Assert.Single(keeper.List());
  }

  [Fact] public async Task PhoneViewRequiresCurrentSessionFolderAndAccountGrants()
  {
    var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), new FakeProcessKeeper()); var d = Definition() with { AccountId = "work" }; await keeper.CreateAsync(d);
    var grants = new PhoneSessionGrants(new MemoryState<SessionGrantState>()); var view = new PhoneSessionView(keeper, grants); var device = new ApprovedDevice("phone", "Phone", "ios", PhoneAccess.Full);
    Assert.Empty(view.Read(device)); grants.Set(new("phone", true, [], ["C:\\work-other"], ["work"])); Assert.Empty(view.Read(device));
    grants.Set(new("phone", false, [d.Id], ["C:\\work"], [])); Assert.Empty(view.Read(device));
    grants.Set(new("phone", false, [d.Id], ["C:\\work"], ["work"])); Assert.Single(view.Read(device));
    grants.Set(new("phone", false, [], ["C:\\work"], ["work"])); Assert.Empty(view.Read(device));
  }

  [Fact] public async Task AtomicFileStoreRestoresMetadataInAScratchRoot()
  {
    var path = Path.Combine(Path.GetTempPath(), "td-w2-" + Guid.NewGuid());
    try
    {
      var store = new JsonStateStore<SessionLedger>(AppDataRoot.Explicit(path), "sessions"); var keeper = new SessionKeeper(store, new FakeProcessKeeper()); var row = await keeper.CreateAsync(Definition());
      Assert.Equal(row, Assert.Single(new SessionKeeper(store, new FakeProcessKeeper()).List())); Assert.Empty(Directory.GetFiles(path, "*.tmp", SearchOption.AllDirectories));
    }
    finally { if (Directory.Exists(path)) Directory.Delete(path, true); }
  }
}

public sealed class KeeperWireTests
{
  [Fact] public async Task PrivateV2UsesBigEndianLengthAndBase64Bytes()
  {
    using var stream = new MemoryStream(); var request = new KeeperRequest { Secret = "synthetic", Operation = "write", Bytes = [0, 255] };
    await KeeperWire.WriteAsync(stream, request); var bytes = stream.ToArray(); Assert.Equal(bytes.Length - 4, (int)BinaryPrimitives.ReadUInt32BigEndian(bytes));
    using var doc = JsonDocument.Parse(bytes.AsMemory(4)); Assert.Equal(2, doc.RootElement.GetProperty("protocolVersion").GetInt32()); Assert.Equal("AP8=", doc.RootElement.GetProperty("bytes").GetString());
    stream.Position = 0; var decoded = await KeeperWire.ReadAsync<KeeperRequest>(stream); Assert.Equal(request.Bytes, decoded.Bytes); Assert.DoesNotContain(request.Secret, request.ToString());
  }
  [Theory] [InlineData(0u)] [InlineData(8388609u)] [InlineData(uint.MaxValue)]
  public async Task RejectsUncheckedLengthBeforeReadingBody(uint length)
  {
    var header = new byte[4]; BinaryPrimitives.WriteUInt32BigEndian(header, length); using var stream = new MemoryStream(header);
    await Assert.ThrowsAsync<IOException>(async () => await KeeperWire.ReadAsync<KeeperRequest>(stream));
  }
  [Fact] public async Task FragmentedStreamAndTruncatedFramesAreHandled()
  {
    using var source = new MemoryStream(); await KeeperWire.WriteAsync(source, new KeeperHello(2, "test", Guid.NewGuid()));
    using var fragments = new FragmentStream(source.ToArray()); Assert.Equal(2, (await KeeperWire.ReadAsync<KeeperHello>(fragments)).ProtocolVersion);
    using var truncated = new MemoryStream(source.ToArray()[..^1]); await Assert.ThrowsAsync<EndOfStreamException>(async () => await KeeperWire.ReadAsync<KeeperHello>(truncated));
  }
  [Fact] public async Task EndpointChecksSecretVersionAndInstanceBeforeMutation()
  {
    var process = new FakeProcessKeeper(); var keeper = new SessionKeeper(new MemoryState<SessionLedger>(), process); var secret = new string('x', 32); var endpoint = new KeeperEndpoint(keeper, Encoding.UTF8.GetBytes(secret), "test");
    await Assert.ThrowsAsync<UnauthorizedAccessException>(async () => await endpoint.HandleAsync(new() { Secret = "wrong", Operation = "list" }));
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await endpoint.HandleAsync(new() { Secret = secret, Operation = "hello", ProtocolVersion = 1 }));
    var hello = await endpoint.HandleAsync(new() { Secret = secret, Operation = "hello" }); Assert.Equal(keeper.Instance, hello.Hello!.Instance);
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await endpoint.HandleAsync(new() { Secret = secret, Operation = "create", Launch = new(Guid.NewGuid().ToString(), "shell", "C:\\work", "Shell") })); Assert.Empty(process.Calls);
  }
  private sealed class FragmentStream(byte[] bytes) : MemoryStream(bytes)
  {
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) => base.ReadAsync(buffer[..Math.Min(1, buffer.Length)], cancellationToken);
  }
}
