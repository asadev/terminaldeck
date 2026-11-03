using System.Text.Json;
using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Quality;

public sealed record StaysFixedRequest(string Action, string? Finding = null, string? Reason = null, string? Summary = null, string[]? Touches = null, bool Force = false);
public sealed partial class StaysFixedService
{
  public Task<StaysFixedReport> RunAsync(string folder, StaysFixedRequest request, CancellationToken ct = default)
  {
    folder = QualityFolder.Require(folder); if (!Directory.Exists(folder)) throw new ArgumentException("Choose an existing project folder.");
    return ExecuteAsync(folder, request.Action, Command(request), ct);
  }
  internal static string[] Command(StaysFixedRequest request)
  {
    static string Required(string? text, string label)
    {
      if (string.IsNullOrWhiteSpace(text) || text.Length > 4000 || text.Contains('\0')) throw new ArgumentException("Enter " + label + ".");
      return text;
    }
    return request.Action switch
    {
      "doctor" => ["doctor", "--json"], "preview" => ["init", "--dry-run", "--json"],
      "setup" => ["init", "--json"], "check" => ["check", "--json"], "coverage" => ["coverage", "--json"],
      "repair" => ["doctor", "--fix"],
      "mark-good" => request.Force ? ["ship", "--why", Required(request.Reason, "why this build is good"), "--json", "--force"] : ["ship", "--why", Required(request.Reason, "why this build is good"), "--json"],
      "accept-diff" => ["waive", Required(request.Finding, "the finding ID"), "--because", Required(request.Reason, "why the difference is intended")],
      "explain" => ["explain", Required(request.Finding, "the finding ID"), "--evidence"],
      "intent" => new[] { "intent", Required(request.Summary, "what you intend to change") }.Concat((request.Touches is { Length: > 0 and <= 100 } ? request.Touches : throw new ArgumentException("Name the files or areas this change touches.")).SelectMany(t => new[] { "--touches", Required(t, "a touched path") })).ToArray(),
      _ => throw new ArgumentException("Choose a supported Stays Fixed action.")
    };
  }
  public JsonElement FullReport(string folder)
  {
    folder = QualityFolder.Require(folder);
    var file = ProjectReadiness.SafeFile(folder, ".staysfixed/v2/last-check.json");
    if (!File.Exists(file)) return JsonSerializer.SerializeToElement(new { available = false, reason = "Run a check to create a report." });
    if (new FileInfo(file).Length > 16 * 1024 * 1024) throw new IOException("The report exceeds the safe reading limit.");
    using var document = JsonDocument.Parse(File.ReadAllBytes(file)); return StaysFixedEvidence.Result(document.RootElement);
  }
  public async Task<string> AddRuleAsync(string folder, string name, string because, string executable, string[] arguments, CancellationToken ct = default)
  {
    if (runner is IQualityGuardValidator validator)
    {
      var refusal = await validator.ValidateGuardNameAsync(name, ct); if (refusal is not null) throw new ArgumentException(refusal);
    }
    return AddRule(folder, name, because, executable, arguments);
  }
  public string AddRule(string folder, string name, string because, string executable, string[] arguments)
  {
    folder = QualityFolder.Require(folder);
    if (!Directory.Exists(folder) || name.Length is < 5 or > 120 || name.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length < 3 || name.Contains('/') || name.Contains('\\') || name.Contains('_') || name.Any(char.IsControl) || string.IsNullOrWhiteSpace(because) || because.Length > 2000 || string.IsNullOrWhiteSpace(executable) || executable.Length > 1024 || arguments.Length > 100 || arguments.Any(a => a.Length > 4000 || a.Contains('\0'))) throw new ArgumentException("Name the rule, why it matters, and its executable and arguments.");
    var directory = ProjectReadiness.SafeFile(folder, ".staysfixed/guards"); Directory.CreateDirectory(directory);
    var file = ProjectReadiness.SafeFile(folder, ".staysfixed/guards/" + Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(name)))[..24] + ".mjs");
    // A guard is the engine's supported executable rule interface. Values are serialized,
    // never interpolated as JavaScript or passed through a command shell.
    var text = "import { execFile } from 'node:child_process'\nimport { promisify } from 'node:util'\nconst exec = promisify(execFile)\nexport default { name: " + JsonSerializer.Serialize(name) + ", because: " + JsonSerializer.Serialize(because) + ", async run() { await exec(" + JsonSerializer.Serialize(executable) + ", " + JsonSerializer.Serialize(arguments) + ", { cwd: " + JsonSerializer.Serialize(folder) + ", timeout: 120000, maxBuffer: 1048576 }) } }\n";
    using var output = new FileStream(file, FileMode.CreateNew, FileAccess.Write, FileShare.None); var bytes = System.Text.Encoding.UTF8.GetBytes(text); output.Write(bytes); output.Flush(true); Changed?.Invoke(folder); return file;
  }
}
