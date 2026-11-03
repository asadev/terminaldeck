using System.Diagnostics;
using System.Text.Json;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Servers;

namespace TerminalDeck.Platform.Windows.Servers;

// One owned SSH reader per explicit attempt, rather than reconnecting for each
// status refresh. Only two bounded records (address and completion) are emitted.
internal sealed class WindowsSigninCaptureWatch : IAsyncDisposable
{
  private readonly Process process;
  private readonly OpenSshTerminalLease credentials;
  private readonly CancellationTokenSource lifetime;
  private readonly Task reading;
  private ServerSigninCapture latest = new(null, false, -1);
  private volatile bool broken;
  public ServerSigninCapture Read() => broken ? throw new IOException("The private sign-in watch closed.") : Volatile.Read(ref latest);
  public WindowsSigninCaptureWatch(ProcessLaunch launch, OpenSshTerminalLease credentials, CancellationToken ct)
  {
    this.credentials = credentials; lifetime = CancellationTokenSource.CreateLinkedTokenSource(ct);
    var start = new ProcessStartInfo(launch.Executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = launch.WorkingDirectory };
    foreach (var arg in launch.Arguments) start.ArgumentList.Add(arg);
    foreach (var key in new[] { "SSH_AUTH_SOCK", "SSH_AGENT_PID", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "DISPLAY", "TD_SERVER_ASKPASS_PIPE" }) start.Environment.Remove(key);
    foreach (var pair in launch.Environment) start.Environment[pair.Key] = pair.Value;
    process = new() { StartInfo = start };
    if (!process.Start()) throw new IOException("The private sign-in watch could not start.");
    reading = ReadAsync();
  }
  private async Task ReadAsync()
  {
    var error = DrainErrorsAsync();
    try
    {
      var buffer = new char[1024]; var line = new System.Text.StringBuilder(); var total = 0;
      while (true)
      {
        var n = await process.StandardOutput.ReadAsync(buffer.AsMemory(), lifetime.Token); if (n == 0) break;
        total += n; if (total > 65536) throw new IOException("Private capture exceeded its limit.");
        for (var index = 0; index < n; index++)
        {
          var character = buffer[index];
          if (character != '\n') { line.Append(character); if (line.Length > 16384) throw new IOException("Private capture exceeded its limit."); continue; }
          var value = JsonSerializer.Deserialize<ServerSigninCapture>(line.ToString(), new JsonSerializerOptions { PropertyNameCaseInsensitive = true }); line.Clear();
          if (value is null || value.Address?.Length > 8192) throw new IOException("Private capture was invalid.");
          Volatile.Write(ref latest, value);
        }
      }
      if (!latest.Done && !lifetime.IsCancellationRequested) broken = true;
    }
    catch (Exception ex) when (ex is IOException or JsonException or OperationCanceledException) { if (!lifetime.IsCancellationRequested) broken = true; Kill(); }
    finally { try { await error; } catch (Exception ex) when (ex is IOException or OperationCanceledException) { } }
  }
  private async Task DrainErrorsAsync()
  {
    var buffer = new char[1024]; var count = 0;
    while (true)
    {
      var n = await process.StandardError.ReadAsync(buffer.AsMemory(), lifetime.Token); if (n == 0) return;
      count += n; if (count > 65536) { Kill(); throw new IOException("The private SSH diagnostics exceeded their limit."); }
    }
  }
  private void Kill() { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } }
  public async ValueTask DisposeAsync()
  {
    lifetime.Cancel(); Kill(); await reading; await process.WaitForExitAsync(); process.Dispose(); await credentials.DisposeAsync(); lifetime.Dispose();
  }
}
