using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Chats;

public sealed class ChatServiceRequest
{
  public required string Secret { get; init; }
  public required string Operation { get; init; }
  public string? Id { get; init; }
  public string? Provider { get; init; }
  public string? Folder { get; init; }
  public string? AccountId { get; init; }
  public string? ClientId { get; init; }
  public string? Text { get; init; }
  public ChatDefinition? Definition { get; init; }
  public string? ConversationId { get; init; }
  public bool CustomTitle { get; init; }
  public ChatOptions? Options { get; init; }
  public ChatMedia[]? Media { get; init; }
  public bool Allow { get; init; }
  public JsonElement? Upload { get; init; }
  public override string ToString() => "<private chat service request>";
}
public sealed record ChatServiceReply(ChatRecord? Chat = null, ChatRecord[]? Chats = null, AccountProfile[]? Accounts = null,
  ProviderModel[]? Models = null, ChatMedia? Media = null, byte[]? Bytes = null, JsonElement? Upload = null, string? Problem = null, bool CanSwitch = false);

// Host this beside the existing keeper pipe. All queue/history work therefore
// continues in the keeper even when every app window has detached.
public sealed class ChatSessionsPipeServer(AppDataRoot root, IChatSessions chats, ReadOnlyMemory<byte> credential)
{
  public static string PipeName(AppDataRoot root) => "terminaldeck-chats-" + root.NamespaceId;
  private readonly ChatImageUploads images = new(chats, 1_400_000);
  public async Task RunAsync(CancellationToken ct)
  {
    WindowsPrivateDirectory.Ensure(Path.Combine(root.DirectoryPath, "chats"));
    WindowsPrivateDirectory.Ensure(ChatWorkerPaths.DirectoryFor(root));
    using var ownership = new FileStream(Path.Combine(ChatWorkerPaths.DirectoryFor(root), "service.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.Read);
    var clients = new ConcurrentDictionary<Guid, Task>(); using var slots = new SemaphoreSlim(16);
    try
    {
      while (!ct.IsCancellationRequested)
      {
        await slots.WaitAsync(ct); NamedPipeServerStream? pipe = null;
        try
        {
          pipe = new(PipeName(root), PipeDirection.InOut, 16, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly, 65536, 65536);
          await pipe.WaitForConnectionAsync(ct); var accepted = pipe; var id = Guid.NewGuid(); var start = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
          async Task Serve()
          { await start.Task; try { await ServeAsync(accepted, ct); } finally { clients.TryRemove(id, out _); slots.Release(); } }
          clients[id] = Serve(); start.SetResult(); pipe = null;
        }
        catch { pipe?.Dispose(); slots.Release(); throw; }
      }
    }
    catch (OperationCanceledException) when (ct.IsCancellationRequested) { }
    finally { await Task.WhenAll(clients.Values); images.Dispose(); }
  }
  private ChatServiceReply Snapshot(string id) => new(Chat: chats.Get(id), Accounts: chats.Accounts(id).ToArray());
  private async Task ServeAsync(NamedPipeServerStream pipe, CancellationToken ct)
  {
    await using (pipe)
    {
      try
      {
        using var requestDeadline = CancellationTokenSource.CreateLinkedTokenSource(ct); requestDeadline.CancelAfter(TimeSpan.FromSeconds(70));
        var request = await KeeperWire.ReadAsync<ChatServiceRequest>(pipe, cancellationToken: requestDeadline.Token);
        if (!CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(request.Secret), Encoding.UTF8.GetBytes(Convert.ToBase64String(credential.Span)))) return;
        if (request.Operation == "list")
        {
          var rows = chats.List().ToArray();
          await KeeperWire.WriteAsync(pipe, new ChatServiceReply(Chats: rows, Accounts: rows.SelectMany(c => chats.Accounts(c.Definition.Id)).DistinctBy(a => a.Id).ToArray()), true, ct); return;
        }
        if (request.Operation == "create")
        {
          var created = request.Definition is { } definition
            ? request.CustomTitle && chats is ChatSessions concrete ? await concrete.CreateAsync(definition, customTitle: true, request.ConversationId, requestDeadline.Token)
              : await chats.CreateAsync(definition, request.ConversationId, requestDeadline.Token)
            : await chats.CreateAsync(request.Provider ?? "", request.Folder ?? "", request.AccountId ?? "", request.Options, requestDeadline.Token);
          await KeeperWire.WriteAsync(pipe, Snapshot(created.Definition.Id), true, ct); return;
        }
        var id = request.Id ?? throw new ArgumentException("Choose a chat.");
        if (request.Operation == "watch")
        {
          using var attached = CancellationTokenSource.CreateLinkedTokenSource(ct);
          async Task Disconnected()
          { try { var count = await pipe.ReadAsync(new byte[1], attached.Token); if (count >= 0) attached.Cancel(); } catch (Exception ex) when (ex is IOException or OperationCanceledException) { } finally { attached.Cancel(); } }
          var disconnected = Disconnected();
          try { await foreach (var chat in chats.WatchAsync(id, attached.Token)) await KeeperWire.WriteAsync(pipe, new ChatServiceReply(Chat: chat, Accounts: chats.Accounts(id).ToArray()), true, attached.Token); }
          finally { attached.Cancel(); await disconnected; }
          return;
        }
        ChatServiceReply? reply = null;
        switch (request.Operation)
        {
          case "get": break;
          case "send": await chats.SendAsync(id, request.ClientId ?? "", request.Text ?? "", request.Media, requestDeadline.Token); break;
          case "sendNow": await chats.SendNowAsync(id, request.ClientId ?? "", requestDeadline.Token); break;
          case "edit": await chats.EditQueuedAsync(id, request.ClientId ?? "", request.Text ?? "", requestDeadline.Token); break;
          case "remove": await chats.RemoveQueuedAsync(id, request.ClientId ?? "", requestDeadline.Token); break;
          case "answer": await chats.AnswerAsync(id, request.ClientId ?? "", request.Allow, requestDeadline.Token); break;
          case "continue": await chats.ContinueWithoutResendingAsync(id, requestDeadline.Token); break;
          case "end": await chats.EndAsync(id, requestDeadline.Token); break;
          case "stop": await chats.StopAsync(id, requestDeadline.Token); break;
          case "retry": await chats.RetryAsync(id, requestDeadline.Token); break;
          case "reconnect": await chats.ReconnectAsync(id, requestDeadline.Token); break;
          case "branch": reply = new(Chat: await chats.BranchAsync(id, request.ClientId, request.Allow, requestDeadline.Token, request.Text)); break;
          case "rename": await chats.RenameAsync(id, request.Text ?? "", requestDeadline.Token); break;
          case "permission":
            if (!Enum.TryParse<AiPermissionMode>(request.Text, true, out var mode)) throw new ArgumentException("Choose a supported permission mode.");
            await chats.SetPermissionAsync(id, mode, requestDeadline.Token); break;
          case "options": await chats.SetOptionsAsync(id, request.Options ?? new(), requestDeadline.Token); break;
          case "account": await chats.SetAccountAsync(id, request.Text ?? "", requestDeadline.Token); break;
          case "accountPlan": reply = new(CanSwitch: await chats.CanSwitchAccountAsync(id, request.Text ?? "", requestDeadline.Token)); break;
          case "signIn": await chats.SignInAsync(id, requestDeadline.Token); break;
          case "models": reply = new(Chat: chats.Get(id), Models: (await chats.ModelsAsync(id, requestDeadline.Token)).ToArray(), Accounts: chats.Accounts(id).ToArray()); break;
          case "imageRead": reply = new(Bytes: chats.ReadImage(id, request.Media?.Single() ?? throw new ArgumentException())); break;
          case "imageUpload": reply = new(Upload: JsonSerializer.SerializeToElement(await images.ApplyAsync(id, "local-app", request.Upload ?? throw new ArgumentException(), requestDeadline.Token))); break;
          default: throw new ArgumentException("Choose a chat action.");
        }
        await KeeperWire.WriteAsync(pipe, reply ?? Snapshot(id), true, ct);
      }
      catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException or OperationCanceledException or JsonException or KeyNotFoundException)
      {
        // Never release paths, process diagnostics, or provider errors through IPC.
        var problem = ex is KeyNotFoundException ? "This chat was not found." : ex is ArgumentException or InvalidOperationException && ex is not JsonException ? ex.Message : "This chat needs to reconnect. Your messages are kept.";
        try { await KeeperWire.WriteAsync(pipe, new ChatServiceReply(Problem: problem), true, ct); }
        catch (Exception e) when (e is IOException or OperationCanceledException or ObjectDisposedException) { }
      }
    }
  }
}

