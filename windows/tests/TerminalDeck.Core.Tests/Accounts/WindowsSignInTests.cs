using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Accounts;

public sealed class WindowsSignInTests : IDisposable
{
  private readonly string folder = Path.Combine(Path.GetTempPath(), "td-signin-" + Guid.NewGuid().ToString("N"));
  private string FileAt(string relative)
  {
    var path = Path.Combine(folder, relative.Replace('/', Path.DirectorySeparatorChar)); Directory.CreateDirectory(Path.GetDirectoryName(path)!); File.WriteAllText(path, "fixture"); return path;
  }
  private Dictionary<string, string> EnvironmentPaths() => new(StringComparer.OrdinalIgnoreCase)
  { ["USERPROFILE"] = folder, ["APPDATA"] = Path.Combine(folder, "roaming"), ["LOCALAPPDATA"] = Path.Combine(folder, "local"), ["ProgramFiles"] = Path.Combine(folder, "programs"), ["PATH"] = "" };
  [Theory]
  [InlineData("claude", ".local/bin/claude.exe")]
  [InlineData("codex", "local/Microsoft/WinGet/Links/codex.exe")]
  [InlineData("claude", "local/Programs/Claude/claude.exe")]
  [InlineData("codex", "programs/Codex/bin/codex.exe")]
  [InlineData("gemini", "scoop/apps/gemini-cli/current/bin/gemini.exe")]
  public void FindsOfficialLayoutsWithoutInheritedPath(string provider, string relative)
  {
    var expected = FileAt(relative);
    var search = WindowsAiSearch.Create(EnvironmentPaths(), Path.Combine(folder, "tools"), _ => []);
    Assert.Equal(expected, InstalledAiResolver.Resolve(provider, search).Executable);
  }
  [Fact]
  public void FindsNpmViaNodeWithoutExecutingACommandWrapper()
  {
    var node = FileAt("programs/nodejs/node.exe"); var entry = FileAt("roaming/npm/node_modules/@google/gemini-cli/dist/index.js");
    FileAt("roaming/npm/gemini.cmd");
    var result = InstalledAiResolver.Resolve("gemini", WindowsAiSearch.Create(EnvironmentPaths(), Path.Combine(folder, "tools"), _ => []));
    Assert.Equal(node, result.Executable); Assert.Equal(entry, Assert.Single(result.Prefix));
  }
  [Fact]
  public void FindsWingetPackageWhenLinksAreMissing()
  {
    var expected = FileAt("local/Microsoft/WinGet/Packages/Anthropic.ClaudeCode_fixture/claude.exe");
    var search = WindowsAiSearch.Create(EnvironmentPaths(), folder, p => Directory.Exists(p) ? Directory.GetDirectories(p) : []);
    Assert.Equal(expected, InstalledAiResolver.Resolve("claude", search).Executable);
  }
  [Fact]
  public void ReadsChangedUserAndMachinePathsAtEveryCheckAndExpandsRegistryVariables()
  {
    var process = EnvironmentPaths(); process["PATH"] = Path.Combine(folder, "stale");
    var machine = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["PATH"] = "%ProgramFiles%/fresh" };
    var user = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["PATH"] = "%USERPROFILE%/new", ["TEMP"] = "%USERPROFILE%/temp" };
    var first = WindowsAiSearch.EnvironmentNow(process, machine, user);
    Assert.Contains(Path.Combine(folder, "programs") + "/fresh", first["PATH"]);
    Assert.Equal(folder + "/temp", first["TEMP"]);
    Assert.Throws<ProviderUnavailableException>(() => InstalledAiResolver.Resolve("claude", WindowsAiSearch.Create(first, folder, _ => [])));
    var executable = FileAt("installed-later/claude.exe"); user["PATH"] = Path.GetDirectoryName(executable)!;
    var second = WindowsAiSearch.EnvironmentNow(process, machine, user);
    Assert.Equal(executable, InstalledAiResolver.Resolve("claude", WindowsAiSearch.Create(second, folder, _ => [])).Executable);
  }
  [Theory]
  [InlineData("claude", ".claude")]
  [InlineData("codex", ".codex")]
  [InlineData("gemini", "")]
  public void ExistingLoginRequiresStableBinaryAndExactStableRoot(string provider, string suffix)
  {
    var stable = StableChannel.Root(folder);
    var expected = suffix.Length == 0 ? folder : Path.Combine(folder, suffix);
    Assert.Equal(expected, AccountHomes.Resolve(stable, provider, AccountHomes.ExistingLogin, folder, true));
    Assert.Throws<InvalidOperationException>(() => AccountHomes.Resolve(stable, provider, AccountHomes.ExistingLogin, folder, false));
    Assert.Throws<InvalidOperationException>(() => AccountHomes.Resolve(AppDataRoot.Explicit(folder), provider, AccountHomes.ExistingLogin, folder, true));
    var id = Guid.NewGuid().ToString("N");
    Assert.Equal(Path.Combine(folder, "accounts", id, provider), AccountHomes.Resolve(AppDataRoot.Explicit(folder), provider, id, folder, false));
  }
  [Fact]
  public async Task LoginWaitsForVerifiedIdentityAndClosesExactlyOnce()
  {
    var flow = new AccountSignInFlow(); flow.Started();
    await flow.CheckAsync(_ => Task.FromResult(false), false); Assert.False(flow.Completion.IsCompleted);
    await flow.CheckAsync(_ => Task.FromResult(true), false);
    Assert.True(await flow.Completion); Assert.Equal(AccountSignInState.Succeeded, flow.State);
    flow.Cancel(); flow.Fail("late failure"); Assert.Equal(AccountSignInState.Succeeded, flow.State);
  }
  [Theory]
  [InlineData(false)]
  [InlineData(true)]
  public async Task CliExitMustConfirmLoginEvenWhenItExitsSuccessfully(bool signedIn)
  {
    var flow = new AccountSignInFlow(); flow.Started();
    await flow.CheckAsync(_ => Task.FromResult(signedIn), true);
    Assert.Equal(signedIn, await flow.Completion);
    Assert.Equal(signedIn ? AccountSignInState.Succeeded : AccountSignInState.Failed, flow.State);
  }
  [Fact]
  public async Task CancelIgnoresAnInFlightOrLateCliSuccess()
  {
    var flow = new AccountSignInFlow(); flow.Started(); var reply = new TaskCompletionSource<bool>();
    var check = flow.CheckAsync(_ => reply.Task, false); flow.Cancel(); reply.SetResult(true); await check;
    Assert.False(await flow.Completion); Assert.Equal(AccountSignInState.Cancelled, flow.State);
  }
  [Fact]
  public async Task FakeCliFailureOffersPlainRetryMessage()
  {
    var flow = new AccountSignInFlow(); flow.Started();
    await flow.CheckAsync(_ => throw new IOException("provider detail"), true);
    Assert.False(await flow.Completion); Assert.Contains("Try", flow.Message); Assert.DoesNotContain("provider detail", flow.Message);
  }
  [Theory]
  [InlineData(false)]
  [InlineData(true)]
  public async Task DefaultIsStableAndDoesNotReplaceAnExplicitAccountChoice(bool stable)
  {
    var service = new AccountService(new TerminalDeck.Core.Tests.Sessions.MemoryState<AccountState>(), [new FakeAccountProvider("claude")]);
    var initial = await service.CreateAsync("claude", "Claude Code");
    await service.EnsureDefaultAsync("claude", stable);
    var row = service.Default("claude")!;
    Assert.Equal(initial.Id, row.Id); Assert.Equal("Default", row.Name);
    Assert.Equal(stable ? AccountHomes.ExistingLogin : initial.HomeId, row.HomeId);
    var custom = await service.CreateAsync("claude", "Work"); await service.SetDefaultAsync("claude", custom.Id);
    await service.EnsureDefaultAsync("claude", stable);
    Assert.Equal(custom.Id, service.Default("claude")!.Id); Assert.Equal(2, service.List().Count);
  }
  [Fact]
  public async Task ExistingSignedInTestDefaultKeepsItsSavedLoginAndHome()
  {
    var provider = new FakeAccountProvider("claude");
    var service = new AccountService(new TerminalDeck.Core.Tests.Sessions.MemoryState<AccountState>(), [provider]);
    var row = await service.CreateAsync("claude", "Claude Code"); provider.Statuses[row.Id] = new(true, "saved@example.test"); await service.RefreshAsync(row.Id);
    await service.EnsureDefaultAsync("claude", false);
    var saved = Assert.Single(service.List());
    Assert.Equal(row.HomeId, saved.HomeId); Assert.Equal("saved@example.test", saved.Email); Assert.True(saved.SignedIn);
    Assert.Equal(row.Id, service.Default("claude")!.Id);
  }
  [Fact]
  public async Task DefaultFollowingAnExistingLoginStaysSeparateFromAnIsolatedCopyOfTheSameEmail()
  {
    var provider = new FakeAccountProvider("claude");
    var service = new AccountService(new TerminalDeck.Core.Tests.Sessions.MemoryState<AccountState>(), [provider]);
    await service.EnsureDefaultAsync("claude", true); var following = service.Default("claude")!;
    var isolated = await service.CreateAsync("claude", "Work");
    provider.Statuses[following.Id] = new(true, "same@example.test"); provider.Statuses[isolated.Id] = new(true, "same@example.test");
    await service.RefreshAsync(isolated.Id); await service.RefreshAsync(following.Id);
    Assert.Equal(2, service.List().Count); Assert.Equal(AccountHomes.ExistingLogin, service.Get(following.Id).HomeId);
    Assert.Equal(isolated.HomeId, service.Get(isolated.Id).HomeId); Assert.Equal("Default", service.Get(following.Id).Name);
  }
  [Fact]
  public void CurrentPathChoiceWinsOverAnOlderFallbackInstallation()
  {
    FileAt(".local/bin/claude.exe"); var chosen = FileAt("chosen/claude.exe");
    var environment = EnvironmentPaths(); environment["PATH"] = Path.GetDirectoryName(chosen)!;
    Assert.Equal(chosen, InstalledAiResolver.Resolve("claude", WindowsAiSearch.Create(environment, Path.Combine(folder, "tools"), _ => [])).Executable);
  }
  [Fact]
  public async Task RenamingThePrivateDefaultDoesNotCreateAnotherLoginOnReopen()
  {
    var service = new AccountService(new TerminalDeck.Core.Tests.Sessions.MemoryState<AccountState>(), [new FakeAccountProvider("claude")]);
    await service.EnsureDefaultAsync("claude", false); var row = service.Default("claude")!;
    await service.RenameAsync(row.Id, "Personal"); await service.EnsureDefaultAsync("claude", false);
    var kept = Assert.Single(service.List()); Assert.Equal(row.Id, kept.Id); Assert.Equal(row.HomeId, kept.HomeId); Assert.Equal("Personal", kept.Name);
  }
  [Theory]
  [InlineData("claude", "CLAUDE_CONFIG_DIR")]
  [InlineData("codex", "CODEX_HOME")]
  [InlineData("gemini", "GEMINI_CLI_HOME")]
  public void InstallAndLoginChildrenUseOnlyTheSelectedAccountConfig(string provider, string variable)
  {
    var inherited = new Dictionary<string, string> { ["USERPROFILE"] = folder, ["PATH"] = "current", ["ANTHROPIC_API_KEY"] = "fake", ["OPENAI_API_KEY"] = "fake", ["GEMINI_API_KEY"] = "fake", ["CLAUDE_CONFIG_DIR"] = "normal-claude", ["CODEX_HOME"] = "normal-codex", ["GEMINI_CLI_HOME"] = "normal-gemini" };
    var environment = AccountEnvironment.Apply(provider, "private-account-home", inherited);
    Assert.Equal("private-account-home", environment[variable]); Assert.Equal(folder, environment["USERPROFILE"]); Assert.Equal("current", environment["PATH"]);
    Assert.Equal(3, environment.Count); Assert.Equal("normal-claude", inherited["CLAUDE_CONFIG_DIR"]);
  }
  [Fact]
  public async Task FailedCliExitCannotAcceptAnOlderStillSignedInLogin()
  {
    var flow = new AccountSignInFlow(); flow.Started();
    await flow.CheckAsync(_ => Task.FromResult(true), true, exitCode: 1);
    Assert.False(await flow.Completion); Assert.Equal(AccountSignInState.Failed, flow.State);
  }
  public void Dispose() { if (Directory.Exists(folder)) Directory.Delete(folder, true); }
}
