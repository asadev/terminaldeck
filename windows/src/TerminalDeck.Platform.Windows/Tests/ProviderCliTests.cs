using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Tests;

public sealed class ProviderCliTests
{
  [Theory(Timeout = 45000)]
  [InlineData("claude")]
  [InlineData("codex")]
  [InlineData("gemini")]
  public async Task InstalledCliLaunchesInRealConPtyWithoutSignIn(string provider)
  {
    var root = AppDataRoot.Explicit(Path.Combine(@"C:\TD\out\w3-cli-data", Guid.NewGuid().ToString("N")));
    WindowsPrivateDirectory.Ensure(root.DirectoryPath);
    var planner = new WindowsProviderLaunchPlanner(root, @"C:\TD\tools\ai");
    var account = Guid.NewGuid().ToString("N");
    var planned = planner.Plan(new(new(Guid.NewGuid().ToString(), provider, root.DirectoryPath, "CLI test", account), Guid.NewGuid().ToString("N"), SessionState.Starting), false);
    var launch = planner.Resolve(provider, ["--version"], planned.Environment, planned.WorkingDirectory);
    await using var terminal = await new ConPtyTerminalFactory().StartAsync(launch, new(100, 30));
    using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(30));
    var output = new StringBuilder();
    var read = Task.Run(async () =>
    {
      try { await foreach (var bytes in terminal.ReadOutputAsync(ct.Token)) output.Append(Encoding.UTF8.GetString(bytes.Span)); }
      catch (IOException) { }
    });
    Assert.Equal(0, await terminal.WaitForExitAsync(ct.Token));
    await terminal.QuitAsync(ct.Token); await read;
    Assert.Matches("[0-9]+\\.[0-9]+\\.[0-9]+", output.ToString());
    var evidence = Environment.GetEnvironmentVariable("TD_EVIDENCE_DIR");
    if (evidence is not null) File.WriteAllText(Path.Combine(evidence, provider + "-conpty.json"), JsonSerializer.Serialize(new { provider, versionOutput = output.ToString(), executable = launch.Executable, accountHome = Path.Combine(root.DirectoryPath, "accounts", account, provider), signedIn = false }));
  }
  [Fact]
  public void MergedAccountUsesItsOpaqueHomeIdentityAndRefusesExternalPaths()
  {
    var root = AppDataRoot.Explicit(Path.Combine(@"C:\TD\out\w3-cli-data", Guid.NewGuid().ToString("N")));
    WindowsPrivateDirectory.Ensure(root.DirectoryPath);
    var homeId = Guid.NewGuid().ToString("N"); var accountId = Guid.NewGuid().ToString("N");
    var definition = new SessionDefinition(Guid.NewGuid().ToString(), "codex", root.DirectoryPath, "Merged account", accountId, homeId);
    var row = new SessionRecord(definition, Guid.NewGuid().ToString("N"), SessionState.Starting);
    var planner = new WindowsProviderLaunchPlanner(root, @"C:\TD\tools\ai");
    Assert.Equal(Path.Combine(root.DirectoryPath, "accounts", homeId, "codex"), planner.Plan(row, false).Environment["CODEX_HOME"]);
    Assert.Throws<ArgumentException>(() => planner.Plan(row with { Definition = definition with { AccountHome = @"C:\someone-else" } }, false));
  }
  [Fact]
  public void ProviderHomesStayUnderEachRootAndInheritedKeysAreRemoved()
  {
    var one = AppDataRoot.Explicit(Path.Combine(@"C:\TD\out\w3-cli-data", Guid.NewGuid().ToString("N")));
    var two = AppDataRoot.Explicit(Path.Combine(@"C:\TD\out\w3-cli-data", Guid.NewGuid().ToString("N")));
    WindowsPrivateDirectory.Ensure(one.DirectoryPath); WindowsPrivateDirectory.Ensure(two.DirectoryPath);
    foreach (var provider in new[] { "claude", "codex", "gemini" })
    {
      var id = Guid.NewGuid().ToString("N");
      var row = new SessionRecord(new(Guid.NewGuid().ToString(), provider, one.DirectoryPath, "Home test", id), Guid.NewGuid().ToString("N"), SessionState.Starting);
      var a = new WindowsProviderLaunchPlanner(one, @"C:\TD\tools\ai").Plan(row, false);
      var b = new WindowsProviderLaunchPlanner(two, @"C:\TD\tools\ai").Plan(row, false);
      var variable = provider switch { "claude" => "CLAUDE_CONFIG_DIR", "codex" => "CODEX_HOME", _ => "GEMINI_CLI_HOME" };
      Assert.StartsWith(one.DirectoryPath, a.Environment[variable]); Assert.StartsWith(two.DirectoryPath, b.Environment[variable]); Assert.NotEqual(a.Environment[variable], b.Environment[variable]);
      Assert.DoesNotContain("OPENAI_API_KEY", a.Environment.Keys); Assert.DoesNotContain("ANTHROPIC_API_KEY", a.Environment.Keys); Assert.DoesNotContain("GEMINI_API_KEY", a.Environment.Keys);
    }
  }
}
