using System.Text.Json;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows.Accounts;

namespace TerminalDeck.Platform.Windows.Tests;

public sealed class V3cModelTests
{
  [Theory]
  [InlineData("claude")]
  [InlineData("codex")]
  [InlineData("gemini")]
  public async Task StartupProtocolDiscoversModelsWithoutPromptsOrAuthentication(string provider)
  {
    var home = Path.Combine(Path.GetTempPath(), "td-v3c-models", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(home);
    try
    {
      var fixture = Path.Combine(home, "models.ps1");
      await File.WriteAllTextAsync(fixture, """
        param($Provider)
        while ($line = [Console]::ReadLine()) {
          $message = $line | ConvertFrom-Json
          if ($Provider -eq 'claude') {
            Add-Content 'requests.txt' $message.request.subtype
            @{type='control_response';response=@{subtype='success';request_id=$message.request_id;response=@{models=@(@{value='reported[1m]';displayName='Reported 1M'})}}} | ConvertTo-Json -Depth 10 -Compress | ForEach-Object { [Console]::WriteLine($_) }
          } else {
            Add-Content 'requests.txt' $message.method
            if ($message.method -eq 'initialized') { continue }
            if ($message.method -eq 'initialize') { $result = @{} }
            elseif ($Provider -eq 'codex' -and $message.method -eq 'model/list') { $result = @{data=@(@{model='reported';displayName='Reported'});nextCursor=$null} }
            elseif ($Provider -eq 'gemini' -and $message.method -eq 'session/new') { $result = @{models=@{availableModels=@(@{modelId='reported';name='Reported'})}} }
            else { exit 31 }
            @{id=$message.id;result=$result} | ConvertTo-Json -Depth 10 -Compress | ForEach-Object { [Console]::WriteLine($_) }
          }
        }
        """);
      var shell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe");
      using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(15));
      var models = await WindowsModelDiscovery.DiscoverAsync(provider, new ProcessLaunch(shell, ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", fixture, provider], new Dictionary<string, string> { ["SystemRoot"] = Environment.GetEnvironmentVariable("SystemRoot")! }, home), deadline.Token);
      Assert.Single(models);
      var methods = await File.ReadAllLinesAsync(Path.Combine(home, "requests.txt"));
      Assert.Equal(provider == "claude" ? new[] { "initialize" } : provider == "codex" ? ["initialize", "initialized", "model/list"] : ["initialize", "session/new"], methods);
    }
    finally { Directory.Delete(home, true); }
  }
  [Theory]
  [InlineData("claude")]
  [InlineData("codex")]
  [InlineData("gemini")]
  public async Task SignInAlwaysUsesTheAccountsScratchFolder(string provider)
  {
    var path = Path.Combine(Path.GetTempPath(), "td-v3c-signin", Guid.NewGuid().ToString("N"));
    try
    {
      var root = AppDataRoot.Explicit(path); var id = Guid.NewGuid().ToString("N");
      string? opened = null;
      using var adapter = new WindowsAccountProvider(provider, root, path, (_, folder) => { opened = folder; return Task.CompletedTask; });
      var account = new AccountProfile(id, provider, "Fixture", null, AccountAuthentication.Subscription, false, id);
      await adapter.SignInAsync(account, Path.GetTempPath(), CancellationToken.None);
      Assert.Equal(Path.Combine(path, "accounts", id, provider), opened);
      await Assert.ThrowsAsync<ArgumentException>(async () => await adapter.SignInAsync(account with { HomeId = "../real-home" }, path, CancellationToken.None));
    }
    finally { if (Directory.Exists(path)) Directory.Delete(path, true); }
  }
  [Fact]
  public void CodexCapacitiesUseOnlyTheSelectedHomesMatchingModel()
  {
    var home = Path.Combine(Path.GetTempPath(), "td-v3c-capacity", Guid.NewGuid().ToString("N")); Directory.CreateDirectory(home);
    try
    {
      File.WriteAllText(Path.Combine(home, "models_cache.json"), "{\"models\":[{\"slug\":\"long\",\"context_window\":1050000},{\"slug\":\"not-offered\",\"context_window\":1000000}]}");
      var rows = WindowsModelDiscovery.WithCodexCapacities([new("long", "Long", 0), new("other", "Other", 0)], home);
      Assert.True(rows[0].SupportsOneMillion); Assert.Equal(0, rows[1].ContextTokens); Assert.Equal(2, rows.Count);
    }
    finally { Directory.Delete(home, true); }
  }
  [Theory]
  [InlineData("claude", "{\"models\":[{\"value\":\"sonnet\",\"displayName\":\"Sonnet\"},{\"value\":\"sonnet[1m]\",\"displayName\":\"Sonnet (1M)\"}]}")]
  [InlineData("codex", "{\"data\":[{\"id\":\"picker-id\",\"model\":\"sol\",\"displayName\":\"Sol\"},{\"model\":\"sol-long\",\"contextWindow\":1050000}]}")]
  [InlineData("gemini", "{\"models\":{\"availableModels\":[{\"modelId\":\"auto\",\"name\":\"Automatic\"},{\"modelId\":\"gemini-long\",\"inputTokenLimit\":1048576}]}}")]
  public void StartupListsKeepExactSelectableIdsAndOnlyReportedLongContext(string provider, string json)
  {
    using var document = JsonDocument.Parse(json); var rows = WindowsModelDiscovery.Parse(provider, document.RootElement);
    Assert.Equal(2, rows.Count); Assert.Equal(0, rows[0].ContextTokens); Assert.False(rows[0].SupportsOneMillion);
    Assert.True(rows[1].SupportsOneMillion); Assert.True(rows[1].ContextTokens >= 1_000_000);
    if (provider == "codex") Assert.Equal("sol", rows[0].Id);
    if (provider == "claude") Assert.Equal("sonnet[1m]", rows[1].Id);
  }
  [Theory]
  [InlineData("{\"data\":[]}")]
  [InlineData("{\"data\":[{\"model\":\"duplicate\"},{\"model\":\"duplicate\"}]}")]
  [InlineData("{\"data\":[{\"model\":\"hidden\",\"hidden\":true}]}")]
  [InlineData("{\"data\":[{\"model\":\"bad\\nvalue\"}]}")]
  public void UnusableCataloguesAreRefused(string json)
  {
    using var document = JsonDocument.Parse(json);
    Assert.Throws<IOException>(() => WindowsModelDiscovery.Parse("codex", document.RootElement));
  }
}
