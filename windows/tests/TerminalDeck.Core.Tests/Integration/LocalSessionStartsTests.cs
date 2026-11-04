using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Settings;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Integration
{
  public sealed class LocalSessionStartsTests
  {
    [Theory]
    [InlineData(null, "powershell")]
    [InlineData("powershell", "powershell")]
    [InlineData("cmd", "cmd")]
    [InlineData("pwsh", "pwsh")]
    public async Task PhoneAndWebLocalStartsResolveTheCurrentDefault(string? preference, string expected)
    {
      using var fixture = new Fixture(preference);
      // Both clients use PhoneSessionsHost.StartTerminalAsync, which supplies no shell.
      var phone = await fixture.Runtime.StartAsync("shell", fixture.Folder, title: "Terminal");
      var web = await fixture.Runtime.StartAsync("shell", fixture.Folder, title: "Terminal");
      Assert.Equal(expected, phone.Definition.Shell);
      Assert.Equal(expected, web.Definition.Shell);
      Assert.Equal(2, fixture.Runtime.Refreshes);
      Assert.All(fixture.Runtime.Keeper.Created, definition => definition.Validate());
    }

    [Fact]
    public async Task ExplicitChoiceWinsAndPreferenceChangesOnlyAffectNewSessions()
    {
      using var fixture = new Fixture(TerminalShells.CommandPrompt);
      var original = await fixture.Runtime.StartAsync("shell", fixture.Folder);
      var explicitChoice = await fixture.Runtime.StartAsync("shell", fixture.Folder, shell: TerminalShells.WindowsPowerShell);
      fixture.Runtime.General.Save(new(TerminalShell: TerminalShells.PowerShell7));
      var next = await fixture.Runtime.StartAsync("shell", fixture.Folder);
      Assert.Equal(TerminalShells.CommandPrompt, original.Definition.Shell);
      Assert.Equal(TerminalShells.WindowsPowerShell, explicitChoice.Definition.Shell);
      Assert.Equal(TerminalShells.PowerShell7, next.Definition.Shell);
      Assert.Equal("Command Prompt", original.Definition.Title);
      Assert.Equal("PowerShell 7", next.Definition.Title);
    }

    private sealed class Fixture : IDisposable
    {
      public string Folder { get; } = Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "fixes-28-shell-" + Guid.NewGuid())).FullName;
      public TerminalDeck.App.Integration.AppRuntime Runtime { get; }
      public Fixture(string? preference)
      {
        var settings = new GeneralSettings(new JsonStateStore<GeneralPreferences>(AppDataRoot.Explicit(Folder), "general-settings"));
        settings.Save(new(TerminalShell: preference));
        Runtime = new(settings);
      }
      public void Dispose() => Directory.Delete(Folder, true);
    }
  }
}

// The linked production launch method owns resolution. Only persistence/process
// boundaries are fake; no real settings, accounts or sessions are touched.
namespace TerminalDeck.App.Integration
{
  public sealed partial class AppRuntime(GeneralSettings general)
  {
    public GeneralSettings General { get; } = general;
    public RecordingKeeper Keeper { get; } = new();
    public int Refreshes { get; private set; }
    public AccountService Accounts => throw new InvalidOperationException("A shell must not read accounts.");
    private Task RefreshSessionsAsync() { Refreshes++; return Task.CompletedTask; }
    private Task<SessionRecord> StartCustomTerminalAsync(string provider, string folder, string? title) => throw new InvalidOperationException("Not a custom terminal fixture.");
  }
  public sealed class RecordingKeeper
  {
    public List<SessionDefinition> Created { get; } = [];
    public ValueTask<KeeperResponse> CreateAsync(SessionDefinition definition)
    {
      Created.Add(definition);
      return ValueTask.FromResult(new KeeperResponse { Session = new(definition, "test-only", SessionState.Running) });
    }
  }
}
