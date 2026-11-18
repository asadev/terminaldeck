using System.Diagnostics;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.Platform.Windows;

// Codex's own loader supplies the effective inventory, including project and managed/plugin layers.
// This command reads configuration only. Its private output is never logged or returned to a tool caller.
public static class AgentAddonInventory
{
  public static IReadOnlyList<string> Restrict(ProcessLaunch inventory, IReadOnlySet<string> configured) => ReadAsync(inventory, configured).GetAwaiter().GetResult();
  private static async Task<IReadOnlyList<string>> ReadAsync(ProcessLaunch launch, IReadOnlySet<string> configured)
  {
    using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(15));
    var start = new ProcessStartInfo(launch.Executable) { WorkingDirectory = launch.WorkingDirectory, UseShellExecute = false, CreateNoWindow = true,
      RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = true, StandardOutputEncoding = new UTF8Encoding(false) };
    foreach (var arg in launch.Arguments) start.ArgumentList.Add(arg);
    start.Environment.Clear(); foreach (var entry in launch.Environment) start.Environment[entry.Key] = entry.Value;
    using var process = Process.Start(start) ?? throw new IOException("Codex's effective add-on inventory could not be checked.");
    process.StandardInput.Close();
    var output = BoundedAsync(process.StandardOutput, true, deadline.Token);
    var errors = BoundedAsync(process.StandardError, false, deadline.Token);
    try
    {
      await process.WaitForExitAsync(deadline.Token).ConfigureAwait(false);
      var text = await output.ConfigureAwait(false); await errors.ConfigureAwait(false);
      if (process.ExitCode != 0) throw new IOException("Codex's effective add-on inventory could not be checked. No restricted session was started.");
      using var document = JsonDocument.Parse(text); return FromExport(document.RootElement, configured);
    }
    catch (Exception error) when (error is OperationCanceledException or JsonException)
    { throw new IOException("Codex did not return a complete add-on inventory. No restricted session was started."); }
    finally
    {
      deadline.Cancel();
      if (!process.HasExited) process.Kill(entireProcessTree: true);
      await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
      try { await Task.WhenAll(output, errors).ConfigureAwait(false); } catch (Exception error) when (error is IOException or OperationCanceledException) { }
    }
  }
  private static async Task<string> BoundedAsync(StreamReader reader, bool keep, CancellationToken ct)
  {
    var text = new StringBuilder(); var buffer = new char[4096]; var total = 0; int count;
    while ((count = await reader.ReadAsync(buffer.AsMemory(), ct).ConfigureAwait(false)) != 0)
    {
      if ((total += count) > 2 * 1024 * 1024) throw new IOException("Codex's private add-on inventory was too large to check.");
      if (keep) text.Append(buffer, 0, count);
    }
    return text.ToString();
  }
  public static IReadOnlyList<string> FromExport(JsonElement rows, IReadOnlySet<string> configured)
  {
    if (rows.ValueKind != JsonValueKind.Array || rows.GetArrayLength() > 200) throw new IOException("Codex did not return a complete structured add-on inventory.");
    var names = new HashSet<string>(StringComparer.Ordinal);
    foreach (var row in rows.EnumerateArray())
    {
      if (row.ValueKind != JsonValueKind.Object || !row.TryGetProperty("name", out var name) || name.ValueKind != JsonValueKind.String || name.GetString() is not { Length: > 0 } id
        || !System.Text.RegularExpressions.Regex.IsMatch(id, "^[A-Za-z0-9_-]+$") || !names.Add(id)
        || !row.TryGetProperty("enabled", out var enabled) || enabled.ValueKind is not (JsonValueKind.True or JsonValueKind.False)
        || !row.TryGetProperty("transport", out var transport) || transport.ValueKind != JsonValueKind.Object) throw new IOException("A Codex add-on inventory record cannot be restricted safely.");
      if (enabled.GetBoolean() && id != "deck-tools" && !configured.Contains(id)) throw new InvalidOperationException("An enabled Codex add-on is supplied outside its configured server tables. It cannot be disabled for one session.");
    }
    return configured.Where(s => s != "deck-tools").Order(StringComparer.Ordinal).SelectMany(s => new[] { "-c", "mcp_servers." + s + ".enabled=false" }).ToArray();
  }
}