// App-side implementation of the single public chat interface. Initial state is
// fetched before showing a page; later updates come from the keeper's watcher.
public sealed class WindowsChatSessionsClient : IChatSessions
{
  private readonly AppDataRoot root;
  public AppDataRoot DataRoot => root;
  private readonly string secret;
  public event Action? Changed;
  public Func<string, string, CancellationToken, ValueTask>? SignInRequested { get; set; }
  private readonly ConcurrentDictionary<string, ChatRecord> records = new();
  private readonly ConcurrentDictionary<string, AccountProfile> accounts = new();
  private WindowsChatSessionsClient(AppDataRoot root, ReadOnlyMemory<byte> credential) { this.root = root; secret = Convert.ToBase64String(credential.Span); }
  public static async ValueTask<WindowsChatSessionsClient> ConnectAsync(AppDataRoot root, ReadOnlyMemory<byte> credential, CancellationToken ct = default)
  {
    var client = new WindowsChatSessionsClient(root, credential); await client.RefreshAsync(ct); return client;
  }
  private async ValueTask<NamedPipeClientStream> OpenAsync(CancellationToken ct)
  {
    var pipe = new NamedPipeClientStream(".", ChatSessionsPipeServer.PipeName(root), PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
    try { await pipe.ConnectAsync(3000, ct); return pipe; } catch { await pipe.DisposeAsync(); throw; }
  }
  private void Apply(ChatServiceReply reply)
  {
    if (reply.Chat is { } chat) records[chat.Definition.Id] = chat;
    foreach (var item in reply.Chats ?? []) records[item.Definition.Id] = item;
    foreach (var account in reply.Accounts ?? []) accounts[account.Id] = account;
    Changed?.Invoke();
  }
  private async ValueTask<ChatServiceReply> CallAsync(ChatServiceRequest request, CancellationToken ct)
  {
    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(75));
    await using var pipe = await OpenAsync(deadline.Token); await KeeperWire.WriteAsync(pipe, request, cancellationToken: deadline.Token);
    var reply = await KeeperWire.ReadAsync<ChatServiceReply>(pipe, true, deadline.Token);
    if (reply.Problem is not null) throw new InvalidOperationException(reply.Problem); Apply(reply); return reply;
  }
  public IReadOnlyList<ChatRecord> List() => records.Values.ToArray();
  public ChatRecord Get(string id) => records.GetValueOrDefault(id) ?? throw new KeyNotFoundException("This chat was not found.");
  public async ValueTask<ChatRecord> ReadAsync(string id, CancellationToken cancellationToken = default) => (await CallAsync(new() { Secret = secret, Operation = "get", Id = id }, cancellationToken)).Chat ?? throw new IOException("This chat snapshot was not returned.");
  public ValueTask<ChatRecord> CreateAsync(ChatDefinition definition, string? conversationId = null, CancellationToken cancellationToken = default) =>
    CreateAsync(definition, customTitle: false, conversationId, cancellationToken);
  // customTitle: the person named it in New session; the keeper keeps that name on the first message.
  public async ValueTask<ChatRecord> CreateAsync(ChatDefinition definition, bool customTitle, string? conversationId = null, CancellationToken cancellationToken = default) =>
    (await CallAsync(new() { Secret = secret, Operation = "create", Definition = definition, ConversationId = conversationId, CustomTitle = customTitle }, cancellationToken)).Chat ?? throw new IOException("This chat was not created.");
  public async ValueTask<ChatRecord> CreateAsync(string provider, string folder, string accountId, ChatOptions? options = null, CancellationToken cancellationToken = default) =>
    (await CallAsync(new() { Secret = secret, Operation = "create", Provider = provider, Folder = folder, AccountId = accountId, Options = options }, cancellationToken)).Chat ?? throw new IOException("This chat was not created.");
  private async ValueTask ActionAsync(string operation, string id, CancellationToken ct, string? clientId = null, string? text = null, ChatMedia[]? media = null, ChatOptions? options = null, bool allow = false) =>
    _ = await CallAsync(new() { Secret = secret, Operation = operation, Id = id, ClientId = clientId, Text = text, Media = media, Options = options, Allow = allow }, ct);
  public ValueTask SendAsync(string id, string clientId, string text, ChatMedia[]? media = null, CancellationToken cancellationToken = default) => ActionAsync("send", id, cancellationToken, clientId, text, media);
  public ValueTask SendNowAsync(string id, string clientId, CancellationToken cancellationToken = default) => ActionAsync("sendNow", id, cancellationToken, clientId);
  public ValueTask EditQueuedAsync(string id, string clientId, string text, CancellationToken cancellationToken = default) => ActionAsync("edit", id, cancellationToken, clientId, text);
  public ValueTask RemoveQueuedAsync(string id, string clientId, CancellationToken cancellationToken = default) => ActionAsync("remove", id, cancellationToken, clientId);
  public ValueTask AnswerAsync(string id, string requestId, bool allow, CancellationToken cancellationToken = default) => ActionAsync("answer", id, cancellationToken, requestId, allow: allow);
  public ValueTask StopAsync(string id, CancellationToken cancellationToken = default) => ActionAsync("stop", id, cancellationToken);
  public ValueTask ContinueWithoutResendingAsync(string id, CancellationToken cancellationToken = default) => ActionAsync("continue", id, cancellationToken);
  public ValueTask EndAsync(string id, CancellationToken cancellationToken = default) => ActionAsync("end", id, cancellationToken);
  public ValueTask RetryAsync(string id, CancellationToken cancellationToken = default) => ActionAsync("retry", id, cancellationToken);
  public ValueTask ReconnectAsync(string id, CancellationToken cancellationToken = default) => ActionAsync("reconnect", id, cancellationToken);
  public ValueTask SetOptionsAsync(string id, ChatOptions options, CancellationToken cancellationToken = default) => ActionAsync("options", id, cancellationToken, options: options);
  public async ValueTask<ChatRecord> BranchAsync(string id, string? messageId, bool rewind, CancellationToken ct = default, string? title = null) =>
    (await CallAsync(new() { Secret = secret, Operation = "branch", Id = id, ClientId = messageId, Allow = rewind, Text = title }, ct)).Chat ?? throw new IOException("The copied history was not returned.");
  public ValueTask RenameAsync(string id, string title, CancellationToken cancellationToken = default) => ActionAsync("rename", id, cancellationToken, text: title);
  public ValueTask SetPermissionAsync(string id, AiPermissionMode mode, CancellationToken cancellationToken = default) => ActionAsync("permission", id, cancellationToken, text: mode.ToString());
  public ValueTask SetAccountAsync(string id, string accountId, CancellationToken cancellationToken = default) => ActionAsync("account", id, cancellationToken, text: accountId);
  public async ValueTask<bool> CanSwitchAccountAsync(string id, string accountId, CancellationToken cancellationToken = default) =>
    (await CallAsync(new() { Secret = secret, Operation = "accountPlan", Id = id, Text = accountId }, cancellationToken)).CanSwitch;
  public async ValueTask SignInAsync(string id, CancellationToken cancellationToken = default)
  {
    if (SignInRequested is { } signIn)
    {
      var chat = Get(id);
      await signIn(chat.Definition.AccountId, chat.Definition.Cwd, cancellationToken);
      await RefreshAsync(cancellationToken);
    }
    else await ActionAsync("signIn", id, cancellationToken);
  }
  public IReadOnlyList<AccountProfile> Accounts(string id) => accounts.Values.Where(a => a.Provider == Get(id).Definition.Provider).ToArray();
  public async ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(string id, CancellationToken cancellationToken = default) =>
    (await CallAsync(new() { Secret = secret, Operation = "models", Id = id }, cancellationToken)).Models ?? [];
  private async ValueTask<JsonElement> UploadAsync(string id, object command, CancellationToken ct) =>
    (await CallAsync(new() { Secret = secret, Operation = "imageUpload", Id = id, Upload = JsonSerializer.SerializeToElement(command) }, ct)).Upload ?? throw new IOException("The image upload did not finish.");
  public async ValueTask<ChatMedia> AddImageAsync(string id, string name, string mimeType, ReadOnlyMemory<byte> bytes, int width, int height, CancellationToken cancellationToken = default)
  {
    if (bytes.Length is <= 0 or > 8 * 1024 * 1024) throw new ArgumentException("Choose an image up to 8 MB.");
    var uploadId = Guid.NewGuid().ToString();
    await UploadAsync(id, new { action = "imageBegin", uploadId, name, mimeType, width, height }, cancellationToken);
    for (var offset = 0; offset < bytes.Length; offset += 768 * 1024)
      await UploadAsync(id, new { action = "imageChunk", uploadId, offset, data = Convert.ToBase64String(bytes.Slice(offset, Math.Min(768 * 1024, bytes.Length - offset)).Span) }, cancellationToken);
    var result = await UploadAsync(id, new { action = "imageFinish", uploadId }, cancellationToken);
    return result.GetProperty("media").Deserialize<ChatMedia>() ?? throw new IOException("The chat image did not save.");
  }
  public async ValueTask<byte[]> ReadImageAsync(string id, ChatMedia media, CancellationToken cancellationToken = default) =>
    (await CallAsync(new() { Secret = secret, Operation = "imageRead", Id = id, Media = [media] }, cancellationToken)).Bytes ?? throw new IOException("This image is unavailable.");
  public byte[] ReadImage(string id, ChatMedia media) => Task.Run(async () => await ReadImageAsync(id, media).ConfigureAwait(false)).GetAwaiter().GetResult();
  public async IAsyncEnumerable<ChatRecord> WatchAsync(string id, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken cancellationToken = default)
  {
    await using var pipe = await OpenAsync(cancellationToken);
    await KeeperWire.WriteAsync(pipe, new ChatServiceRequest { Secret = secret, Operation = "watch", Id = id }, cancellationToken: cancellationToken);
    while (!cancellationToken.IsCancellationRequested)
    {
      var reply = await KeeperWire.ReadAsync<ChatServiceReply>(pipe, true, cancellationToken);
      if (reply.Problem is not null) throw new IOException("This chat needs to reconnect."); Apply(reply);
      yield return reply.Chat ?? throw new IOException("The chat snapshot is missing.");
    }
  }
  public async ValueTask RefreshAsync(CancellationToken ct = default) => _ = await CallAsync(new() { Secret = secret, Operation = "list" }, ct);
  public async ValueTask RecoverAsync(CancellationToken cancellationToken = default)
  { await RefreshAsync(cancellationToken); foreach (var chat in List()) await ReconnectAsync(chat.Definition.Id, cancellationToken); }
}
