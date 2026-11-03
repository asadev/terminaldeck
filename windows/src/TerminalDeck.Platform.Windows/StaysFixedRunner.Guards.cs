using System.Diagnostics;
using System.Text.Json;

namespace TerminalDeck.Platform.Windows;

public sealed partial class StaysFixedRunner
{
  public async Task<string?> ValidateGuardNameAsync(string name, CancellationToken ct)
  {
    var bundledNode = Path.GetFullPath(Path.Combine(packageDirectory, "..", "..", "node.exe")); var node = nodeExecutable ?? (File.Exists(bundledNode) ? bundledNode : Node());
    if (!File.Exists(node)) throw new IOException("Repair the Stays Fixed runtime before adding a rule.");
    var module = Path.Combine(packageDirectory, "src", "guard", "name.js"); if (!File.Exists(module)) throw new IOException("The bundled guard validator is missing. Repair this app.");
    var start = new ProcessStartInfo(node) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
    foreach (var argument in new[] { "--input-type=module", "--eval", "const {checkGuardName}=await import(process.argv[1]);process.stdout.write(JSON.stringify(checkGuardName(process.argv[2])))", new Uri(Path.GetFullPath(module)).AbsoluteUri, name }) start.ArgumentList.Add(argument);
    using var process = Process.Start(start) ?? throw new IOException("The guard validator could not start.");
    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct); timeout.CancelAfter(TimeSpan.FromSeconds(10));
    using var stop = timeout.Token.Register(() => { try { process.Kill(true); } catch (InvalidOperationException) { } catch (System.ComponentModel.Win32Exception) { } });
    var output = ReadAsync(process.StandardOutput, 16384); var error = ReadAsync(process.StandardError, 16384); await process.WaitForExitAsync(timeout.Token); await error;
    if (process.ExitCode != 0) throw new IOException("The engine could not validate this rule name. Repair setup and retry.");
    using var document = JsonDocument.Parse(await output); var verdict = document.RootElement;
    return verdict.GetProperty("ok").GetBoolean() ? null : verdict.TryGetProperty("why", out var why) ? why.GetString() : "Use a plain sentence describing what the product must still do.";
  }
}
