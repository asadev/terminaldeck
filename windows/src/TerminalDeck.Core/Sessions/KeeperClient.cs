using System.Text;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.Core.Sessions;

// The client never retries a mutation after an ambiguous disconnect. Reattach to
// the durable session id first; create retries must reuse that same id.
public sealed class KeeperClient(IKeeperConnector connector, ReadOnlyMemory<byte> secret)
{
  private readonly string credential = secret.Length >= 32 ? Encoding.UTF8.GetString(secret.Span) : throw new ArgumentException("The keeper needs a private credential.");
  private readonly object gate = new();
  private Guid? instance;
  public async ValueTask<KeeperHello> HelloAsync(CancellationToken cancellationToken = default)
  {
    var response = await SendAsync(new() { Secret = credential, Operation = "hello" }, cancellationToken);
    var hello = response.Hello ?? throw new IOException("The keeper did not identify itself.");
    if (hello.ProtocolVersion != KeeperWire.Version) throw new InvalidOperationException("The running keeper uses another version. Its sessions were left running.");
    lock (gate) instance = hello.Instance;
    return hello;
  }
  public ValueTask<KeeperResponse> ShutdownIdleAsync(CancellationToken ct = default) => SendAsync(new() { Secret = credential, Operation = "shutdown-idle", Instance = Current() }, ct);
  public ValueTask<KeeperResponse> PrepareUpdateAsync(CancellationToken ct = default) => SendAsync(new() { Secret = credential, Operation = "prepare-update", Instance = Current() }, ct);
  public ValueTask<KeeperResponse> ListAsync(CancellationToken cancellationToken = default) => SendAsync(new() { Secret = credential, Operation = "list" }, cancellationToken);
  // What every open terminal is doing now (output, typing, the AI's own busy flag), for the update check.
  public ValueTask<KeeperResponse> ActivityAsync(CancellationToken ct = default) => SendAsync(new() { Secret = credential, Operation = "activity" }, ct);
  // An AI hook named the conversation this terminal is in now.
  public ValueTask<KeeperResponse> UpdateConversationAsync(string id, string conversation, CancellationToken ct = default)
    => SendAsync(new() { Secret = credential, Operation = "conversation", Instance = Current(), Id = id, Conversation = conversation }, ct);
  public ValueTask<KeeperResponse> CreateAsync(SessionDefinition definition, CancellationToken cancellationToken = default) => SendAsync(new() { Secret = credential, Operation = "create", Instance = Current(), Launch = definition }, cancellationToken);
  public ValueTask<KeeperResponse> RollbackAccountAsync(SessionDefinition original, string transaction, CancellationToken ct = default)
    => SendAsync(new() { Secret = credential, Operation = "account-rollback", Instance = Current(), Id = original.Id, Launch = original, Transaction = transaction }, ct);
  public ValueTask<KeeperResponse> SwitchAccountAsync(SessionDefinition destination, long revision, string transaction, CancellationToken ct = default)
    => SendAsync(new() { Secret = credential, Operation = "account", Instance = Current(), Id = destination.Id, Launch = destination, Revision = revision, Transaction = transaction }, ct);
  public ValueTask<KeeperResponse> WriteAsync(string id, ReadOnlyMemory<byte> bytes, CancellationToken cancellationToken = default)
  {
    if (bytes.Length > KeeperWire.MaximumInputBytes) throw new ArgumentException("That input is too large.");
    return SendAsync(new() { Secret = credential, Operation = "write", Instance = Current(), Id = id, Bytes = bytes.ToArray() }, cancellationToken);
  }
  public ValueTask<KeeperResponse> RenameAsync(string id, string title, CancellationToken ct = default) => SendAsync(new() { Secret = credential, Operation = "rename", Instance = Current(), Id = id, Title = title }, ct);
  public ValueTask<KeeperResponse> ResizeAsync(string id, TerminalSize size, CancellationToken ct = default)
  {
    size.Validate(); return SendAsync(new() { Secret = credential, Operation = "resize", Instance = Current(), Id = id, Cols = size.Columns, Rows = size.Rows }, ct);
  }
  public ValueTask<KeeperResponse> StopAsync(string id, CancellationToken ct = default) => SendAsync(new() { Secret = credential, Operation = "remove", Instance = Current(), Id = id }, ct);
  public async ValueTask<KeeperRemoteAttachment> AttachAsync(string id, CancellationToken cancellationToken = default)
  {
    var expected = Current(); var stream = await connector.ConnectAsync(cancellationToken);
    try
    {
      await KeeperWire.WriteAsync(stream, new KeeperRequest { Secret = credential, Operation = "watch", Instance = expected, Id = id }, cancellationToken: cancellationToken);
      var response = await KeeperWire.ReadAsync<KeeperResponse>(stream, response: true, cancellationToken);
      Check(response);
      var snapshot = response.Snapshot ?? throw new IOException("The keeper did not send a session snapshot.");
      if (snapshot.Session.Definition.Id != id) throw new IOException("The keeper sent a different session.");
      return new(stream, snapshot);
    }
    catch { await stream.DisposeAsync(); throw; }
  }
  private Guid Current() { lock (gate) return instance ?? throw new InvalidOperationException("Connect to the keeper before changing a session."); }
  private async ValueTask<KeeperResponse> SendAsync(KeeperRequest request, CancellationToken ct)
  {
    await using var stream = await connector.ConnectAsync(ct);
    await KeeperWire.WriteAsync(stream, request, cancellationToken: ct);
    var response = await KeeperWire.ReadAsync<KeeperResponse>(stream, response: true, ct); Check(response); return response;
  }
  private static void Check(KeeperResponse response)
  {
    // A peer's raw error text is never a trusted diagnostic or log message.
    if (response.Error is not null) throw new IOException("The keeper refused this request. Reconnect before trying again.");
  }
}
public sealed class KeeperRemoteAttachment(Stream stream, SessionSnapshot snapshot) : IAsyncDisposable
{
  public SessionSnapshot Snapshot { get; } = snapshot;
  public async IAsyncEnumerable<SessionEvent> Events([System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken = default)
  {
    var sequence = Snapshot.Sequence;
    while (!cancellationToken.IsCancellationRequested)
    {
      var message = await KeeperWire.ReadAsync<KeeperResponse>(stream, response: true, cancellationToken);
      var change = message.Event ?? throw new IOException("The keeper event stream ended unexpectedly.");
      if (change.Id != Snapshot.Session.Definition.Id || change.Sequence <= sequence) throw new IOException("The keeper event stream needs a fresh snapshot.");
      sequence = change.Sequence; yield return change;
    }
  }
  public ValueTask DisposeAsync() => stream.DisposeAsync();
}
