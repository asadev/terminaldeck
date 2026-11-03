using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Quality;

public sealed record QualityCommandResult(int ExitCode, string Output, string Error);
public interface IQualityGuardValidator
{
  Task<string?> ValidateGuardNameAsync(string name, CancellationToken ct);
}
public interface IQualityRunner
{
  Task<QualityCommandResult> RunAsync(string folder, IReadOnlyList<string> arguments, CancellationToken ct);
}
public sealed record StaysFixedReport(string Folder, string Action, DateTimeOffset ReadAt, bool Ok, JsonElement? Report, string? Problem);

public sealed partial class StaysFixedService(IQualityRunner runner, TerminalDeck.Core.Storage.IStateStore<StaysFixedPreferences>? preferences = null)
{
  public event Action<string>? Changed;
  private readonly System.Collections.Concurrent.ConcurrentDictionary<string, SemaphoreSlim> gates = new(StringComparer.OrdinalIgnoreCase);
  public async Task<StaysFixedReport> RunAsync(string folder, string action, CancellationToken ct)
  {
    folder = QualityFolder.Require(folder);
    if (!Directory.Exists(folder)) throw new ArgumentException("Choose an existing project folder.");
    return await ExecuteAsync(folder, action, Command(new(action)), ct);
  }
  private async Task<StaysFixedReport> ExecuteAsync(string folder, string action, string[] command, CancellationToken ct)
  {
    var gate = gates.GetOrAdd(folder, _ => new(1, 1));
    await gate.WaitAsync(ct);
    try
    {
    if (action == "mark-good") StaysFixedEvidence.RequireObservedBuild(folder, FullReport(folder));
    var result = await runner.RunAsync(folder, command, ct);
    JsonElement? report = null;
    try { using var json = JsonDocument.Parse(result.Output, new JsonDocumentOptions { MaxDepth = 64 }); report = json.RootElement.Clone(); }
    catch (JsonException)
    {
      var start = 0;
      foreach (var line in result.Output.Split('\n'))
      {
        if (line.StartsWith('{'))
        {
          try { using var json = JsonDocument.Parse(result.Output[start..], new JsonDocumentOptions { MaxDepth = 64 }); report = json.RootElement.Clone(); break; }
          catch (JsonException) { }
        }
        start += line.Length + 1;
      }
    }
    var problem = result.ExitCode != 0 ? result.Error.Length > 0 ? result.Error : "The engine refused or could not finish this operation. Read the report for its reason." : null;
    if (report is null) report = JsonSerializer.SerializeToElement(new { output = result.Output, error = result.Error });
    var answer = new StaysFixedReport(folder, action, DateTimeOffset.UtcNow, result.ExitCode == 0, report, problem);
    Changed?.Invoke(folder); return answer;
    }
    finally { gate.Release(); }
  }
  public static IReadOnlyList<McpToolSpec> Specs { get; } =
  [ new("quality.staysfixed", "quality_staysfixed", McpTier.Alter, JsonSerializer.Deserialize<JsonElement>("""{"type":"object","properties":{"folder":{"type":"string"},"action":{"type":"string","enum":["doctor","preview","setup","check"]}},"required":["folder","action"],"additionalProperties":false}""")) ];
}
