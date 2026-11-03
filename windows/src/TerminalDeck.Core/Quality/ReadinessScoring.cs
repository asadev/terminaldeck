using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Quality;

public static class ReadinessScoring
{
  public static int Score(IEnumerable<ProjectCheck> checks)
  {
    var rows = checks.ToArray(); var total = rows.Where(r => r.Status != "skip").Sum(r => r.Weight);
    var earned = rows.Where(r => r.Status != "skip").Sum(r => r.Weight * (r.Status == "pass" ? 1 : r.Status == "warn" ? .5 : 0));
    var score = total > 0 ? (int)Math.Round(100 * earned / total, MidpointRounding.AwayFromZero) : 0;
    foreach (var gate in rows.Where(r => r.Gate)) score = Math.Min(score, gate.Status == "fail" ? 39 : gate.Status == "warn" ? 79 : 100);
    return score;
  }
}

public sealed partial class ProjectReadiness
{
  private static readonly Dictionary<string, double> Weights = new() { ["instructions"] = 18, ["test"] = 14, ["git"] = 12, ["ignore"] = 10, ["readme"] = 8, ["typecheck"] = 8, ["git-clean"] = 8, ["lint"] = 6, ["lock"] = 6, ["secrets"] = 30 };
  private static readonly string[] SecretRules = [".env", ".env.*", "!.env.example", "*.pem", "*.p12", "*.pfx", "id_rsa", "id_ed25519", ".netrc"];
  private static string? ReadProjectText(string folder, string relative)
  {
    var path = SafeFile(folder, relative);
    if (!File.Exists(path)) return null;
    if (new FileInfo(path).Length > 2 * 1024 * 1024) throw new IOException(relative + " exceeds the inspection size limit.");
    return File.ReadAllText(path);
  }
  internal static string SafeFile(string folder, string relative)
  {
    if (Path.IsPathRooted(relative) || relative.Split('/', '\\').Any(p => p is ".." or "." || p.Length == 0)) throw new ArgumentException("Choose a project-relative file.");
    var path = Path.GetFullPath(Path.Combine(folder, relative));
    for (var part = new FileInfo(path) as FileSystemInfo; part is not null && !string.Equals(part.FullName, folder, StringComparison.OrdinalIgnoreCase); part = part is FileInfo f ? f.Directory : ((DirectoryInfo)part).Parent)
      if ((part.Exists || File.Exists(part.FullName) || Directory.Exists(part.FullName)) && (part.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("Linked files are not inspected or changed.");
    return path;
  }
  private static (string Dependency, string Command)[] ScriptChoices(string key) => key switch
  {
    "test" => [("vitest", "vitest run"), ("jest", "jest"), ("mocha", "mocha"), ("ava", "ava"), ("@playwright/test", "playwright test"), ("playwright", "playwright test")],
    "lint" => [("eslint", "eslint ."), ("@biomejs/biome", "biome check ."), ("oxlint", "oxlint"), ("prettier", "prettier --check .")],
    "typecheck" => [("typescript", "tsc --noEmit")],
    _ => throw new ArgumentException("Unknown project script.")
  };
  private static void Enrich(string folder, string? provider, List<ProjectCheck> checks)
  {
    var candidates = provider switch { "codex" => new[] { "AGENTS.md" }, "gemini" => ["GEMINI.md"], "claude" => ["CLAUDE.md", ".claude/CLAUDE.md", "AGENTS.md"], null => ["CLAUDE.md", ".claude/CLAUDE.md", "AGENTS.md", "GEMINI.md"], _ => throw new ArgumentException("Choose Claude, Codex or Gemini.") };
    var instruction = candidates.FirstOrDefault(f => File.Exists(Path.Combine(folder, f)));
    checks.RemoveAll(c => c.Id == "instructions");
    if (instruction is null) checks.Add(new("instructions", "Agent instructions present and useful", "fail", "No instructions for the selected agent were found.", Fix: provider == "gemini" ? "gemini-instructions" : provider == "claude" ? "claude-instructions" : "instructions"));
    else
    {
      var text = ReadProjectText(folder, instruction)!; var lines = text.Split('\n').Count(l => !string.IsNullOrWhiteSpace(l) && !l.TrimStart().StartsWith("<!--", StringComparison.Ordinal));
      var useful = !Regex.IsMatch(text, "Add the actual|Describe this project|Add the project") && lines is >= 12 and <= 400 && Regex.IsMatch(text, @"```|\b(npm|pnpm|yarn|cargo|dotnet|pytest|make|gradle)\b");
      checks.Add(new("instructions", "Agent instructions present and useful", useful ? "pass" : "warn", instruction + " has " + lines + " meaningful lines. Include actual run, test and project conventions.", instruction));
    }
    var readme = ReadProjectText(folder, "README.md");
    if (readme is not null)
    {
      checks.RemoveAll(c => c.Id == "readme"); var useful = readme.Split('\n').Count(l => !string.IsNullOrWhiteSpace(l)) >= 5 && !Regex.IsMatch(readme, "Describe this project|Add the actual");
      checks.Add(new("readme", "README for humans", useful ? "pass" : "warn", useful ? "A substantive README exists." : "Fill in the project, install, run and test details.", "README.md"));
    }
    var ignore = ReadProjectText(folder, ".gitignore") ?? "";
    var missing = SecretRules.Where(r => !ignore.Split('\n').Select(l => l.Trim()).Contains(r)).ToArray();
    checks.RemoveAll(c => c.Id == "ignore");
    checks.Add(new("ignore", "Ignored files cover the basics", ignore.Length == 0 ? "fail" : missing.Length > 0 ? "warn" : "pass", missing.Length > 0 ? "Review missing environment and key ignore patterns." : "Standard secret ignore patterns exist.", ".gitignore", "patch-ignore"));
    var exposed = Directory.EnumerateFiles(folder).Take(10001).Select(Path.GetFileName).Where(n => n is not null && Regex.IsMatch(n, @"^(\.env(\..+)?|id_(rsa|ed25519)|\.netrc)$|\.(pem|p12|pfx)$", RegexOptions.IgnoreCase) && !Regex.IsMatch(n, @"\.(example|sample|template)$", RegexOptions.IgnoreCase)).ToArray();
    // Only Git can establish whether a path is tracked; a filesystem scan keeps that distinction explicit.
    checks.Add(new("secrets", "Credential files protected", "warn", missing.Length == 0 && exposed.Length == 0 ? "Standard ignore patterns are present; tracked-file verification requires Git." : "Review credential ignore coverage. No credential contents were read. Tracked-file verification requires Git.", ".gitignore", "patch-ignore", 30, true));
    if (File.Exists(Path.Combine(folder, "package.json")))
    {
      var package = JsonNode.Parse(ReadProjectText(folder, "package.json")!)?.AsObject();
      var scripts = package?["scripts"] as JsonObject;
      var deps = new[] { package?["dependencies"] as JsonObject, package?["devDependencies"] as JsonObject };
      bool Has(string name) => deps.Any(d => d?.ContainsKey(name) == true);
      foreach (var id in new[] { "test", "lint", "typecheck" })
      {
        var script = scripts?[id]?.GetValue<string>();
        if (id == "typecheck" && scripts is not null) script ??= scripts.FirstOrDefault(p => Regex.IsMatch(p.Key, "^(type-check|check-types|tsc)$", RegexOptions.IgnoreCase) || Regex.IsMatch(p.Value?.ToString() ?? "", @"tsc\b[^&|]*--noEmit")).Value?.ToString();
        if (id == "lint" && scripts is not null) script ??= scripts.FirstOrDefault(p => Regex.IsMatch(p.Key, "^(format|fmt|check)$", RegexOptions.IgnoreCase) || Regex.IsMatch(p.Value?.ToString() ?? "", @"\b(eslint|biome|oxlint|prettier|standard)\b")).Value?.ToString();
        var supported = ScriptChoices(id).FirstOrDefault(choice => Has(choice.Dependency));
        if (id == "typecheck" && !Has("typescript") && !File.Exists(Path.Combine(folder, "tsconfig.json"))) { checks.Add(new(id, "Type checks", "skip", "No TypeScript declaration.")); continue; }
        var present = !string.IsNullOrWhiteSpace(script) && !script.Contains("no test specified", StringComparison.OrdinalIgnoreCase);
        checks.RemoveAll(c => c.Id == id);
        checks.Add(new(id, id == "typecheck" ? "Types checked without building" : id == "test" ? "Tests can be run" : "Lint or format check", present ? "pass" : id == "test" ? "fail" : "warn", present ? "A command is declared; this scan has not run it." : "No useful command is declared.", "package.json", !present && supported.Dependency is not null ? "script-" + id : null));
      }
    }
    for (var i = 0; i < checks.Count; i++) checks[i] = checks[i] with { Weight = Weights.GetValueOrDefault(checks[i].Id, 0) };
  }
}
