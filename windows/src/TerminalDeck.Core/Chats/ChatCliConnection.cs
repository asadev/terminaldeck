using System.Diagnostics;
using System.Text;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.Core.Chats;

// The keeper worker owns this connection. UI disposal only detaches its watcher.
public sealed class ChatCliConnection(ChatRecord chat, IChatHistory media, ProcessLaunch launch,
  Func<ChatSignal, ValueTask> receive, bool codexAppServer = false, object[]? mcpServers = null) : IAsyncDisposable
{
  private readonly ChatLineProtocol protocol = new(chat, media, codexAppServer, mcpServers);
  private readonly SemaphoreSlim writeGate = new(1);
  private readonly object protocolGate = new();
  private readonly CancellationTokenSource lifetime = new();
  private readonly TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
  private Process? process;
  private Task? pump;
  private Task? diagnostics;
  private string stderr = "";
  private bool sawTerminalSignal;
  private string? activeClientId;
  private readonly string connectionId = Guid.NewGuid().ToString("N");
  private readonly Dictionary<string, (string Raw, string? Client)> approvals = [];
  public Task Completion => pump ?? Task.CompletedTask;
  private int readerFailed;
  public bool Alive => Volatile.Read(ref readerFailed) == 0 && process is { HasExited: false };
  public async ValueTask StartAsync(CancellationToken cancellationToken = default)
  {
    if (process is not null) throw new InvalidOperationException("This chat connection has already started.");
    var start = new ProcessStartInfo(launch.Executable) { WorkingDirectory = launch.WorkingDirectory,
      UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true,
      StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false) };
    start.Environment.Clear(); foreach (var pair in launch.Environment) start.Environment[pair.Key] = pair.Value;
    foreach (var argument in launch.Arguments) start.ArgumentList.Add(argument);
    process = new Process { StartInfo = start };
    if (!process.Start()) throw new IOException("The coding AI could not start.");
    diagnostics = ReadDiagnosticsAsync(); pump = PumpAsync();
    var begin = protocol.Begin();
    if (begin is null) ready.TrySetResult(); else await WriteLineAsync(begin, cancellationToken);
  }
  public async ValueTask SendAsync(ChatMessage message, CancellationToken cancellationToken = default)
  {
    activeClientId = message.ClientId;
    await ready.Task.WaitAsync(TimeSpan.FromSeconds(45), cancellationToken); sawTerminalSignal = false;
    string line; lock (protocolGate) { approvals.Clear(); line = protocol.User(message); }
    await WriteLineAsync(line, cancellationToken);
  }
  public async ValueTask SendExecAsync(ChatMessage message, CancellationToken cancellationToken = default)
  {
    if (!Alive) throw new IOException("This coding AI has stopped.");
    activeClientId = message.ClientId; sawTerminalSignal = false;
    // exec has no interactive approval channel. Its prompt is stdin, never argv.
    await writeGate.WaitAsync(cancellationToken);
    try { await process!.StandardInput.WriteAsync(ChatRichContent.Prompt(chat, message.Text).AsMemory(), cancellationToken); await process.StandardInput.FlushAsync(cancellationToken); process.StandardInput.Close(); }
    finally { writeGate.Release(); }
  }
  public ValueTask AnswerAsync(string requestId, bool allow, System.Text.Json.JsonElement input, CancellationToken cancellationToken = default)
  {
    string line; lock (protocolGate)
    {
      if (!approvals.TryGetValue(requestId, out var source) || source.Client != activeClientId) throw new InvalidOperationException("That approval is no longer waiting.");
      line = protocol.Answer(source.Raw, allow, input);
    }
    return WriteLineAsync(line, cancellationToken);
  }
  public ValueTask InterruptAsync(CancellationToken cancellationToken = default)
  { string line; lock (protocolGate) line = protocol.Interrupt(); return WriteLineAsync(line, cancellationToken); }
  private async ValueTask WriteLineAsync(string line, CancellationToken ct)
  {
    await writeGate.WaitAsync(ct);
    try
    {
      if (!Alive) throw new IOException("This coding AI has stopped.");
      await process!.StandardInput.WriteLineAsync(line.AsMemory(), ct); await process.StandardInput.FlushAsync(ct);
    }
    finally { writeGate.Release(); }
  }
  private async Task PumpAsync()
  {
    try
    {
      await foreach (var line in Lines(process!.StandardOutput, lifetime.Token))
      {
        ChatProtocolUpdate update; lock (protocolGate) update = protocol.Receive(line);
        foreach (var output in update.Writes) await WriteLineAsync(output, lifetime.Token);
        foreach (var signal in update.Signals)
        {
          if (signal.Kind is "error" or "complete") sawTerminalSignal = true;
          if (signal.Kind == "error" && !ready.Task.IsCompleted) ready.TrySetException(new IOException("The coding AI could not start this chat."));
          if (protocol.IsRpc && !ready.Task.IsCompletedSuccessfully && signal.Kind is "textDelta" or "message" or "toolCall" or "toolResult") continue;
          ChatSignal identified; lock (protocolGate) identified = Identify(signal);
          await receive(identified);
        }
        if (update.Ready) ready.TrySetResult();
      }
      await process.WaitForExitAsync(lifetime.Token);
      if (diagnostics is not null) await diagnostics;
      if (!sawTerminalSignal) await receive(new(0, "error", Text: ChatErrors.FromProvider(chat.Definition.Provider, stderr), ClientId: activeClientId));
      await receive(new(0, "exit", Text: "The coding AI stopped.", ClientId: activeClientId));
      ready.TrySetException(new IOException("The coding AI stopped before this chat was ready."));
    }
    catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { ready.TrySetCanceled(); }
    catch (Exception ex) when (ex is IOException or InvalidOperationException or System.Text.Json.JsonException)
    {
      // A running process without a reader cannot receive another turn. Retire
      // it before publishing recovery state, so resuming cannot duplicate work.
      Interlocked.Exchange(ref readerFailed, 1);
      ready.TrySetException(new IOException("The chat connection ended."));
      if (process is { HasExited: false }) { await LetSignInRenewalFinishAsync(); if (!process.HasExited) process.Kill(entireProcessTree: true); await process.WaitForExitAsync(); }
      await receive(new(0, "connectionLost", Text: "The chat connection ended. This message may have reached the coding AI. Your messages are kept.", ClientId: activeClientId));
    }
  }
  private ChatSignal Identify(ChatSignal signal)
  {
    var client = signal.ClientId ?? activeClientId; var scope = client ?? connectionId; var id = signal.Id;
    if (signal.Kind is "approval" or "approvalResolved")
    {
      id = connectionId + ":" + scope + ":" + signal.Id;
      if (signal.Kind == "approval") approvals[id] = (signal.Id, client);
      else approvals.Remove(id);
    }
    else if (signal.Kind is "textDelta" or "message" or "toolCall" or "toolInputDelta" or "toolResult" or "reasoningDelta" or "reasoning" or "requestStarted" or "requestUsage" or "compaction") id = scope + ":" + (id.Length > 0 ? id : "message");
    return signal with { Id = id, ClientId = client };
  }
  private async Task ReadDiagnosticsAsync()
  {
    try
    {
      var buffer = new char[2048]; int count;
      while ((count = await process!.StandardError.ReadAsync(buffer, lifetime.Token)) > 0)
      { stderr += new string(buffer, 0, count); if (stderr.Length > 8192) stderr = stderr[^8192..]; }
    }
    catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
  }
  public static async IAsyncEnumerable<string> Lines(TextReader reader, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct)
  {
    var buffer = new char[4096]; var line = new StringBuilder(); int count;
    while ((count = await reader.ReadAsync(buffer, ct)) > 0)
    {
      for (var i = 0; i < count; i++)
      {
        if (buffer[i] == '\n') { yield return line.ToString().TrimEnd('\r'); line.Clear(); }
        else { line.Append(buffer[i]); if (line.Length > ChatLineProtocol.MaximumLineCharacters) throw new IOException("The coding AI returned a line that is too large."); }
      }
    }
    if (line.Length > 0) yield return line.ToString();
  }
  // Stopping Claude between its sign-in renewal's server call and save blanks the
  // login (saba-pc, 1 Nov). Stop and update keep their meaning; they only wait for
  // a renewal already under way (Claude's own lock, at most SignInRenewal.Patience).
  private Task LetSignInRenewalFinishAsync() =>
    TerminalDeck.Core.Accounts.SignInRenewal.WaitAsync(TerminalDeck.Core.Accounts.SignInRenewal.ConfigFolder(chat.Definition.Provider, launch.Environment), TerminalDeck.Core.Accounts.SignInRenewal.Patience);
  public async ValueTask DisposeAsync()
  {
    lifetime.Cancel();
    if (process is not null)
    {
      if (!process.HasExited) { await LetSignInRenewalFinishAsync(); if (!process.HasExited) process.Kill(entireProcessTree: true); }
      if (pump is not null) await pump;
      if (diagnostics is not null) await diagnostics;
      process.Dispose();
    }
    lifetime.Dispose(); writeGate.Dispose();
  }
}
