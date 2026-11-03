using System.Diagnostics;
using System.Text;
using TerminalDeck.Core.Quality;

namespace TerminalDeck.Platform.Windows;

// The existing MIT package is bundled as a dependency, never reconstructed from
// its source. Each check owns one cancellable process tree, outside the UI.
public sealed partial class StaysFixedRunner(string packageDirectory, string? nodeExecutable = null) : IQualityRunner, IQualityGuardValidator
{
  private static string Node() => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "nodejs", "node.exe");
  public async Task<QualityCommandResult> RunAsync(string folder, IReadOnlyList<string> arguments, CancellationToken ct)
  {
    var bundledNode = Path.GetFullPath(Path.Combine(packageDirectory, "..", "..", "node.exe"));
    var node = nodeExecutable ?? (File.Exists(bundledNode) ? bundledNode : Node());
    if (!File.Exists(node)) throw new InvalidOperationException("Stays Fixed needs Node.js 22 or newer. Install Node.js, then try again.");
    var entry = Path.Combine(packageDirectory, "bin", "staysfixed.js");
    if (!File.Exists(entry)) throw new InvalidOperationException("The bundled Stays Fixed engine is missing. Repair or update this copy of the app.");
    var versionStart = new ProcessStartInfo(node) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = folder }; versionStart.ArgumentList.Add("--version");
    using (var version = Process.Start(versionStart) ?? throw new IOException("The Stays Fixed runtime could not start."))
    {
      var read = version.StandardOutput.ReadToEndAsync(ct); var errors = version.StandardError.ReadToEndAsync(ct);
      using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct); timeout.CancelAfter(TimeSpan.FromSeconds(10));
      using var cancelVersion = timeout.Token.Register(() => { try { version.Kill(true); } catch (InvalidOperationException) { } catch (System.ComponentModel.Win32Exception) { } });
      await version.WaitForExitAsync(timeout.Token); var text = (await read).Trim().TrimStart('v'); await errors;
      if (version.ExitCode != 0 || !int.TryParse(text.Split('.')[0], out var major) || major < 22) throw new InvalidOperationException("Stays Fixed needs Node.js 22 or newer. Repair this app's bundled runtime or install a current Node.js, then retry setup.");
    }
    var start = new ProcessStartInfo(node) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = folder };
    start.ArgumentList.Add(entry); foreach (var argument in arguments) start.ArgumentList.Add(argument);
    using var process = Process.Start(start) ?? throw new IOException("Stays Fixed could not start.");
    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromMinutes(arguments.Contains("check") ? 20 : 5));
    using var stop = deadline.Token.Register(() => { try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } catch (System.ComponentModel.Win32Exception) { } });
    var output = ReadAsync(process.StandardOutput, 2 * 1024 * 1024); var error = ReadAsync(process.StandardError, 64 * 1024);
    try { await process.WaitForExitAsync(deadline.Token); return new(process.ExitCode, await output, await error); }
    catch (OperationCanceledException) { await process.WaitForExitAsync(CancellationToken.None); await Task.WhenAll(output, error); throw; }
  }
  private static async Task<string> ReadAsync(StreamReader reader, int maximum)
  {
    var text = new StringBuilder(); var buffer = new char[4096];
    while (true) { var count = await reader.ReadAsync(buffer); if (count == 0) return text.ToString(); if (text.Length < maximum) text.Append(buffer, 0, Math.Min(count, maximum - text.Length)); }
  }
}
