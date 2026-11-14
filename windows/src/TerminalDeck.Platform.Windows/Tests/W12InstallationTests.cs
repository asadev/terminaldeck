using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Tests;

public sealed class W12InstallationTests
{
  [Trait("Group", "RealPc")] [Theory(Timeout = 90000)]
  [InlineData("claude")]
  [InlineData("codex")]
  [InlineData("gemini")]
  public async Task ReadsInstalledVersionWithoutStartingSignInOrCreatingAConversation(string name)
  {
    var root = AppDataRoot.Explicit(Path.Combine(@"C:\TD-SettingsProof", "installation-" + Guid.NewGuid().ToString("N")));
    Directory.CreateDirectory(root.DirectoryPath);
    var signIns = 0;
    using var provider = new WindowsAccountProvider(name, root, @"C:\TD\tools\ai", (_, _) => { signIns++; return Task.CompletedTask; });
    var id = Guid.NewGuid().ToString("N");
    var account = new AccountProfile(id, name, "Audit account", null, AccountAuthentication.Subscription, false, id);
    var status = await provider.InstallationAsync(account, CancellationToken.None);
    Assert.True(status.Installed); Assert.Matches(@"\d+\.\d+\.\d+", status.Version ?? ""); Assert.Equal(0, signIns);
    Assert.False(account.SignedIn);
    Assert.False(File.Exists(Path.Combine(root.DirectoryPath, "accounts.json")));
  }
}
