namespace TerminalDeck.Core.Storage;

// The publisher/package family may change. This directory and its namespace must not.
public static class StableChannel
{
  public const string Marker = "terminaldeck-stable-channel";
  public static bool IsStable(string directory) => File.Exists(Path.Combine(directory, Marker));
  public static AppDataRoot Root(string userProfile) => AppDataRoot.Explicit(Path.Combine(userProfile, "AppData", "Local", "TerminalDeckStable"));
  public static AppDataRoot Resolve(string? explicitPath, string userProfile)
  {
    var root = Root(userProfile);
    if (explicitPath is not null && !string.Equals(AppDataRoot.Explicit(explicitPath).DirectoryPath, root.DirectoryPath, StringComparison.OrdinalIgnoreCase))
      throw new ArgumentException("The stable channel uses its own saved-data folder.");
    return root;
  }
}
