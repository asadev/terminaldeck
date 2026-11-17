using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Accounts;

public static class AccountHomes
{
  public const string ExistingLogin = "00000000000000000000000000000000";
  public static string Resolve(AppDataRoot root, string provider, string homeId, string userProfile, bool stableInstall)
  {
    if (provider is not ("claude" or "codex" or "gemini") || !Guid.TryParseExact(homeId, "N", out _)) throw new ArgumentException("Choose an account for this AI.");
    if (homeId != ExistingLogin)
    {
      // Old MSIX app state was virtualized, while its external CLIs kept their
      // private homes at the logical path. Keep using those original homes;
      // directory or login-file existence must never select a different account.
      var directory = stableInstall && StableChannel.IsLegacyRoot(root, userProfile) &&
        string.Equals(root.DirectoryPath, StableChannel.Root(userProfile).DirectoryPath, StringComparison.OrdinalIgnoreCase)
        ? InstalledDataRoot.NamespacePath(root.DirectoryPath, userProfile) : root.DirectoryPath;
      return Path.Combine(directory, "accounts", homeId, provider);
    }
    if (!stableInstall || !string.Equals(root.DirectoryPath, StableChannel.Root(userProfile).DirectoryPath, StringComparison.OrdinalIgnoreCase))
      throw new InvalidOperationException("This test copy uses its own sign-ins. Choose a test account.");
    return provider == "gemini" ? userProfile : Path.Combine(userProfile, "." + provider);
  }
}
