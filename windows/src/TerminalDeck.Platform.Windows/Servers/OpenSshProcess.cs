using System.Diagnostics;
using System.Text;
using TerminalDeck.Core.Servers;

namespace TerminalDeck.Platform.Windows.Servers;

public sealed record OpenSshInvocation(string Executable, IReadOnlyList<string> Arguments, IReadOnlyDictionary<string, string> Environment, string? Input = null, int Limit = 262144);
public interface IOpenSshProcess
{
  ValueTask<ServerOutput> RunAsync(OpenSshInvocation invocation, CancellationToken ct);
}
public sealed class OpenSshProcess : IOpenSshProcess
{
  public async ValueTask<ServerOutput> RunAsync(OpenSshInvocation invocation, CancellationToken ct)
  {
    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct); timeout.CancelAfter(TimeSpan.FromSeconds(45));
    var start = new ProcessStartInfo(invocation.Executable) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
    foreach (var arg in invocation.Arguments) start.ArgumentList.Add(arg);
    foreach (var key in new[] { "SSH_AUTH_SOCK", "SSH_AGENT_PID", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "DISPLAY", "TD_SERVER_ASKPASS_PIPE" }) start.Environment.Remove(key);
    foreach (var entry in invocation.Environment) start.Environment[entry.Key] = entry.Value;
    using var process = new Process { StartInfo = start };
    if (!process.Start()) throw new IOException("Windows could not start OpenSSH.");
    using var stop = timeout.Token.Register(() => { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } });
    try
    {
      // Drain both pipes concurrently, but never release stderr: SSH failures may
      // contain paths and remote diagnostic text that the app must not log.
      var output = ReadAsync(process.StandardOutput, invocation.Limit, timeout);
      var error = ReadAsync(process.StandardError, 65536, timeout);
      var input = WriteAsync(process, invocation.Input, timeout.Token);
      await Task.WhenAll(output, error, input, process.WaitForExitAsync(timeout.Token));
      return new(process.ExitCode, await output);
    }
    catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new IOException("The SSH request timed out."); }
    finally { if (!process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(CancellationToken.None); } }
  }
  private static async Task WriteAsync(Process p, string? input, CancellationToken ct)
  {
    try { if (input is not null) await p.StandardInput.WriteAsync(input.AsMemory(), ct); }
    finally { p.StandardInput.Close(); }
  }
  private static async Task<string> ReadAsync(StreamReader stream, int limit, CancellationTokenSource lifetime)
  {
    var result = new StringBuilder(); var buffer = new char[4096]; int bytes = 0;
    while (true)
    {
      var count = await stream.ReadAsync(buffer.AsMemory(), lifetime.Token); if (count == 0) return result.ToString();
      bytes += Encoding.UTF8.GetByteCount(buffer.AsSpan(0, count));
      if (bytes > limit) { lifetime.Cancel(); throw new IOException("The SSH response exceeded its size limit."); }
      result.Append(buffer, 0, count);
    }
  }
}
