using System.Collections.Concurrent;
using System.Text.Json;

namespace TerminalDeck.Core.Servers;

public sealed record ServerSigninState(string ServerId, string SessionId, string Phase, string Message);
public sealed record ServerSigninRequest(SavedServer Server, ServerCodingTask Task, string SessionId, ServerCaller Caller)
{ public override string ToString() => "<private server sign-in attempt>"; }
public sealed record ServerSigninCapture(string? Address, bool Done, int ExitCode)
{ public override string ToString() => "<private sign-in capture>"; }
public sealed class ServerSigninPortBusy : IOException { public ServerSigninPortBusy() : base("The callback port is in use.") { } }
public interface IServerSigninForward : IAsyncDisposable { bool IsAlive { get; } }
public interface IServerSigninTransport
{
  ValueTask<ServerSigninCapture> CaptureAsync(ServerSigninRequest request, CancellationToken ct);
  ValueTask<IServerSigninForward> ForwardAsync(ServerSigninRequest request, int port, CancellationToken ct);
  ValueTask OpenBrowserAsync(Uri address, CancellationToken ct);
  ValueTask CleanupAsync(ServerSigninRequest request, CancellationToken ct);
  bool SessionRunning(ServerSigninRequest request);
  ValueTask StopOwnSessionAsync(ServerSigninRequest request, CancellationToken ct);
}
public static class ServerSigninAddress
{
  public static (Uri Address, int Port) Validate(string text)
  {
    if (text.Length is < 1 or > 8192 || text.Any(char.IsControl) || !Uri.TryCreate(text, UriKind.Absolute, out var address) || address.Scheme != "https" || !address.IsDefaultPort || address.UserInfo.Length != 0 || address.Fragment.Length != 0 || address.AbsolutePath != "/oauth/authorize" || address.Host is not ("claude.ai" or "console.anthropic.com" or "platform.claude.com")) throw new ServerRefusal("The coding AI returned an unsupported sign-in address. Continue in its terminal.");
    var fields = address.Query.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries).Select(s => s.Split('=', 2)).ToArray();
    var redirect = fields.Where(f => Uri.UnescapeDataString(f[0]) == "redirect_uri").ToArray();
    if (redirect.Length != 1 || redirect[0].Length != 2 || !Uri.TryCreate(Uri.UnescapeDataString(redirect[0][1]), UriKind.Absolute, out var callback) || callback.Scheme != "http" || callback.Host is not ("localhost" or "127.0.0.1") || callback.Port is < 1024 or > 65535 || callback.UserInfo.Length != 0 || callback.Query.Length != 0 || callback.Fragment.Length != 0 || callback.AbsolutePath is not ("/callback" or "/oauth/callback")) throw new ServerRefusal("The coding AI callback is not a supported loopback address. Continue in its terminal.");
    return (address, callback.Port);
  }
}

