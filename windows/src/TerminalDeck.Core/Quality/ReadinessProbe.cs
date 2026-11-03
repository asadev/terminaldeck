using System.Text.RegularExpressions;
using TerminalDeck.Core.Code;

namespace TerminalDeck.Core.Quality;

public sealed partial class ProjectReadiness
{
  public async Task<ProjectReadinessReport> ScanAsync(string folder, string? provider = null, ICodeProcessRunner? runner = null, CancellationToken ct = default)
  {
    var scan = Scan(folder, provider); folder = scan.Folder; var checks = scan.Checks.ToList(); var process = runner ?? new CodeProcessRunner();
    async Task<CodeProcessResult> Git(params string[] args) => await process.RunAsync("git", new[] { "-C", folder }.Concat(args).ToArray(), folder, TimeSpan.FromSeconds(15), ct);
    var tracked = await Git("ls-files", "-z");
    checks.RemoveAll(c => c.Id is "secrets" or "git");
    checks.Add(new("git", "Git repository initialised", tracked.Ok ? "pass" : tracked.Missing ? "warn" : "fail", tracked.Ok ? "Git recognises this project as a repository." : tracked.Missing ? "Install Git in the Store or Windows Apps." : "This folder is not a usable Git repository.", Fix: !tracked.Ok && !tracked.Missing ? "git-init" : null, Weight: 12));
    if (tracked.Ok)
    {
      var names = tracked.Output.Split('\0', StringSplitOptions.RemoveEmptyEntries);
      if (names.Length > 100000) throw new IOException("The tracked-file list exceeds the scan limit.");
      var secrets = names.Where(n => Regex.IsMatch(n.Replace('\\', '/'), @"(^|/)(\.env(\.[^/]+)?|[^/]+\.(pem|p12|pfx|jks|keystore)|id_(rsa|dsa|ecdsa|ed25519)|\.netrc|\.pgpass|secrets?\.(json|ya?ml)|credentials\.json|serviceaccount[^/]*\.json)$", RegexOptions.IgnoreCase) && !Regex.IsMatch(n, @"\.(example|sample|template|dist|defaults?)$", RegexOptions.IgnoreCase)).ToArray();
      if (secrets.Length > 0) checks.Add(new("secrets", "No secrets committed", "fail", secrets.Length + " credential-named files are tracked. Review them in Changes; ignoring a file does not remove it from old commits. No contents were read.", ".gitignore", "untrack-secrets", 30, true));
      else
      {
        var rootSecrets = Directory.EnumerateFiles(folder).Select(Path.GetFileName).Where(n => n is not null && Regex.IsMatch(n, @"^(\.env(\..+)?|id_(rsa|ed25519)|\.netrc)$|\.(pem|p12|pfx)$", RegexOptions.IgnoreCase) && !Regex.IsMatch(n, @"\.(example|sample|template)$", RegexOptions.IgnoreCase)).Cast<string>().ToArray();
        // Check each root credential name explicitly; stdin-less check-ignore cannot prove coverage.
        var exposed = false;
        foreach (var name in rootSecrets) if (!(await Git("check-ignore", "--", name)).Ok) exposed = true;
        checks.Add(new("secrets", "No secrets committed", exposed ? "warn" : "pass", exposed ? "Credential-named files exist without Git ignore coverage. No contents were read." : "Git tracks no credential-named files and root credential names are ignored.", ".gitignore", exposed ? "patch-ignore" : null, 30, true));
      }
    }
    else checks.Add(new("secrets", "No secrets committed", "warn", tracked.Missing ? "Git is unavailable; tracked credentials could not be checked." : "Tracked credentials could not be checked. Inspect Git setup and try again.", Weight: 30, Gate: true));
    var status = await Git("status", "--porcelain=v1", "-z");
    if (status.Ok)
    {
      var count = status.Output.Split('\0', StringSplitOptions.RemoveEmptyEntries).Length;
      checks.Add(new("git-clean", "Working tree is reviewable", count == 0 ? "pass" : count >= 20 ? "fail" : "warn", count + " changed file records. Inspect Changes before starting work.", Weight: 8));
    }
    else checks.Add(new("git-clean", "Working tree is reviewable", "skip", "Working-tree status could not be checked."));
    foreach (var agent in provider is null ? new[] { "claude", "codex", "gemini" } : new[] { provider! })
    {
      var result = await process.RunAsync(agent, ["--version"], folder, TimeSpan.FromSeconds(8), ct);
      checks.Add(new("provider-" + agent, agent + " command line", result.Ok ? "pass" : "warn", result.Ok ? result.Output.Trim()[..Math.Min(result.Output.Trim().Length, 160)] + ". Installed version observed; latest-version status was not checked." : "The command line could not report its version. Open Coding AIs to install or repair it.", Weight: 0));
    }
    return new(folder, DateTimeOffset.UtcNow, checks.ToArray());
  }
}
