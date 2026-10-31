using System.Text.Json;

namespace TerminalDeck.Core.Storage;

// Written once during an explicitly requested review migration. No data is moved
// or copied: keeper, sessions and credentials retain their existing namespace.
public sealed record InstalledDataRoot(string MachineName, string DirectoryPath)
{
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
