namespace TerminalDeck.Core.Storage;

// The publisher/package family may change. This directory and its namespace must not.
public static class StableChannel
{
  public const string Marker = "terminaldeck-stable-channel";
  private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, bool> identities = new(StringComparer.OrdinalIgnoreCase);
  // Windows can retire the old package's marker while its keeper still owns
  // terminals. Install identity belongs to the running process: losing that
  // file must not turn its next existing-login launch into a test-copy refusal.
  // Remember a missing marker too, so a test copy cannot gain access later.
  public static bool IsStable(string directory) => identities.GetOrAdd(Path.GetFullPath(directory),
    path => File.Exists(Path.Combine(path, Marker)));
  public static AppDataRoot Root(string userProfile) => AppDataRoot.Explicit(Path.Combine(userProfile, "AppData", "Local", "TerminalDeckStable"));
  public static AppDataRoot Resolve(string? explicitPath, string userProfile)
  {
    var root = Root(userProfile);
    if (explicitPath is not null && !string.Equals(AppDataRoot.Explicit(explicitPath).DirectoryPath, root.DirectoryPath, StringComparison.OrdinalIgnoreCase))
      throw new ArgumentException("The stable channel uses its own saved-data folder.");
    return root;
  }
}
