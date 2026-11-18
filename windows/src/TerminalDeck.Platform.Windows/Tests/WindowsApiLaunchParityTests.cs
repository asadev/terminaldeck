using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows.Accounts;

namespace TerminalDeck.Platform.Windows.Tests;

public sealed class WindowsApiLaunchParityTests : IDisposable
{
  private readonly AppDataRoot root = AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "td-api-launch-" + Guid.NewGuid().ToString("N")));

  [Theory]
  [InlineData("invalid")]
  [InlineData("no-access")]
  [InlineData("needs-key")]
  [InlineData("unreadable")]
  public void RefusedApiAccountCannotFallThroughToSubscriptionLogin(string state)
  {
    var home = Guid.NewGuid().ToString("N");
    ApiAccountFiles.Write(root, home, new(ApiKinds.Anthropic, CredentialReference: Guid.NewGuid().ToString("N"), CheckState: state));
    Assert.Throws<ApiAccountUnavailableException>(() => WindowsApiAccountLaunch.Apply(root, "claude", home, new Dictionary<string, string>()));
  }

  [Fact] public void MissingApiConnectionCannotOpenASubscriptionSignIn()
  {
    var home = Guid.NewGuid().ToString("N");
    new JsonStateStore<AccountState>(root, "accounts").Save(new(1, [new(home, "claude", "API fixture", null, AccountAuthentication.ApiKey, true, home)], [], []));
    Assert.Throws<ApiAccountUnavailableException>(() => WindowsApiAccountLaunch.Apply(root, "claude", home, new Dictionary<string, string>()));
  }

  [Fact] public void UncheckedSubscriptionHomeKeepsItsOwnEnvironment()
  {
    var environment = new Dictionary<string, string> { ["CLAUDE_CONFIG_DIR"] = "isolated-fixture" };
    Assert.Same(environment, WindowsApiAccountLaunch.Apply(root, "claude", Guid.NewGuid().ToString("N"), environment).Environment);
  }

  public void Dispose() { if (Directory.Exists(root.DirectoryPath)) Directory.Delete(root.DirectoryPath, true); }
}