// Owns only explicit Claude sign-in attempts. Public state contains no URL,
// code, token, captured output or arbitrary remote command.
public sealed class ServerSigninAttempts(Func<string, ServerCaller, SavedServer> getServer, IServerSigninTransport transport, TimeProvider? clock = null) : IAsyncDisposable
{
  private sealed class Attempt(ServerSigninRequest request)
  {
    public ServerSigninRequest Request = request;
    public CancellationTokenSource Stop = new();
    public Task Work = Task.CompletedTask;
    public bool Finished;
  }
  private readonly TimeProvider time = clock ?? TimeProvider.System;
  private readonly ConcurrentDictionary<string, Attempt> attempts = new();
  private readonly ConcurrentDictionary<string, ServerSigninState> states = new();
  private int disposed;
  private readonly object gate = new();
  public event Action<ServerSigninState>? Changed;
  public ServerSigninState? State(string serverId) => states.GetValueOrDefault(serverId);
  public void Start(ServerSigninRequest request)
  {
    request.Task.Validate();
    if (request.Task.Provider != "claude" || request.Task.Action != "signin" || request.Task.AttemptId is null) throw new ServerRefusal("Choose an explicit Claude sign-in attempt.");
    lock (gate)
    {
      ObjectDisposedException.ThrowIf(Volatile.Read(ref disposed) != 0, this);
      var attempt = new Attempt(request);
      attempts.AddOrUpdate(request.Server.Id, attempt, (_, old) => { try { old.Stop.Cancel(); } catch (ObjectDisposedException) { } return attempt; });
      attempt.Work = Task.Run(() => RunAsync(attempt));
    }
  }
  private void Publish(ServerSigninRequest request, string phase, string message)
  {
    if (attempts.TryGetValue(request.Server.Id, out var current) && current.Request.Task.AttemptId != request.Task.AttemptId) return;
    var state = new ServerSigninState(request.Server.Id, request.SessionId, phase, message); states[request.Server.Id] = state;
    foreach (var listener in Changed?.GetInvocationList() ?? []) try { ((Action<ServerSigninState>)listener)(state); } catch (Exception) { }
  }
  private async ValueTask Current(ServerSigninRequest request, CancellationToken ct)
  {
    await request.Caller.RecheckAsync(ct);
    var current = getServer(request.Server.Id, request.Caller); ServerValidation.CanChange(current, request.Caller);
    if (JsonSerializer.Serialize(current) != JsonSerializer.Serialize(request.Server)) throw new ServerRefusal("This sign-in's server access changed.");
    if (!transport.SessionRunning(request)) throw new OperationCanceledException(ct);
  }
  private async Task RunAsync(Attempt attempt)
  {
    var request = attempt.Request; var ct = attempt.Stop.Token; IServerSigninForward? forward = null; var manual = !request.Server.DrivesBrowser;
    try
    {
      Publish(request, manual ? "manual" : "waiting", manual ? "Browser access is off for this server. Continue sign-in in its terminal." : "Waiting for Claude's sign-in address in the server terminal.");
      var deadline = time.GetUtcNow() + TimeSpan.FromMinutes(16); var captureDeadline = time.GetUtcNow() + TimeSpan.FromSeconds(25);
      while (time.GetUtcNow() < deadline)
      {
        await Current(request, ct);
        var capture = await transport.CaptureAsync(request, ct);
        if (capture.Done)
        {
          attempt.Finished = true;
          Publish(request, capture.ExitCode == 0 ? "done" : "failed", capture.ExitCode == 0 ? "Claude sign-in finished. Refresh Coding AIs to read the account status." : "Claude sign-in ended. Retry or continue in the server terminal."); return;
        }
        if (!manual && forward is null && capture.Address is { Length: > 0 } address)
        {
          try
          {
            var validated = ServerSigninAddress.Validate(address);
            for (var retry = 0; retry < 3; retry++)
            {
              await Current(request, ct);
              try { forward = await transport.ForwardAsync(request, validated.Port, ct); break; }
              catch (ServerSigninPortBusy) when (retry < 2) { await Task.Delay(TimeSpan.FromMilliseconds(250), time, ct); }
            }
            await Current(request, ct);
            if (!getServer(request.Server.Id, request.Caller).DrivesBrowser) throw new ServerRefusal("Browser access was retired.");
            if (forward?.IsAlive != true) throw new IOException("The callback forward did not open.");
            await transport.OpenBrowserAsync(validated.Address, ct);
            Publish(request, "browser", "Finish signing in in your browser. The private callback tunnel is ready.");
          }
          catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException)
          {
            if (forward is not null) { await forward.DisposeAsync(); forward = null; }
            manual = true; Publish(request, "manual", "Automatic sign-in could not open. Use the address and code shown in the server terminal.");
          }
        }
        if (!manual && forward is null && time.GetUtcNow() >= captureDeadline)
        { manual = true; Publish(request, "manual", "No browser address was captured. Continue using the address and code in the server terminal."); }
        if (forward is not null && !forward.IsAlive)
        { await forward.DisposeAsync(); forward = null; manual = true; Publish(request, "manual", "The callback tunnel closed. Continue in the server terminal or retry sign-in."); }
        await Task.Delay(TimeSpan.FromMilliseconds(500), time, ct);
      }
      Publish(request, "expired", "This sign-in attempt timed out. Start sign-in again.");
    }
    catch (OperationCanceledException) { Publish(request, "cancelled", "This sign-in attempt ended."); }
    catch (Exception ex) when (ex is IOException or InvalidOperationException or KeyNotFoundException or UnauthorizedAccessException)
    { Publish(request, "cancelled", "This sign-in attempt stopped because its connection or access changed."); }
    finally
    {
      if (forward is not null) await forward.DisposeAsync();
      if (!attempt.Finished)
        try { await transport.StopOwnSessionAsync(request, CancellationToken.None); } catch (Exception ex) when (ex is IOException or InvalidOperationException) { }
      try { await request.Caller.RecheckAsync(CancellationToken.None); var current = getServer(request.Server.Id, request.Caller); if (JsonSerializer.Serialize(current) == JsonSerializer.Serialize(request.Server)) await transport.CleanupAsync(request, CancellationToken.None); } catch (Exception ex) when (ex is IOException or InvalidOperationException or OperationCanceledException) { }
      ((ICollection<KeyValuePair<string, Attempt>>)attempts).Remove(new(request.Server.Id, attempt)); attempt.Stop.Dispose();
    }
  }
  public void ServerChanged(SavedServer server)
  {
    if (attempts.TryGetValue(server.Id, out var attempt) && JsonSerializer.Serialize(server) != JsonSerializer.Serialize(attempt.Request.Server))
      try { attempt.Stop.Cancel(); } catch (ObjectDisposedException) { }
  }
  public void RefreshSessions()
  {
    foreach (var attempt in attempts.Values)
      if (!transport.SessionRunning(attempt.Request)) try { attempt.Stop.Cancel(); } catch (ObjectDisposedException) { }
  }
  public async ValueTask DisposeAsync()
  {
    Attempt[] active;
    lock (gate)
    {
      if (Interlocked.Exchange(ref disposed, 1) != 0) return;
      active = attempts.Values.ToArray();
      foreach (var attempt in active) try { attempt.Stop.Cancel(); } catch (ObjectDisposedException) { }
    }
    await Task.WhenAll(active.Select(a => a.Work));
  }
}
