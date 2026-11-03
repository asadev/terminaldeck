using System.Diagnostics;
using System.Collections.Concurrent;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Servers;

namespace TerminalDeck.Platform.Windows.Servers;

public interface IServerSigninForwardStarter
{
  ValueTask<IServerSigninForward> StartAsync(ProcessLaunch launch, int port, CancellationToken ct);
}
public sealed class WindowsServerSigninTransport(WindowsOpenSshRuntime runtime,
  Func<ServerSigninRequest, bool> sessionRunning, Func<ServerSigninRequest, CancellationToken, ValueTask> stopOwnSession,
  Func<Uri, CancellationToken, ValueTask> openBrowser, IServerSigninForwardStarter? forwardStarter = null) : IServerSigninTransport
{
  private readonly ConcurrentDictionary<string, Lazy<Task<WindowsSigninCaptureWatch>>> watches = new();
  public bool SessionRunning(ServerSigninRequest request) => sessionRunning(request);
  public async ValueTask StopOwnSessionAsync(ServerSigninRequest request, CancellationToken ct)
  { await StopWatch(request); await stopOwnSession(request, ct); }
  public ValueTask OpenBrowserAsync(Uri address, CancellationToken ct) => openBrowser(address, ct);
  public async ValueTask<ServerSigninCapture> CaptureAsync(ServerSigninRequest request, CancellationToken ct)
  {
    var key = request.Task.AttemptId ?? throw new ServerRefusal("Choose a private sign-in attempt.");
    var watch = await watches.GetOrAdd(key, _ => new(() => StartWatch(request, ct))).Value;
    return watch.Read();
  }
  private async Task<WindowsSigninCaptureWatch> StartWatch(ServerSigninRequest request, CancellationToken ct)
  {
    var lease = await runtime.PrepareTerminalAsync(request.Server, ct);
    try
    {
      var args = runtime.Arguments(request.Server, ServerSigninScripts.Watch(request.Task.AttemptId!).Script);
      if (lease.Launch.Arguments.Contains("BatchMode=yes")) args = new[] { "-o", "BatchMode=yes" }.Concat(args).ToArray();
      return new(lease.Launch with { Arguments = args }, lease, ct);
    }
    catch (System.ComponentModel.Win32Exception) { await lease.DisposeAsync(); throw new IOException("The private sign-in watch could not start."); }
    catch { await lease.DisposeAsync(); throw; }
  }
  private async ValueTask StopWatch(ServerSigninRequest request)
  {
    if (request.Task.AttemptId is { } key && watches.TryRemove(key, out var watch) && watch.IsValueCreated)
      try { await (await watch.Value).DisposeAsync(); } catch (Exception ex) when (ex is IOException or InvalidOperationException or OperationCanceledException) { }
  }
  public async ValueTask CleanupAsync(ServerSigninRequest request, CancellationToken ct)
  { await StopWatch(request); _ = await runtime.RunAsync(request.Server, ServerSigninScripts.Cleanup(request.Task.AttemptId!), ct); }
  public async ValueTask<IServerSigninForward> ForwardAsync(ServerSigninRequest request, int port, CancellationToken ct)
  {
    if (!request.Server.DrivesBrowser || port is < 1024 or > 65535) throw new ServerRefusal("This server cannot open browser sign-in callbacks.");
    var lease = await runtime.PrepareTerminalAsync(request.Server, ct);
    try
    {
      var pinned = runtime.Arguments(request.Server, null);
      if (lease.Launch.Arguments.Contains("BatchMode=yes")) pinned = new[] { "-o", "BatchMode=yes" }.Concat(pinned).ToArray();
      var args = ForwardArguments(pinned, port);
      var launch = lease.Launch with { Arguments = args };
      var forward = await (forwardStarter ?? new WindowsSigninForwardStarter()).StartAsync(launch, port, ct);
      return new OwnedForward(forward, lease);
    }
    catch { await lease.DisposeAsync(); throw; }
  }
  public static IReadOnlyList<string> ForwardArguments(IReadOnlyList<string> pinnedArguments, int port)
  {
    if (port is < 1024 or > 65535) throw new ServerRefusal("Choose an unprivileged callback port.");
    var args = pinnedArguments.Select(a => a == "-T" || a == "-tt" ? "-N" : a == "ClearAllForwardings=yes" ? "ClearAllForwardings=no" : a).ToList();
    var target = args.IndexOf("--"); if (target < 0 || target + 2 != args.Count) throw new ServerRefusal("The pinned SSH target is invalid.");
    args.InsertRange(target, ["-v", "-o", "ExitOnForwardFailure=yes", "-L", "127.0.0.1:" + port.ToString(CultureInfo.InvariantCulture) + ":127.0.0.1:" + port.ToString(CultureInfo.InvariantCulture)]);
    return args;
  }
  private sealed class OwnedForward(IServerSigninForward forward, OpenSshTerminalLease credentials) : IServerSigninForward
  {
    public bool IsAlive => forward.IsAlive;
    public async ValueTask DisposeAsync() { await forward.DisposeAsync(); await credentials.DisposeAsync(); }
  }
}

