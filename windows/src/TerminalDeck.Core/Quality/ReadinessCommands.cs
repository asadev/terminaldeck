using System.Security.Cryptography;
using TerminalDeck.Core.Code;

namespace TerminalDeck.Core.Quality;

public sealed record ReadinessCommandPreview(string Token, string Folder, string Fix, string Executable, string[] Arguments, string Summary, string[] Touches, string Fingerprint, DateTimeOffset ExpiresAt, string GitState);
public sealed partial class ProjectReadiness
{
  private readonly Dictionary<string, ReadinessCommandPreview> commandPreviews = [];
  public async Task<ReadinessCommandPreview> PreviewCommandAsync(string folder, string fix, ICodeProcessRunner? process = null, CancellationToken ct = default)
  {
    folder = Root(folder); process ??= new CodeProcessRunner(); string executable; string[] arguments; string[] touches; string summary;
    switch (fix)
    {
      case "git-init": executable = "git"; arguments = ["init"]; touches = [".git"]; summary = "Initialise Git without staging or committing files."; break;
      case "create-lockfile": executable = OperatingSystem.IsWindows() ? "cmd.exe" : "npm"; arguments = OperatingSystem.IsWindows() ? ["/d", "/s", "/c", "npm install --package-lock-only --ignore-scripts"] : ["install", "--package-lock-only", "--ignore-scripts"]; touches = ["package-lock.json"]; summary = "Resolve the declared dependencies into package-lock.json. This may contact the registry; project scripts are disabled."; break;
      case "untrack-secrets":
        var report = await process.RunAsync("git", ["-C", folder, "ls-files", "-z"], folder, TimeSpan.FromSeconds(15), ct);
        if (!report.Ok) throw new IOException("Git could not establish which credential files are tracked.");
        var names = report.Output.Split('\0', StringSplitOptions.RemoveEmptyEntries).Where(n => System.Text.RegularExpressions.Regex.IsMatch(n.Replace('\\', '/'), @"(^|/)(\.env(\.[^/]+)?|[^/]+\.(pem|p12|pfx|jks|keystore)|id_(rsa|dsa|ecdsa|ed25519)|\.netrc|\.pgpass|secrets?\.(json|ya?ml)|credentials\.json|serviceaccount[^/]*\.json)$", System.Text.RegularExpressions.RegexOptions.IgnoreCase) && !System.Text.RegularExpressions.Regex.IsMatch(n, @"\.(example|sample|template|dist|defaults?)$", System.Text.RegularExpressions.RegexOptions.IgnoreCase)).ToArray();
        if (names.Length is 0 or > 1000) throw new IOException("No bounded credential-file selection is available. Inspect Changes.");
        executable = "git"; arguments = ["rm", "--cached", "--", .. names]; touches = ["git index", ".gitignore"]; summary = "Remove these credential-named files from the Git index. The files stay on disk and in old commits. Rotate any exposed credentials. Add ignore rules separately through the reviewed file fix."; break;
      default: throw new ArgumentException("Choose initialise Git, create lockfile or untrack credentials.");
    }
    var fingerprint = CommandFingerprint(folder);
    var preview = new ReadinessCommandPreview(Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(24)), folder, fix, executable, arguments, summary, touches, fingerprint, DateTimeOffset.UtcNow.AddMinutes(10), await GitStateAsync(folder, process, ct));
    lock (changeGate)
    {
      foreach (var old in commandPreviews.Values.Where(p => p.ExpiresAt <= DateTimeOffset.UtcNow).ToArray()) commandPreviews.Remove(old.Token);
      if (commandPreviews.Count >= 32) throw new InvalidOperationException("Finish an existing command review first."); commandPreviews.Add(preview.Token, preview);
    }
    return preview;
  }
  public async Task<CodeProcessResult> ApplyCommandAsync(string folder, string token, ICodeProcessRunner? process = null, CancellationToken ct = default)
  {
    folder = Root(folder); ReadinessCommandPreview preview;
    lock (changeGate)
    {
      if (!commandPreviews.Remove(token, out preview!) || preview.Folder != folder || preview.ExpiresAt <= DateTimeOffset.UtcNow) throw new InvalidOperationException("This review expired or belongs to another project. Preview again.");
    }
    process ??= new CodeProcessRunner();
    if (CommandFingerprint(folder) != preview.Fingerprint || await GitStateAsync(folder, process, ct) != preview.GitState) throw new IOException("The project metadata or Git index changed after review. Nothing was run; preview again.");
    ct.ThrowIfCancellationRequested();
    var result = await process.RunAsync(preview.Executable, preview.Arguments, folder, TimeSpan.FromMinutes(3), ct);
    if (!result.Ok) throw new IOException("The reviewed command could not finish. Check the command's tools and project state, then preview again.");
    return result;
  }
  private static async Task<string> GitStateAsync(string folder, ICodeProcessRunner process, CancellationToken ct)
  {
    var result = await process.RunAsync("git", ["-C", folder, "ls-files", "--stage", "-z"], folder, TimeSpan.FromSeconds(15), ct);
    if (result.Output.Length > 16 * 1024 * 1024) throw new IOException("The Git index exceeds the review limit.");
    return result.Ok ? Convert.ToHexStringLower(SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(result.Output))) : "unavailable:" + result.ExitCode + ":" + result.Missing;
  }
  private static string CommandFingerprint(string folder)
  {
    using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
    foreach (var file in new[] { "package.json", "package-lock.json", ".gitignore", ".git/index" })
    {
      var path = SafeFile(folder, file); hash.AppendData(System.Text.Encoding.UTF8.GetBytes(file));
      if (!File.Exists(path)) continue;
      if (new FileInfo(path).Length > 32 * 1024 * 1024) throw new IOException("The project metadata exceeds the command review limit.");
      hash.AppendData(File.ReadAllBytes(path));
    }
    return Convert.ToHexStringLower(hash.GetHashAndReset());
  }
}
