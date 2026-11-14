using TerminalDeck.Core.Code;

namespace TerminalDeck.Core.Tests.Code;

public sealed class GitHubCopyIsolationTests
{
  [Fact] public void OnlyTheStableInstallOnItsOwnRootIsTheRealCopy()
  {
    // StableChannel remembers each app folder's answer, a missing marker too (a test copy can never gain access
    // later), so the unmarked and the marked install are two different folders.
    var test = Directory.CreateTempSubdirectory().FullName; var app = Directory.CreateTempSubdirectory().FullName; var profile = Directory.CreateTempSubdirectory().FullName;
    var stableRoot = Path.Combine(profile, "AppData", "Local", "TerminalDeckStable");
    File.WriteAllText(Path.Combine(app, TerminalDeck.Core.Storage.StableChannel.Marker), "");
    Assert.False(GitHubClient.IsRealCopy(stableRoot, test, profile));
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
