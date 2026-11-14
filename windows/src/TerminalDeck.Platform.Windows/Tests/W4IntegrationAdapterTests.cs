using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Tests;

public sealed class W4IntegrationAdapterTests : IDisposable
{
  private readonly AppDataRoot root = AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "td-w4-status-" + Guid.NewGuid().ToString("N")));
  public W4IntegrationAdapterTests() => Directory.CreateDirectory(root.DirectoryPath);
  [Trait("Group", "RealPc")] [Theory]
  [InlineData("claude")]
  [InlineData("codex")]
  [InlineData("gemini")]
  public async Task EmptyIsolatedHomeIsSignedOutWithoutStartingSignIn(string provider)
  {
    var started = false;
    var adapter = new WindowsAccountProvider(provider, root, @"C:\TD\tools\ai", (_, _) => { started = true; return Task.CompletedTask; });
    var id = Guid.NewGuid().ToString("N");
    var status = await adapter.StatusAsync(new(id, provider, "W4", null, AccountAuthentication.Subscription, false, id), CancellationToken.None);
    Assert.False(status.SignedIn); Assert.Null(status.Email); Assert.False(started);
  }
  [Trait("Group", "RealPc")] [Fact]
  public void ShellUsesPowerShellAndCodexPinsItsCredentialBackend()
  {
    var planner = new WindowsProviderLaunchPlanner(root, @"C:\TD\tools\ai");
    var shell = planner.Plan(new(new(Guid.NewGuid().ToString(), "shell", root.DirectoryPath, "W4"), "test", SessionState.Starting), false);
    Assert.EndsWith("powershell.exe", shell.Executable, StringComparison.OrdinalIgnoreCase);
    var codex = planner.Resolve("codex", ["login", "status"], new Dictionary<string, string>(), root.DirectoryPath);
    Assert.Contains("cli_auth_credentials_store=\"file\"", codex.Arguments);
  }
  [Fact]
  public async Task SignInRoutesOnlyToTheSelectedAccountAndIsolatedProviderHome()
  {
    AccountProfile? selected = null; string? folder = null;
    using var adapter = new WindowsAccountProvider("codex", root, @"C:\TD\tools\ai", (account, working) => { selected = account; folder = working; return Task.CompletedTask; });
    var id = Guid.NewGuid().ToString("N"); var home = Guid.NewGuid().ToString("N");
    var account = new AccountProfile(id, "codex", "W4", null, AccountAuthentication.Subscription, false, home);
    await adapter.SignInAsync(account, root.DirectoryPath, CancellationToken.None);
    Assert.Same(account, selected); Assert.Equal(Path.Combine(root.DirectoryPath, "accounts", home, "codex"), folder);
    Assert.NotEqual(root.DirectoryPath, folder); Assert.True(Directory.Exists(folder));
  }
  public void Dispose() { if (Directory.Exists(root.DirectoryPath)) Directory.Delete(root.DirectoryPath, true); }
}
