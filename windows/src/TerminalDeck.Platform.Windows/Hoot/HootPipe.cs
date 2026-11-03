using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Channels;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Hoot;

public sealed record HootPipeRequest(string Secret, string Operation, string Id = "", string Text = "", string Extra = "",
  HootSettings? Settings = null, HootSource? Source = null, HootBoardRow? Row = null, bool Allow = false)
{
  public ChatAttachmentData[] Attachments { get; init; } = [];
  public override string ToString() => "<private Hoot request>";
}
public sealed record HootPipeReply(HootState? State = null, HootHandoff? Handoff = null, string? Problem = null, ProviderModel[]? Models = null);

public sealed class HootPipeServer(AppDataRoot root, IHoot hoot, ReadOnlyMemory<byte> credential)
{
  public static string Name(AppDataRoot root) => "terminaldeck-hoot-" + root.NamespaceId;
  public async Task RunAsync(CancellationToken ct)
  {
    WindowsPrivateDirectory.Ensure(Path.Combine(root.DirectoryPath, "state"));
    using var owner = new FileStream(Path.Combine(root.DirectoryPath, "state", "hoot-service.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read);
    await hoot.StartAsync(ct);
    using var slots = new SemaphoreSlim(8); var clients = new ConcurrentDictionary<Guid, Task>();
    try
    {
      while (!ct.IsCancellationRequested)
      {
        await slots.WaitAsync(ct); NamedPipeServerStream? pipe = null;
        try
        {
          pipe = new(Name(root), PipeDirection.InOut, 8, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
          await pipe.WaitForConnectionAsync(ct); var accepted = pipe; pipe = null; var id = Guid.NewGuid();
          var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
          async Task Serve() { await ready.Task; try { await ServeAsync(accepted, ct); } finally { clients.TryRemove(id, out _); slots.Release(); } }
          clients[id] = Serve(); ready.SetResult();
        }
        catch { pipe?.Dispose(); slots.Release(); throw; }
      }
    }
    catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
    finally { await Task.WhenAll(clients.Values); }
  }
  private async Task ServeAsync(NamedPipeServerStream pipe, CancellationToken ct)
  {
    await using (pipe)
    {
      try
      {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(65));
        var request = await KeeperWire.ReadAsync<HootPipeRequest>(pipe, cancellationToken: deadline.Token);
        if (request.Secret.Length > 256 || !CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(request.Secret), Encoding.UTF8.GetBytes(Convert.ToBase64String(credential.Span)))) return;
        if (request.Operation == "watch")
        {
          using var watch = CancellationTokenSource.CreateLinkedTokenSource(ct);
          var channel = Channel.CreateBounded<HootState>(new BoundedChannelOptions(1) { FullMode = BoundedChannelFullMode.DropOldest });
          void Changed(HootState state) => channel.Writer.TryWrite(state);
          hoot.Changed += Changed;
          async Task DetectClose()
          { try { await pipe.ReadExactlyAsync(new byte[1], watch.Token); } catch (Exception ex) when (ex is IOException or OperationCanceledException) { } finally { watch.Cancel(); } }
          var closed = DetectClose();
          try
          {
            Changed(hoot.Read());
            await foreach (var state in channel.Reader.ReadAllAsync(watch.Token)) await KeeperWire.WriteAsync(pipe, new HootPipeReply(state), true, watch.Token);
          }
          finally { hoot.Changed -= Changed; watch.Cancel(); await closed; }
          return;
        }
        if (request.Operation == "models")
        { await KeeperWire.WriteAsync(pipe, new HootPipeReply(Models: (await hoot.ModelsAsync(request.Id, deadline.Token)).ToArray()), true, ct); return; }
        HootHandoff? handoff = null; var token = deadline.Token;
        switch (request.Operation)
        {
          case "read": break;
          case "ready": await hoot.EnsureReadyAsync(token); break;
          case "configure": await hoot.ConfigureAsync(request.Settings ?? throw new ArgumentException("Choose Hoot's settings."), token); break;
          case "say":
            if (request.Source is { Kind: not "person" }) throw new ArgumentException("Agent notes use the guarded MCP door.");
            if (request.Attachments.Length > 0) await hoot.SayWithAttachmentsAsync(request.Id, request.Text, request.Attachments, request.Source, token);
            else await hoot.SayAsync(request.Id, request.Text, request.Source, token);
            break;
          case "background":
            var source = request.Source ?? throw new ArgumentException("Choose a background source.");
            await hoot.BackgroundTurnAsync(request.Id, source.Kind, source.Id, source.Title, request.Text, cancellationToken: token); break;
          case "cancel": await hoot.CancelBackgroundAsync(request.Id, token); break;
          case "stop": await hoot.StopAsync(token); break;
          case "keep": await hoot.KeepUnconfirmedAsync(token); break;
          case "continue": await hoot.ContinueAsync(token); break;
          case "answer": await hoot.AnswerAsync(request.Id, request.Allow, token); break;
          case "refresh": throw new InvalidOperationException("Memory upkeep does not start a new chat.");
          case "newChat": await hoot.RefreshAsync(token); break;
          case "memory": await hoot.SaveMemoryAsync(request.Text, request.Extra, token); break;
          case "board": await hoot.SaveBoardAsync(request.Row ?? throw new ArgumentException("Choose a board row."), token); break;
          case "handoff": handoff = await hoot.HandoffAsync(request.Id, request.Extra, request.Text, token); break;
          default: throw new ArgumentException("Choose a Hoot action.");
        }
        await KeeperWire.WriteAsync(pipe, new HootPipeReply(hoot.Read(), handoff), true, ct);
      }
      catch (Exception ex) when (ex is IOException or OperationCanceledException) { }
      catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or KeyNotFoundException)
      {
        // Never relay a provider's raw exception, arguments or private paths.
        try { await KeeperWire.WriteAsync(pipe, new HootPipeReply(Problem: "Hoot could not finish that action. Check the account, current turn and saved choices."), true, ct); }
        catch (Exception write) when (write is IOException or OperationCanceledException) { }
      }
    }
  }
}

