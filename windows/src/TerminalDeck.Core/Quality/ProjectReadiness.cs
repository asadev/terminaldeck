using System.Text.Json;
using System.Security.Cryptography;

namespace TerminalDeck.Core.Quality;

public sealed record ProjectCheck(string Id, string Title, string Status, string Detail, string? File = null, string? Fix = null, double Weight = 1, bool Gate = false);
public sealed record ProjectReadinessReport(string Folder, DateTimeOffset ScannedAt, ProjectCheck[] Checks)
{
  public int Passing => Checks.Count(c => c.Status == "pass");
  public int Applicable => Checks.Count(c => c.Status != "skip");
  public int Score => ReadinessScoring.Score(Checks);
  public string Band => Score >= 85 ? "Ready" : Score >= 65 ? "Workable" : Score >= 40 ? "Rough" : "At risk";
  public bool Ready => Applicable > 0 && Passing == Applicable;
  public string? CappedBy => Checks.FirstOrDefault(c => c.Gate && c.Status is "fail" or "warn")?.Title;
}
public sealed record ProjectFixPreview(string Token, string Folder, string File, string Text, DateTimeOffset ExpiresAt);

// These are filesystem observations, not claims that commands/tests have passed.
// Project code is never imported or executed by a readiness read.
public sealed partial class ProjectReadiness
{
  private readonly Dictionary<string, ProjectFixPreview> previews = [];
  public ProjectReadinessReport Scan(string folder, string? provider = null)
  {
    folder = Root(folder); var checks = new List<ProjectCheck>();
    void Exists(string id, string name, string file, string? fix = null) => checks.Add(File.Exists(Path.Combine(folder, file))
      ? new(id, name, "pass", file + " exists. Its contents have not been executed or approved.", file)
      : new(id, name, "warn", file + " is missing.", null, fix));
    Exists("instructions", "Instructions for agents", "AGENTS.md", "instructions");
    Exists("readme", "Project readme", "README.md", "readme");
    Exists("ignore", "Ignored files", ".gitignore", "ignore");
    checks.Add(new("git", "Version control", Directory.Exists(Path.Combine(folder, ".git")) || File.Exists(Path.Combine(folder, ".git")) ? "pass" : "warn", "A repository marker is " + (Directory.Exists(Path.Combine(folder, ".git")) || File.Exists(Path.Combine(folder, ".git")) ? "present. Working-tree status is shown under Changes." : "missing. No repository was created.")));
    var package = Path.Combine(folder, "package.json");
    if (File.Exists(package))
    {
      try
      {
        if (new FileInfo(package).Length > 2 * 1024 * 1024) throw new IOException("package.json is too large to inspect.");
        using var json = JsonDocument.Parse(File.ReadAllBytes(package));
        foreach (var (id, label) in new[] { ("test", "Test command"), ("build", "Build command"), ("lint", "Lint command") })
        {
          var found = json.RootElement.TryGetProperty("scripts", out var scripts) && scripts.ValueKind == JsonValueKind.Object && scripts.TryGetProperty(id, out var script) && script.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(script.GetString());
          checks.Add(new(id, label, found ? "pass" : "warn", found ? "A package script is declared. It has not been run by this scan." : "No " + id + " script is declared in package.json.", "package.json"));
        }
        var locked = new[] { "package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock", "bun.lock", "bun.lockb" }.Any(f => File.Exists(Path.Combine(folder, f)));
        checks.Add(new("lock", "Dependency lockfile", locked ? "pass" : "warn", locked ? "A dependency lockfile exists." : "No supported dependency lockfile was found.", Fix: locked ? null : "create-lockfile"));
      }
      catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException) { checks.Add(new("package", "Package metadata", "fail", "package.json could not be read as a bounded JSON file.", "package.json")); }
    }
    else checks.Add(new("package", "Node package checks", "skip", "No package.json. This scan does not invent Node checks for another project type."));
    var workflows = Path.Combine(folder, ".github", "workflows");
    checks.Add(new("ci", "Continuous checks", Directory.Exists(workflows) ? "pass" : "warn", Directory.Exists(workflows) ? "A GitHub workflows directory exists. Its checks have not been run by this scan." : "No GitHub workflows directory was found. Other CI systems are not detected by this scan."));
    try { Enrich(folder, provider, checks); }
    catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException)
    {
      checks.Add(new("inspection", "Complete project inspection", "fail", "Some project metadata could not be safely inspected. Review linked files and package.json, then scan again."));
      if (!checks.Any(c => c.Id == "secrets")) checks.Add(new("secrets", "Credential files protected", "warn", "This check could not run safely.", Weight: 30, Gate: true));
    }
    return new(folder, DateTimeOffset.UtcNow, checks.ToArray());
  }
  public ProjectFixPreview Preview(string folder, string fix)
  {
    folder = Root(folder);
    var (file, text) = fix switch
    {
      "instructions" => ("AGENTS.md", "# Project instructions\n\nDescribe the project, its run and verification commands, and any files or services that need special care. Keep these instructions current as the project changes.\n"),
      "readme" => ("README.md", "# " + Path.GetFileName(folder) + "\n\nDescribe what this project does, how to run it, and how to verify a change.\n"),
      "ignore" => (".gitignore", ".env\n.env.*\n!.env.example\n*.pem\n*.p12\n*.pfx\nnode_modules/\n"),
      _ => throw new ArgumentException("Choose a supported missing-file fix.")
    };
    if (File.Exists(Path.Combine(folder, file))) throw new InvalidOperationException("That file already exists. Edit it in Files instead.");
    var token = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(24));
    var preview = new ProjectFixPreview(token, folder, file, text, DateTimeOffset.UtcNow.AddMinutes(10));
    lock (previews)
    {
      foreach (var old in previews.Values.Where(p => p.ExpiresAt <= DateTimeOffset.UtcNow).ToArray()) previews.Remove(old.Token);
      if (previews.Count >= 64) throw new InvalidOperationException("Too many pending previews. Finish or let one expire.");
      previews[token] = preview;
    }
    return preview;
  }
  public string Apply(string folder, string token)
  {
    folder = Root(folder); ProjectFixPreview preview;
    lock (previews)
    {
      if (!previews.Remove(token, out preview!) || preview.ExpiresAt <= DateTimeOffset.UtcNow || !string.Equals(preview.Folder, folder, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("That preview expired or belongs to another folder. Preview again.");
    }
    var path = Path.Combine(folder, preview.File);
    using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
    var bytes = System.Text.Encoding.UTF8.GetBytes(preview.Text); file.Write(bytes); file.Flush(true);
    return path;
  }
  private static string Root(string folder)
  {
    folder = Path.GetFullPath(folder);
    var current = new DirectoryInfo(folder);
    if (!current.Exists) throw new ArgumentException("Choose an existing project folder.");
    for (var check = current; check is not null; check = check.Parent)
      if ((check.Attributes & FileAttributes.ReparsePoint) != 0) throw new ArgumentException("Choose the real project folder, not a linked folder.");
    return folder;
  }
}
