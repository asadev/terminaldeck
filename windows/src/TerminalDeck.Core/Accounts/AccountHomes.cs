using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Accounts;

public static class AccountHomes
{
  public const string ExistingLogin = "00000000000000000000000000000000";
  public static string Resolve(AppDataRoot root, string provider, string homeId, string userProfile, bool stableInstall)
  {
    if (provider is not ("claude" or "codex" or "gemini") || !Guid.TryParseExact(homeId, "N", out _)) throw new ArgumentException("Choose an account for this AI.");
    if (homeId != ExistingLogin) return Path.Combine(root.DirectoryPath, "accounts", homeId, provider);
    if (!stableInstall || !string.Equals(root.DirectoryPath, StableChannel.Root(userProfile).DirectoryPath, StringComparison.OrdinalIgnoreCase))
      throw new InvalidOperationException("This test copy uses its own sign-ins. Choose a test account.");
    return provider == "gemini" ? userProfile : Path.Combine(userProfile, "." + provider);
  }
}
