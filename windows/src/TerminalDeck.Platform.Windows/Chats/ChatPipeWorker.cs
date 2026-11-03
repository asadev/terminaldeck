using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Chats;

public sealed record ChatWorkerReceipt(ChatDelivery Delivery, string Digest);
public sealed record ChatWorkerJournal(ChatWorkerReceipt[] Receipts, ChatSignal[] Signals, long Sequence, string? ConversationId);

// One detached worker per chat. It owns the CLI and receipts, so closing or
// restarting a window/supervisor cannot lose a write acknowledgment.
public sealed class ChatPipeWorker(AppDataRoot root, ChatWorkerPlan plan, ReadOnlyMemory<byte> credential)
{
  private readonly SemaphoreSlim gate = new(1);
  private readonly SemaphoreSlim sends = new(1);
  private readonly ConcurrentDictionary<Guid, Channel<ChatSignal>> watchers = new();
  private readonly CancellationTokenSource stopping = new();
  private readonly WindowsChatLaunchPlanner planner = new(root, plan.ToolsDirectory, plan.CodexAppServer);
  private ChatWorkerJournal journal = new([], [], 0, plan.Chat.ConversationId);
  private ChatCliConnection? connection;
  private volatile bool interrupting;
  private long interruptRevision;
  private string? activeClient;
  private string Key => plan.Chat.CreationKey;
  private string JournalPath => ChatWorkerPaths.FileFor(root, Key, ".journal.json");
  private ChatRecord Current => plan.Chat with { ConversationId = journal.ConversationId };
  private bool Exec => plan.Chat.Definition.Provider == "codex" && !plan.CodexAppServer;

