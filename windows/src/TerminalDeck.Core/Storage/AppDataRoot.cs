using System.Security.Cryptography;
using System.Text;

namespace TerminalDeck.Core.Storage;

// Constructing a root performs no IO. Developer launches must name a scratch root.
public sealed class AppDataRoot
{
  public string DirectoryPath { get; }
  public string NamespaceId { get; }

  private AppDataRoot(string path, string? userProfile = null)
  {
    DirectoryPath = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
    var namespacePath = InstalledDataRoot.NamespacePath(DirectoryPath, userProfile ?? Environment.GetFolderPath(Environment.SpecialFolder.UserProfile));
    var identity = OperatingSystem.IsWindows() ? namespacePath.ToUpperInvariant() : namespacePath;
    NamespaceId = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(identity)))[..24];
  }

  internal static AppDataRoot Installed(string path, string userProfile)
  {
    _ = Explicit(path);
    return new AppDataRoot(path, userProfile);
  }

  public static AppDataRoot Explicit(string path)
  {
    if (string.IsNullOrWhiteSpace(path) || !Path.IsPathFullyQualified(path) || path.Contains('\0'))
      throw new ArgumentException("Choose an absolute scratch data folder.", nameof(path));
    return new AppDataRoot(path);
  }

  public static AppDataRoot FromArguments(string[] args, bool development = false, string? packageLocalCache = null)
  {
    string? value = null;
    for (var i = 0; i < args.Length; i++)
    {
      if (args[i].StartsWith("--user-data-dir=", StringComparison.Ordinal))
      {
        if (value is not null) throw new ArgumentException("Choose only one data folder.");
        value = args[i][16..];
      }
      else if (args[i] == "--user-data-dir")
      {
        if (value is not null || ++i >= args.Length) throw new ArgumentException("Choose one data folder.");
        value = args[i];
      }
      else throw new ArgumentException("This scaffold only accepts --user-data-dir.");
    }
    if (StableChannel.IsStable(AppContext.BaseDirectory))
      return StableChannel.Resolve(value, Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), packageLocalCache);
    if (value is not null) return Explicit(value);
    if (development) throw new ArgumentException("This development run needs --user-data-dir with a separate scratch folder.");
    return InstalledDataRoot.Resolve(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), Environment.MachineName);
  }
}