public sealed class WindowsHootClient : IHoot, IAsyncDisposable
{
  private readonly AppDataRoot root;
  private readonly byte[] credential;
  private HootState state;
  private readonly CancellationTokenSource lifetime = new();
  private Task? watch;
  public event Action<HootState>? Changed;
  private WindowsHootClient(AppDataRoot root, ReadOnlyMemory<byte> credential, HootState state)
  { this.root = root; this.credential = credential.ToArray(); this.state = state; }
  public static async ValueTask<WindowsHootClient> ConnectAsync(AppDataRoot root, ReadOnlyMemory<byte> credential, CancellationToken ct = default)
  {
    if (credential.Length < 32) throw new ArgumentException("Use the keeper's private credential.");
    var client = new WindowsHootClient(root, credential, HootState.Empty);
    try { await client.CallAsync(new("", "read"), ct); await client.StartAsync(ct); return client; }
    catch { await client.DisposeAsync(); throw; }
  }
  public HootState Read() => Volatile.Read(ref state);
  private void Publish(HootState next)
  {
    Volatile.Write(ref state, next);
    foreach (var listener in Changed?.GetInvocationList() ?? [])
      try { ((Action<HootState>)listener)(next); } catch (Exception) { }
  }
  private async ValueTask<NamedPipeClientStream> OpenAsync(CancellationToken ct)
  {
    var pipe = new NamedPipeClientStream(".", HootPipeServer.Name(root), PipeDirection.InOut, PipeOptions.Asynchronous);
    try { await pipe.ConnectAsync(5000, ct); return pipe; } catch { await pipe.DisposeAsync(); throw; }
  }
  private HootPipeRequest Authenticate(HootPipeRequest request) => request with { Secret = Convert.ToBase64String(credential) };
  private async ValueTask<HootPipeReply> CallAsync(HootPipeRequest request, CancellationToken ct)
  {
    await using var pipe = await OpenAsync(ct); await KeeperWire.WriteAsync(pipe, Authenticate(request), cancellationToken: ct);
    var reply = await KeeperWire.ReadAsync<HootPipeReply>(pipe, true, ct);
    if (reply.Problem is not null) throw new InvalidOperationException(reply.Problem);
    if (reply.State is { } next) Publish(next);
    return reply;
  }
  public ValueTask StartAsync(CancellationToken cancellationToken = default)
  {
    if (watch is not null) return ValueTask.CompletedTask;
    watch = Task.Run(async () =>
    {
      try
      {
        await using var pipe = await OpenAsync(lifetime.Token);
        await KeeperWire.WriteAsync(pipe, Authenticate(new("", "watch")), cancellationToken: lifetime.Token);
        while (!lifetime.IsCancellationRequested)
        {
          var reply = await KeeperWire.ReadAsync<HootPipeReply>(pipe, true, lifetime.Token);
          if (reply.State is { } next) Publish(next);
        }
      }
      catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
      catch (Exception ex) when (ex is IOException or TimeoutException)
      { Publish(Read() with { Problem = "Hoot's connection closed. Reopen Hoot to reconnect." }); }
    });
    return ValueTask.CompletedTask;
  }
  private async ValueTask Send(HootPipeRequest request, CancellationToken ct) => await CallAsync(request, ct);
  public async ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(string accountId, CancellationToken cancellationToken = default) =>
    (await CallAsync(new("", "models", accountId), cancellationToken)).Models ?? [];
  public ValueTask ConfigureAsync(HootSettings settings, CancellationToken cancellationToken = default) => Send(new("", "configure", Settings: settings), cancellationToken);
  public ValueTask SayAsync(string clientId, string text, HootSource? source = null, CancellationToken cancellationToken = default)
  {
    if (source is not null && source.Kind != "person") throw new ArgumentException("Agent notes use the guarded MCP door.");
    return Send(new("", "say", clientId, text, Source: source), cancellationToken);
  }
  public ValueTask SayWithAttachmentsAsync(string clientId, string text, ChatAttachmentData[] attachments, HootSource? source = null, CancellationToken cancellationToken = default)
  {
    if (source is not null && source.Kind != "person") throw new ArgumentException("Agent notes use the guarded MCP door.");
    return Send(new("", "say", clientId, text, Source: source) { Attachments = attachments }, cancellationToken);
  }
  public async ValueTask<string> BackgroundTurnAsync(string clientId, string reason, string sourceId, string title, string text, string? compactLine = null, CancellationToken cancellationToken = default)
  { await Send(new("", "background", clientId, text, Source: new(reason, sourceId, title)), cancellationToken); return clientId; }
  public ValueTask CancelBackgroundAsync(string id, CancellationToken cancellationToken = default) => Send(new("", "cancel", id), cancellationToken);
  public ValueTask StopAsync(CancellationToken cancellationToken = default) => Send(new("", "stop"), cancellationToken);
  public ValueTask EnsureReadyAsync(CancellationToken cancellationToken = default) => Send(new("", "ready"), cancellationToken);
  public ValueTask KeepUnconfirmedAsync(CancellationToken cancellationToken = default) => Send(new("", "keep"), cancellationToken);
  public ValueTask ContinueAsync(CancellationToken cancellationToken = default) => Send(new("", "continue"), cancellationToken);
  public ValueTask AnswerAsync(string requestId, bool allow, CancellationToken cancellationToken = default) => Send(new("", "answer", requestId, Allow: allow), cancellationToken);
  public ValueTask RefreshAsync(CancellationToken cancellationToken = default) => Send(new("", "newChat"), cancellationToken);
  public ValueTask SaveMemoryAsync(string card, string playbook, CancellationToken cancellationToken = default) => Send(new("", "memory", Text: card, Extra: playbook), cancellationToken);
  public ValueTask SaveBoardAsync(HootBoardRow row, CancellationToken cancellationToken = default) => Send(new("", "board", Row: row), cancellationToken);
  public async ValueTask<HootHandoff> HandoffAsync(string clientId, string sessionId, string text, CancellationToken cancellationToken = default) =>
    (await CallAsync(new("", "handoff", clientId, text, sessionId), cancellationToken)).Handoff ?? throw new IOException("The handoff reply was lost. Check the saved handoff before sending another.");
  public async ValueTask DisposeAsync()
  {
    lifetime.Cancel(); if (watch is not null) await watch; lifetime.Dispose(); CryptographicOperations.ZeroMemory(credential);
  }
}