  public async Task RunAsync(CancellationToken ct = default)
  {
    WindowsPrivateDirectory.Ensure(ChatWorkerPaths.DirectoryFor(root));
    using var ownership = new FileStream(ChatWorkerPaths.FileFor(root, Key, ".lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read);
    if (File.Exists(JournalPath)) throw new IOException("A stopped chat worker cannot be recreated with its old identity.");
    Save();
    using var self = Process.GetCurrentProcess();
    File.WriteAllBytes(ChatWorkerPaths.FileFor(root, Key, ".identity.json"), JsonSerializer.SerializeToUtf8Bytes(new ChatWorkerIdentity(self.Id, self.StartTime.ToUniversalTime().Ticks, Key, plan.Chat.Definition.Id)));
    using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(ct, stopping.Token);
    var clients = new ConcurrentDictionary<Guid, Task>(); using var slots = new SemaphoreSlim(16);
    try
    {
      while (!lifetime.IsCancellationRequested)
      {
        await slots.WaitAsync(lifetime.Token); NamedPipeServerStream? pipe = null;
        try
        {
          pipe = new(ChatWorkerPaths.Pipe(root, Key), PipeDirection.InOut, 16, PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly, 65536, 65536);
          await pipe.WaitForConnectionAsync(lifetime.Token);
          var accepted = pipe; var id = Guid.NewGuid(); var start = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
          async Task Serve()
          {
            await start.Task;
            try { await ServeAsync(accepted, lifetime.Token); }
            finally { clients.TryRemove(id, out _); slots.Release(); }
          }
          clients[id] = Serve(); start.SetResult(); pipe = null;
        }
        catch { pipe?.Dispose(); slots.Release(); throw; }
      }
    }
    catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    finally
    {
      lifetime.Cancel();
      await sends.WaitAsync();
      try { if (connection is not null) await connection.DisposeAsync(); }
      finally { sends.Release(); }
      foreach (var watcher in watchers.Values) watcher.Writer.TryComplete();
      await Task.WhenAll(clients.Values);
    }
  }
  private ChatWorkerState Snapshot() => new(journal.Receipts.Select(r => r.Delivery).ToArray(), journal.Signals, journal.Sequence, connection?.Alive == true, journal.ConversationId);
  private void Save()
  {
    var temporary = JournalPath + "." + Guid.NewGuid().ToString("N");
    try
    {
      using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
      { JsonSerializer.Serialize(file, journal); file.Flush(true); }
      File.Move(temporary, JournalPath, true);
    }
    finally { if (File.Exists(temporary)) File.Delete(temporary); }
  }
  private void Publish(ChatSignal signal)
  {
    signal = signal with { Sequence = checked(journal.Sequence + 1) };
    journal = journal with { Signals = [.. journal.Signals, signal], Sequence = signal.Sequence,
      ConversationId = signal.Kind == "conversation" ? signal.Text : journal.ConversationId };
    Save();
    foreach (var watcher in watchers.Values)
      if (!watcher.Writer.TryWrite(signal)) watcher.Writer.TryComplete(new IOException("Reconnect to read this chat's saved events."));
  }
  private async ValueTask ReceiveAsync(ChatSignal signal)
  {
    await gate.WaitAsync();
    try
    {
      if (interrupting && signal.Kind is "error" or "complete")
      { signal = signal with { Kind = "complete", Text = "Stopped" }; interrupting = false; }
      if (signal.Kind == "connectionLost" && (signal.ClientId ?? activeClient) is { } lost)
      {
        var receipt = journal.Receipts.FirstOrDefault(r => r.Delivery.ClientId == lost);
        if (receipt is not null) SetReceipt(receipt with { Delivery = new(lost, ChatMessageState.Uncertain) });
      }
      if (signal.Kind is "complete" or "error" or "connectionLost")
      {
        foreach (var request in journal.Signals.Where(s => s.Kind == "approval" && !journal.Signals.Any(a => a.Kind == "approvalResolved" && a.Id == s.Id)).ToArray())
          Publish(new(0, "approvalResolved", request.Id, "No longer waiting"));
      }
      Publish(signal with { ClientId = signal.ClientId ?? activeClient });
    }
    finally { gate.Release(); }
  }
  private void SetReceipt(ChatWorkerReceipt receipt)
  { journal = journal with { Receipts = [.. journal.Receipts.Where(r => r.Delivery.ClientId != receipt.Delivery.ClientId), receipt] }; Save(); }
  private async ValueTask<ChatDelivery> SendAsync(ChatMessage message, CancellationToken ct)
  {
    if (!Guid.TryParse(message.ClientId, out _) || message.Text.Length > 128_000 || message.Media.Length > 8) throw new ArgumentException("Choose a valid chat message.");
    var digest = Convert.ToHexStringLower(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(new { message.ClientId, message.Text, message.Media })));
    await gate.WaitAsync(ct);
    try
    {
      var existing = journal.Receipts.FirstOrDefault(r => r.Delivery.ClientId == message.ClientId);
      if (existing is not null)
      {
        if (existing.Digest != digest) throw new InvalidOperationException("That message id belongs to another message.");
        return existing.Delivery;
      }
      // Preflight media before recording a possible write. Data is read locally,
      // encoded transiently for the provider, and never stored in this journal.
      var history = new ChatHistory(root); foreach (var image in message.Media) _ = history.ReadMedia(plan.Chat.Definition.Id, image);
      var receipt = new ChatWorkerReceipt(new(message.ClientId, ChatMessageState.Dispatching), digest);
      SetReceipt(receipt); activeClient = message.ClientId;
    }
    finally { gate.Release(); }
    try
    {
      if (Exec && connection is not null) { await connection.Completion.WaitAsync(ct); await connection.DisposeAsync(); connection = null; }
      if (connection?.Alive != true)
      {
        if (connection is not null) await connection.DisposeAsync();
        connection = new(Current, new ChatHistory(root), planner.Plan(Current, Exec ? message : null), ReceiveAsync, plan.CodexAppServer,
          !File.Exists(Path.Combine(AppContext.BaseDirectory, "tools-bridge", "TerminalDeck.ToolBridge.exe")) ? null : [new {
            name = "deck-tools", command = Path.Combine(AppContext.BaseDirectory, "tools-bridge", "TerminalDeck.ToolBridge.exe"),
            args = new[] { "--root", root.DirectoryPath, "--chat", Current.Definition.Id }, env = Array.Empty<object>() }]);
        await connection.StartAsync(ct);
      }
      if (Exec) await connection.SendExecAsync(message, ct); else await connection.SendAsync(message, ct);
      await gate.WaitAsync(ct);
      try
      {
        if (connection?.Alive != true) { SetReceipt(new(new(message.ClientId, ChatMessageState.Uncertain), digest)); return new(message.ClientId, ChatMessageState.Uncertain); }
        SetReceipt(new(new(message.ClientId, ChatMessageState.Sent), digest)); Publish(new(0, "accepted", ClientId: message.ClientId));
        return new(message.ClientId, ChatMessageState.Sent);
      }
      finally { gate.Release(); }
    }
    catch (Exception ex) when (ex is IOException or InvalidOperationException or TimeoutException or OperationCanceledException)
    {
      await gate.WaitAsync();
      try { SetReceipt(new(new(message.ClientId, ChatMessageState.Uncertain), digest)); return new(message.ClientId, ChatMessageState.Uncertain); }
      finally { gate.Release(); }
    }
  }
  private async ValueTask InterruptAsync(CancellationToken ct)
  {
    await sends.WaitAsync(ct);
    try
    {
      var target = connection; var client = activeClient;
      if (Exec || target?.Alive != true)
      {
        if (target is not null) { await target.DisposeAsync(); connection = null; }
        await ReceiveAsync(new(0, "complete", Text: "Stopped", ClientId: client)); return;
      }
      interrupting = true; var revision = Interlocked.Increment(ref interruptRevision);
      try { await target.InterruptAsync(ct); }
      catch (Exception ex) when (ex is IOException or InvalidOperationException) { }
      _ = FinishUnresponsiveStopAsync(target, client, revision);
    }
    finally { sends.Release(); }
  }
  private async Task FinishUnresponsiveStopAsync(ChatCliConnection target, string? client, long revision)
  {
    try
    {
      await Task.Delay(TimeSpan.FromSeconds(15), stopping.Token); await sends.WaitAsync(stopping.Token);
      try
      {
        long boundary; await gate.WaitAsync(stopping.Token);
        try
        {
          if (!interrupting || activeClient != client || !ReferenceEquals(connection, target) || Volatile.Read(ref interruptRevision) != revision) return;
          boundary = journal.Sequence;
        }
        finally { gate.Release(); }
        // New turns cannot enter while this exact owned CLI is being stopped.
        await target.DisposeAsync(); connection = null;
        await gate.WaitAsync(stopping.Token);
        try
        {
          interrupting = false;
          if (!journal.Signals.Any(s => s.Sequence > boundary && s.ClientId == client && s.Kind is "complete" or "error"))
            Publish(new(0, "complete", Text: "Stopped", ClientId: client));
        }
        finally { gate.Release(); }
      }
      finally { sends.Release(); }
    }
    catch (OperationCanceledException) when (stopping.IsCancellationRequested) { }
    catch (Exception ex) when (ex is IOException or InvalidOperationException) { }
  }
  private async Task ServeAsync(NamedPipeServerStream pipe, CancellationToken ct)
  {
    await using (pipe)
    {
      Guid? watcherId = null;
      try
      {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(60));
        var request = await KeeperWire.ReadAsync<ChatWorkerRequest>(pipe, cancellationToken: deadline.Token);
        if (request.Key != Key || !CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(request.Secret), Encoding.UTF8.GetBytes(Convert.ToBase64String(credential.Span)))) return;
        switch (request.Operation)
        {
          case "snapshot":
            ChatWorkerState snapshot; await gate.WaitAsync(ct); try { snapshot = Snapshot(); } finally { gate.Release(); }
            await KeeperWire.WriteAsync(pipe, new ChatWorkerReply(Snapshot: snapshot, Success: true), true, ct); break;
          case "watch":
            ChatSignal[] initial; var channel = Channel.CreateBounded<ChatSignal>(256);
            await gate.WaitAsync(ct);
            try { watcherId = Guid.NewGuid(); watchers[watcherId.Value] = channel; initial = journal.Signals.Where(s => s.Sequence > request.After).ToArray(); }
            finally { gate.Release(); }
            foreach (var signal in initial) await KeeperWire.WriteAsync(pipe, new ChatWorkerReply(Signal: signal), true, ct);
            using (var attached = CancellationTokenSource.CreateLinkedTokenSource(ct))
            {
              async Task Disconnected()
              { try { var count = await pipe.ReadAsync(new byte[1], attached.Token); if (count >= 0) attached.Cancel(); } catch (Exception ex) when (ex is IOException or OperationCanceledException) { } finally { attached.Cancel(); } }
              var disconnected = Disconnected();
              try { await foreach (var signal in channel.Reader.ReadAllAsync(attached.Token)) await KeeperWire.WriteAsync(pipe, new ChatWorkerReply(Signal: signal), true, attached.Token); }
              finally { attached.Cancel(); await disconnected; }
            }
            break;
          case "send":
            ChatDelivery delivery; await sends.WaitAsync(deadline.Token);
            try { delivery = await SendAsync(request.Message ?? throw new ArgumentException(), deadline.Token); }
            finally { sends.Release(); }
            await KeeperWire.WriteAsync(pipe, new ChatWorkerReply(Delivery: delivery, Success: true), true, ct); break;
          case "answer":
            ChatSignal approval;
            await gate.WaitAsync(ct);
            try
            {
              approval = journal.Signals.LastOrDefault(s => s.Kind == "approval" && s.Id == request.RequestId) ?? throw new InvalidOperationException();
              if (journal.Signals.Any(s => s.Kind is "approvalResolved" or "approvalSending" && s.Id == request.RequestId)) throw new InvalidOperationException();
              // Reserve this exact approval before the pipe write. Lost replies
              // never grant twice, even when the UI also reconnects.
              Publish(new(0, "approvalSending", approval.Id, "Sending answer…"));
            }
            finally { gate.Release(); }
            await connection!.AnswerAsync(approval.Id, request.Allow, approval.Data ?? throw new InvalidOperationException(), ct);
            await ReceiveAsync(new(0, "approvalResolved", approval.Id, request.Allow ? "Allowed" : "Refused"));
            await KeeperWire.WriteAsync(pipe, new ChatWorkerReply(Success: true), true, ct); break;
          case "interrupt":
            await InterruptAsync(ct);
            await KeeperWire.WriteAsync(pipe, new ChatWorkerReply(Success: true), true, ct); break;
          case "quit":
            await KeeperWire.WriteAsync(pipe, new ChatWorkerReply(Success: true), true, ct); stopping.Cancel(); break;
        }
      }
      catch (Exception ex) when (ex is IOException or OperationCanceledException or ArgumentException or InvalidOperationException or TimeoutException)
      {
        try { await KeeperWire.WriteAsync(pipe, new ChatWorkerReply(Problem: "This chat needs to reconnect. Your messages are kept."), true, ct); }
        catch (Exception e) when (e is IOException or OperationCanceledException or ObjectDisposedException) { }
      }
      finally { if (watcherId is { } id) watchers.TryRemove(id, out _); }
    }
  }
  // W4 calls this before ordinary keeper argument parsing. Bootstrap stays in the
  // root-scoped Windows vault, never in argv or a displayed launch plan.
  public static async ValueTask<bool> TryRunAsync(string[] args, CancellationToken ct = default)
  {
    var index = Array.IndexOf(args, "--chat-worker"); if (index < 0) return false;
    if (index != args.Length - 2) throw new ArgumentException("Choose a valid chat worker.");
    var root = AppDataRoot.FromArguments(args[..index]); var key = WorkerPaths.Key(args[index + 1]);
    var plain = new CurrentUserDpapi(root).Unprotect(File.ReadAllBytes(ChatWorkerPaths.FileFor(root, key, ".launch")));
    ChatWorkerPlan plan;
    try { plan = JsonSerializer.Deserialize<ChatWorkerPlan>(plain) ?? throw new IOException(); }
    finally { CryptographicOperations.ZeroMemory(plain); }
    if (plan.Chat.CreationKey != key) throw new IOException("This chat worker belongs to another launch.");
    ChatWorkerContainment.AttachCurrentWorker();
    await new ChatPipeWorker(root, plan, KeeperCredentials.GetOrCreate(root)).RunAsync(ct); return true;
  }
}
