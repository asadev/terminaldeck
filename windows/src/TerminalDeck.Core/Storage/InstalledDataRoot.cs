using System.Text.Json;

namespace TerminalDeck.Core.Storage;

// Written once during an explicitly requested review migration. No data is moved
// or copied: keeper, sessions and credentials retain their existing namespace.
public sealed record InstalledDataRoot(string MachineName, string DirectoryPath)
{
  public const string PackageFamilyName = "TerminalDeck_6wvt5fg33ztg8";
  public static string PackageLocalCache(string userProfile) => Path.GetFullPath(Path.Combine(userProfile, "AppData", "Local", "Packages", PackageFamilyName, "LocalCache"));
  public static string NamespacePath(string path, string userProfile)
  {
    var full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
    foreach (var name in new[] { "TerminalDeck", "TerminalDeckStable" })
      if (string.Equals(full, Path.Combine(PackageLocalCache(userProfile), "Local", name), StringComparison.OrdinalIgnoreCase))
        return Path.GetFullPath(Path.Combine(userProfile, "AppData", "Local", name));
    return full;
  }
  public static bool IsInstalledPath(string path, string userProfile)
  {
    var full = Path.TrimEndingDirectorySeparator(Path.GetFullPath(path));
    foreach (var name in new[] { "TerminalDeck", "TerminalDeckStable" })
      foreach (var root in new[] { Path.GetFullPath(Path.Combine(userProfile, "AppData", "Local", name)), Path.Combine(PackageLocalCache(userProfile), "Local", name) })
        if (string.Equals(full, root, StringComparison.OrdinalIgnoreCase) || full.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return true;
    return false;
  }

  public static AppDataRoot Resolve(string localAppData, string machineName)
  {
    var standard = Path.Combine(localAppData, "TerminalDeck");
    var setting = Path.Combine(standard, "installed-data-root.json");
    if (!File.Exists(setting)) return AppDataRoot.Explicit(standard);
    var saved = JsonSerializer.Deserialize<InstalledDataRoot>(File.ReadAllText(setting))
      ?? throw new IOException("The installed data-folder setting is empty.");
    if (!string.Equals(saved.MachineName, machineName, StringComparison.OrdinalIgnoreCase)) return AppDataRoot.Explicit(standard);
    var root = AppDataRoot.Explicit(saved.DirectoryPath);
    if (!Directory.Exists(root.DirectoryPath) || !File.Exists(Path.Combine(root.DirectoryPath, "state", "sessions.json")))
      throw new IOException("The saved session folder is unavailable. Restore that folder before opening the app.");
    return root;
  }
}
