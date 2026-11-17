using System.Text.Json;

namespace TerminalDeck.Core.Storage;

// A package's saved files can move without changing its credential/pipe namespace.
public static class StableChannel
{
  public const string Marker = "terminaldeck-stable-channel";
  private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, bool> identities = new(StringComparer.OrdinalIgnoreCase);
  private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, AppDataRoot> installedRoots = new(StringComparer.OrdinalIgnoreCase);
  // Windows can retire the old package's marker while its keeper still owns
  // terminals. Install identity belongs to the running process: losing that
  // file must not turn its next existing-login launch into a test-copy refusal.
  // Remember a missing marker too, so a test copy cannot gain access later.
  public static bool IsStable(string directory) => identities.GetOrAdd(Path.GetFullPath(directory),
    path => File.Exists(Path.Combine(path, Marker)));
  private static AppDataRoot DefaultRoot(string userProfile) => AppDataRoot.Explicit(Path.Combine(userProfile, "AppData", "Local", "TerminalDeckStable"));
  private static AppDataRoot LegacyRoot(string userProfile) => AppDataRoot.Explicit(Path.Combine(userProfile, "AppData", "Local", "TerminalDeck"));
  private static bool HasSavedState(string directory) => new[] { "sessions", "accounts", "projects" }.Any(name => File.Exists(Path.Combine(directory, "state", name + ".json")));
  public static bool IsLegacyRoot(AppDataRoot root, string userProfile) => string.Equals(InstalledDataRoot.NamespacePath(root.DirectoryPath, userProfile), LegacyRoot(userProfile).DirectoryPath, StringComparison.OrdinalIgnoreCase);
  public static AppDataRoot Root(string userProfile) => installedRoots.TryGetValue(Path.GetFullPath(userProfile), out var root) ? root : DefaultRoot(userProfile);
  public static AppDataRoot Resolve(string? explicitPath, string userProfile, string? packageLocalCache = null)
  {
    var key = Path.GetFullPath(userProfile);
    var root = Root(userProfile);
    if (!installedRoots.ContainsKey(key))
    {
      var cache = InstalledDataRoot.PackageLocalCache(userProfile);
      var cachedLegacy = Path.Combine(cache, "Local", "TerminalDeck");
      var cachedStable = Path.Combine(cache, "Local", "TerminalDeckStable");
      // A deliberate, machine-bound receipt beats an unrelated newer install.
      // This code never creates or changes that receipt or moves any saved data.
      if (packageLocalCache is not null)
      {
        if (!string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(packageLocalCache)), cache, StringComparison.OrdinalIgnoreCase))
          throw new IOException("The installed package's data folder does not match its identity.");
        AppDataRoot? received = null;
        foreach (var directory in new[] { cachedLegacy, cachedStable })
        {
          var receipt = Path.Combine(directory, "installed-data-root.json");
          if (!File.Exists(receipt)) continue;
          InstalledDataRoot saved;
          try { saved = JsonSerializer.Deserialize<InstalledDataRoot>(File.ReadAllText(receipt)) ?? throw new IOException("The installed data-folder setting is empty."); }
          catch (JsonException) { throw new IOException("The installed data-folder setting could not be read."); }
          if (!string.Equals(saved.MachineName, Environment.MachineName, StringComparison.OrdinalIgnoreCase)) continue;
          var target = AppDataRoot.Installed(saved.DirectoryPath, userProfile);
          if ((!string.Equals(target.DirectoryPath, cachedLegacy, StringComparison.OrdinalIgnoreCase) && !string.Equals(target.DirectoryPath, cachedStable, StringComparison.OrdinalIgnoreCase)) || !HasSavedState(target.DirectoryPath))
            throw new IOException("The saved package data folder is unavailable or belongs to another install.");
          if (received is not null && !string.Equals(received.DirectoryPath, target.DirectoryPath, StringComparison.OrdinalIgnoreCase))
            throw new IOException("The package has conflicting saved data-folder settings.");
          received = target;
        }
        root = received ?? (HasSavedState(root.DirectoryPath) ? root : HasSavedState(cachedStable) ? AppDataRoot.Installed(cachedStable, userProfile)
          : HasSavedState(cachedLegacy) ? AppDataRoot.Installed(cachedLegacy, userProfile) : root);
      }
      // A keeper or chat worker receives its owner's exact physical root. Its
      // canonical namespace is unchanged, including the private credential name.
      if (explicitPath is not null)
      {
        var requested = AppDataRoot.Installed(explicitPath, userProfile);
        var namespacePath = InstalledDataRoot.NamespacePath(requested.DirectoryPath, userProfile);
        var canonicalPhysical = !string.Equals(namespacePath, requested.DirectoryPath, StringComparison.OrdinalIgnoreCase);
        if ((canonicalPhysical || string.Equals(requested.DirectoryPath, LegacyRoot(userProfile).DirectoryPath, StringComparison.OrdinalIgnoreCase)) && HasSavedState(requested.DirectoryPath)) root = requested;
      }
    }
    if (explicitPath is not null && !string.Equals(AppDataRoot.Explicit(explicitPath).DirectoryPath, root.DirectoryPath, StringComparison.OrdinalIgnoreCase))
      throw new ArgumentException("The stable channel uses its own saved-data folder.");
    var pinned = installedRoots.GetOrAdd(key, root);
    if (!string.Equals(root.DirectoryPath, pinned.DirectoryPath, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("This process already selected another installed data folder.");
    return pinned;
  }
}
