using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Integration;

public sealed record HootToolRequest(string Secret, string ChatId)
{
  public override string ToString() => "<private Hoot tool request>";
}
public sealed record HootToolReply(bool Ready);
public sealed record ChatToolConnection(string Url, string Token)
{
  public override string ToString() => "<private chat tool connection>";
}

// The keeper asks the attached window to provision the exact backing chat. No
// credential is placed in the transcript, argv, or a globally shared AI home.
public sealed class HootToolConnection(AppDataRoot root, ReadOnlyMemory<byte> credential)
{
  public static string PipeName(AppDataRoot root) => "terminaldeck-hoot-tools-" + root.NamespaceId;
  public async ValueTask PrepareAsync(string chatId, CancellationToken ct)
  {
    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(10));
    await using var pipe = new NamedPipeClientStream(".", PipeName(root), PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
    await pipe.ConnectAsync(5000, deadline.Token);
    await KeeperWire.WriteAsync(pipe, new HootToolRequest(Convert.ToBase64String(credential.Span), chatId), true, deadline.Token);
    var reply = await KeeperWire.ReadAsync<HootToolReply>(pipe, cancellationToken: deadline.Token);
    if (!reply.Ready) throw new IOException("Hoot's app tools are not connected. Reopen the window before continuing.");
  }
  private static string FileName(AppDataRoot root, string id)
  {
    if (!Guid.TryParseExact(id, "D", out _)) throw new ArgumentException("Choose a chat identity.");
    var directory = Path.Combine(root.DirectoryPath, "mcp", "chat-tools"); WindowsPrivateDirectory.Ensure(directory);
    return Path.Combine(directory, id + ".bin");
  }
  public static void Save(AppDataRoot root, string id, ChatToolConnection connection)
  {
    var bytes = JsonSerializer.SerializeToUtf8Bytes(connection);
    try { File.WriteAllBytes(FileName(root, id), new CurrentUserDpapi(root).Protect(bytes)); }
    finally { CryptographicOperations.ZeroMemory(bytes); }
  }
  public static ChatToolConnection? Read(AppDataRoot root, string id)
  {
    var path = FileName(root, id); if (!File.Exists(path)) return null;
    var bytes = new CurrentUserDpapi(root).Unprotect(File.ReadAllBytes(path));
    try
    {
      var value = JsonSerializer.Deserialize<ChatToolConnection>(bytes) ?? throw new IOException("The chat tool connection is missing.");
      var uri = new Uri(value.Url);
      if (uri.Scheme != "http" || uri.Host != "127.0.0.1" || uri.AbsolutePath != "/mcp" || value.Token.Length is < 32 or > 256)
        throw new IOException("The chat tool connection is unusable.");
      return value;
    }
    finally { CryptographicOperations.ZeroMemory(bytes); }
  }
}

public sealed class HootToolConnectionServer(AppDataRoot root, ReadOnlyMemory<byte> credential,
  Func<string, CancellationToken, ValueTask> prepare) : IAsyncDisposable
{
  private readonly CancellationTokenSource lifetime = new();
  private Task? running;
  public void Start() => running = RunAsync();
  private async Task RunAsync()
  {
    var clients = new ConcurrentDictionary<Guid, Task>(); using var slots = new SemaphoreSlim(4);
    try
    {
      while (!lifetime.IsCancellationRequested)
      {
        await slots.WaitAsync(lifetime.Token);
        var pipe = new NamedPipeServerStream(HootToolConnection.PipeName(root), PipeDirection.InOut, 4, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
        try { await pipe.WaitForConnectionAsync(lifetime.Token); }
        catch { pipe.Dispose(); slots.Release(); throw; }
        var id = Guid.NewGuid();
        var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        async Task Serve()
        {
          await ready.Task;
          try
          {
            await using (pipe)
            {
              using var deadline = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); deadline.CancelAfter(TimeSpan.FromSeconds(15));
              var request = await KeeperWire.ReadAsync<HootToolRequest>(pipe, cancellationToken: deadline.Token);
              if (request.Secret.Length > 256 || !CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(request.Secret), Encoding.UTF8.GetBytes(Convert.ToBase64String(credential.Span)))) return;
              await prepare(request.ChatId, deadline.Token);
              await KeeperWire.WriteAsync(pipe, new HootToolReply(true), true, deadline.Token);
            }
          }
          catch (Exception ex) when (ex is IOException or OperationCanceledException or ArgumentException or InvalidOperationException) { }
          finally { clients.TryRemove(id, out _); slots.Release(); }
        }
        clients[id] = Serve(); ready.SetResult();
      }
    }
    catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
    finally { await Task.WhenAll(clients.Values); }
  }
  public async ValueTask DisposeAsync() { lifetime.Cancel(); if (running is not null) await running; lifetime.Dispose(); }
}