public sealed class WindowsSigninForwardStarter : IServerSigninForwardStarter
{
  public async ValueTask<IServerSigninForward> StartAsync(ProcessLaunch launch, int port, CancellationToken ct)
  {
    // Refuse an existing local listener without opening a connection to it.
    var probe = new TcpListener(IPAddress.Loopback, port);
    try { probe.Server.ExclusiveAddressUse = true; probe.Start(); }
    catch (SocketException) { throw new ServerSigninPortBusy(); }
    finally { probe.Stop(); }
    Forward? owner = null;
    try { owner = new Forward(launch, port, ct); await owner.ReadyAsync(ct); return owner; }
    catch (Exception ex) when (ex is TimeoutException or System.ComponentModel.Win32Exception)
    { if (owner is not null) await owner.DisposeAsync(); throw new IOException("The private SSH callback tunnel could not start."); }
    catch { if (owner is not null) await owner.DisposeAsync(); throw; }
  }
  private sealed class Forward : IServerSigninForward
  {
    private readonly Process process;
    private readonly CancellationTokenSource lifetime;
    private readonly TaskCompletionSource ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Task drain;
    private readonly Task exited;
    private int disposed;
    private volatile bool busy;
    public bool IsAlive => Volatile.Read(ref disposed) == 0 && !process.HasExited;
    public Forward(ProcessLaunch launch, int port, CancellationToken ct)
    {
      lifetime = CancellationTokenSource.CreateLinkedTokenSource(ct);
      var start = new ProcessStartInfo(launch.Executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = launch.WorkingDirectory };
      foreach (var arg in launch.Arguments) start.ArgumentList.Add(arg);
      foreach (var key in new[] { "SSH_AUTH_SOCK", "SSH_AGENT_PID", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "DISPLAY", "TD_SERVER_ASKPASS_PIPE" }) start.Environment.Remove(key);
      foreach (var entry in launch.Environment) start.Environment[entry.Key] = entry.Value;
      process = new() { StartInfo = start };
      if (!process.Start()) throw new IOException("The private SSH forward could not start.");
      drain = Task.WhenAll(DrainAsync(process.StandardError, port, true), DrainAsync(process.StandardOutput, port, false));
      exited = process.WaitForExitAsync();
    }
    private async Task DrainAsync(StreamReader stream, int port, bool inspect)
    {
      var buffer = new char[1024]; var tail = new StringBuilder(); var bytes = 0;
      try
      {
        while (true)
        {
          var count = await stream.ReadAsync(buffer.AsMemory(), lifetime.Token); if (count == 0) return;
          bytes += Encoding.UTF8.GetByteCount(buffer.AsSpan(0, count)); if (bytes > 65536) throw new IOException("The private SSH forward exceeded its diagnostic limit.");
          if (!inspect) continue;
          tail.Append(buffer, 0, count);
          var text = tail.ToString();
          if (text.Contains("Address already in use", StringComparison.OrdinalIgnoreCase) || text.Contains("cannot listen to port", StringComparison.OrdinalIgnoreCase)) busy = true;
          if (text.Contains("Local forwarding listening on 127.0.0.1 port " + port.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal)) ready.TrySetResult();
          if (tail.Length > 4096) tail.Remove(0, tail.Length - 4096);
        }
      }
      catch (Exception ex) when (ex is IOException or OperationCanceledException)
      { ready.TrySetException(new IOException("The private SSH forwarding connection closed.")); Kill(); }
    }
    public async Task ReadyAsync(CancellationToken ct)
    {
      var first = await Task.WhenAny(ready.Task, exited).WaitAsync(TimeSpan.FromSeconds(15), ct);
      if (first == exited) { if (busy) throw new ServerSigninPortBusy(); throw new IOException("The server refused its private callback tunnel."); }
      await ready.Task;
      if (process.HasExited) { if (busy) throw new ServerSigninPortBusy(); throw new IOException("The private callback tunnel closed before sign-in."); }
    }
    private void Kill() { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } }
    public async ValueTask DisposeAsync()
    {
      if (Interlocked.Exchange(ref disposed, 1) != 0) return;
      lifetime.Cancel(); Kill();
      try { await Task.WhenAll(exited, drain); } catch (Exception ex) when (ex is IOException or OperationCanceledException) { }
      process.Dispose(); lifetime.Dispose();
    }
  }
}
