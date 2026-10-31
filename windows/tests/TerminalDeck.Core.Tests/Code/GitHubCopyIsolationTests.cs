using TerminalDeck.Core.Code;

namespace TerminalDeck.Core.Tests.Code;

public sealed class GitHubCopyIsolationTests
{
  [Fact] public void OnlyTheStableInstallOnItsOwnRootIsTheRealCopy()
  {
    var app = Directory.CreateTempSubdirectory().FullName; var profile = Directory.CreateTempSubdirectory().FullName;
    var stableRoot = Path.Combine(profile, "AppData", "Local", "TerminalDeckStable");
    Assert.False(GitHubClient.IsRealCopy(stableRoot, app, profile));
    File.WriteAllText(Path.Combine(app, TerminalDeck.Core.Storage.StableChannel.Marker), "");
    Assert.True(GitHubClient.IsRealCopy(stableRoot, app, profile));
    Assert.False(GitHubClient.IsRealCopy(Path.Combine(profile, "scratch"), app, profile));
  }
  [Fact] public async Task TestCopyNeverReportsAnInheritedTokenAsItsSignIn()
  {
    var runner = new Recording();
    var client = new GitHubClient(runner, name => name == "GH_TOKEN" ? null : null);
    var state = await client.AuthAsync();
    Assert.Equal("none", state.Source);
  }
  private sealed class Recording : ICodeProcessRunner
  {
    public Task<CodeProcessResult> RunAsync(string executable, IReadOnlyList<string> arguments, string workingDirectory, TimeSpan timeout, CancellationToken ct, string? input = null)
      => Task.FromResult(new CodeProcessResult(1, "", "not logged in"));
  }
}
