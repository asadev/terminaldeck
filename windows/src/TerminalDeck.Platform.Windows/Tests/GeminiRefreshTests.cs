using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows.Accounts;

namespace TerminalDeck.Platform.Windows.Tests;

public sealed class GeminiRefreshTests
{
  [Theory]
  [InlineData(true)]
  [InlineData(false)]
  public async Task ExpiredAccessTokenUsesProviderRefreshInsteadOfForcingSignIn(bool accepted)
  {
    using var fixture = new Fixture(); var check = new Check(accepted);
    var provider = new WindowsAccountProvider("gemini", fixture.Root, fixture.Tools, (_, _) => throw new InvalidOperationException("No interactive sign-in."), check);
    var result = await provider.StatusAsync(fixture.Account, default);
    Assert.Equal(accepted, result.SignedIn); Assert.Equal(1, check.Calls);
    Assert.Equal(accepted ? "fixture@example.invalid" : null, result.Email);
    Assert.Equal(fixture.Home, check.Launch!.Environment["GEMINI_CLI_HOME"]);
    Assert.Equal(["--acp"], check.Launch.Arguments); Assert.DoesNotContain("prompt", string.Join(' ', check.Launch.Arguments));
  }
  [Fact]
  public async Task ConnectionFailureKeepsTheSavedAccountStateAndRequiresARefreshRetry()
  {
    using var fixture = new Fixture(); var check = new Check(true) { Fail = true };
    var provider = new WindowsAccountProvider("gemini", fixture.Root, fixture.Tools, (_, _) => Task.CompletedTask, check);
    var service = new AccountService(new JsonStateStore<AccountState>(fixture.Root, "accounts"), [provider]);
    var account = await service.CreateAsync("gemini", "Fixture");
    var actualHome = Path.Combine(fixture.Root.DirectoryPath, "accounts", account.HomeId, "gemini", ".gemini"); Directory.CreateDirectory(actualHome);
    File.Copy(Path.Combine(fixture.Home, ".gemini", "oauth_creds.json"), Path.Combine(actualHome, "oauth_creds.json"));
    File.Copy(Path.Combine(fixture.Home, ".gemini", "google_accounts.json"), Path.Combine(actualHome, "google_accounts.json"));
    await Assert.ThrowsAsync<IOException>(async () => await service.RefreshAsync(account.Id));
    Assert.Equal(account, service.Get(account.Id)); Assert.Equal(1, check.Calls);
  }
  [Fact]
  public async Task MissingCredentialsAndDifferentAuthTypesNeverStartARefreshOrSwitchLogin()
  {
    using var fixture = new Fixture(); var check = new Check(true);
    var provider = new WindowsAccountProvider("gemini", fixture.Root, fixture.Tools, (_, _) => Task.CompletedTask, check);
    File.WriteAllText(Path.Combine(fixture.Home, ".gemini", "settings.json"), "{\"security\":{\"auth\":{\"selectedType\":\"gemini-api-key\"}}}");
    Assert.False((await provider.StatusAsync(fixture.Account, default)).SignedIn);
    File.Delete(Path.Combine(fixture.Home, ".gemini", "oauth_creds.json"));
    Assert.False((await provider.StatusAsync(fixture.Account, default)).SignedIn); Assert.Equal(0, check.Calls);
  }
  [Theory]
  [InlineData("ok")]
  [InlineData("rejected")]
  [InlineData("malformed")]
  [InlineData("unsupported")]
  [InlineData("requested-tool")]
  public async Task ActualChildProtocolOnlyInitializesAndAuthenticatesWithoutAModelPrompt(string outcome)
  {
    using var fixture = new Fixture(); var script = Path.Combine(fixture.Root.DirectoryPath, "readiness-fixture.ps1");
    var transcript = Path.Combine(fixture.Root.DirectoryPath, "methods.txt");
    File.WriteAllText(script, """
      $ErrorActionPreference='Stop'
      if ($env:NO_BROWSER -ne 'true') { exit 7 }
      $hello = [Console]::ReadLine() | ConvertFrom-Json
      $hello.method | Set-Content -LiteralPath $env:TD_FIXTURE_METHODS
      [Console]::WriteLine('{"jsonrpc":"2.0","id":"account-hello","result":{"protocolVersion":1,"authMethods":[{"id":"oauth-personal"}]}}')
      $auth = [Console]::ReadLine() | ConvertFrom-Json
      $auth.method | Add-Content -LiteralPath $env:TD_FIXTURE_METHODS
      if ($auth.params.methodId -ne 'oauth-personal') { exit 8 }
      switch ($env:TD_FIXTURE_OUTCOME) {
        'ok' { [Console]::WriteLine('{"jsonrpc":"2.0","id":"account-auth","result":{}}') }
        'rejected' { [Console]::WriteLine('{"jsonrpc":"2.0","id":"account-auth","error":{"code":-32000,"message":"Synthetic auth refusal"}}') }
        'malformed' { [Console]::WriteLine('not json') }
        'unsupported' { [Console]::WriteLine('{"jsonrpc":"2.0","id":"account-auth","error":{"code":-32601,"message":"Synthetic missing method"}}') }
        'requested-tool' { [Console]::WriteLine('{"jsonrpc":"2.0","id":5,"method":"session/request_permission","params":{}}') }
      }
      Start-Sleep -Seconds 45
      """);
    var environment = new Dictionary<string, string>
    {
      ["SystemRoot"] = Environment.GetFolderPath(Environment.SpecialFolder.Windows),
      ["TD_FIXTURE_METHODS"] = transcript, ["TD_FIXTURE_OUTCOME"] = outcome
    };
    var launch = new ProcessLaunch(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"),
      ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script], environment, fixture.Root.DirectoryPath);
    var readiness = new GeminiAccountReadiness(); using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(10));
    if (outcome is "ok" or "rejected") Assert.Equal(outcome == "ok", await readiness.VerifyAsync(launch, ct.Token));
    else await Assert.ThrowsAsync<IOException>(async () => await readiness.VerifyAsync(launch, ct.Token));
    Assert.Equal(["initialize", "authenticate"], File.ReadAllLines(transcript));
  }
  private sealed class Check(bool accepted) : IGeminiAccountReadiness
  {
    public int Calls; public bool Fail; public ProcessLaunch? Launch;
    public ValueTask<bool> VerifyAsync(ProcessLaunch launch, CancellationToken ct)
    {
      ct.ThrowIfCancellationRequested(); Calls++; Launch = launch;
      if (Fail) throw new IOException("Synthetic offline provider.");
      return ValueTask.FromResult(accepted);
    }
  }
  private sealed class Fixture : IDisposable
  {
    public AppDataRoot Root = AppDataRoot.Explicit(Path.Combine(@"C:\TD\out\v3a-gemini-tests", Guid.NewGuid().ToString("N")));
    public AccountProfile Account;
    public string Tools;
    public string Home;
    public Fixture()
    {
      var id = Guid.NewGuid().ToString("N"); Account = new(id, "gemini", "Fixture", null, AccountAuthentication.Subscription, false, id);
      Tools = Path.Combine(Root.DirectoryPath, "tools"); Directory.CreateDirectory(Tools); File.WriteAllBytes(Path.Combine(Tools, "gemini.exe"), []);
      Home = Path.Combine(Root.DirectoryPath, "accounts", id, "gemini"); Directory.CreateDirectory(Path.Combine(Home, ".gemini"));
      File.WriteAllText(Path.Combine(Home, ".gemini", "oauth_creds.json"), JsonSerializer.Serialize(new { access_token = "synthetic-expired", refresh_token = "synthetic-refresh", expiry_date = 1 }));
      File.WriteAllText(Path.Combine(Home, ".gemini", "google_accounts.json"), "{\"active\":\"fixture@example.invalid\"}");
    }
    public void Dispose() => Directory.Delete(Root.DirectoryPath, true);
  }
}
