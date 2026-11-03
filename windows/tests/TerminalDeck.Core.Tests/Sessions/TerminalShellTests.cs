using System.Text.Json;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Settings;

namespace TerminalDeck.Core.Tests.Sessions;

public sealed class TerminalShellTests
{
  [Theory]
  [InlineData(null, "PowerShell")]
  [InlineData("powershell", "PowerShell")]
  [InlineData("pwsh", "PowerShell 7")]
  [InlineData("cmd", "Command Prompt")]
  public void TerminalsAreNamedForTheirShell(string? shell, string label) => Assert.Equal(label, TerminalShells.Label(shell));

  [Fact]
  public void SettingsNameWindowsPowerShellInFull()
  {
    Assert.Equal("Windows PowerShell", TerminalShells.Name(null));
    Assert.Equal("Windows PowerShell", TerminalShells.Name(TerminalShells.WindowsPowerShell));
    Assert.Equal("PowerShell 7", TerminalShells.Name(TerminalShells.PowerShell7));
    Assert.Equal("Command Prompt", TerminalShells.Name(TerminalShells.CommandPrompt));
  }

  [Theory]
  [InlineData(null)]
  [InlineData("powershell")]
  [InlineData("pwsh")]
  [InlineData("cmd")]
  public void ATerminalAcceptsAKnownShell(string? shell) => Terminal(shell).Validate();

  [Fact]
  public void OnlyLocalTerminalsCarryAShellAndOnlyKnownOnes()
  {
    Assert.Throws<ArgumentException>(() => (Terminal("cmd") with { Provider = "claude" }).Validate());
    Assert.Throws<ArgumentException>(() => Terminal("bash").Validate());
    Assert.Throws<ArgumentException>(() => (Terminal("cmd") with { ServerId = Guid.NewGuid().ToString("N") }).Validate());
  }

  [Fact]
  public void SessionsAndSettingsSavedBeforeTheChoiceReadAsWindowsPowerShell()
  {
    var saved = JsonSerializer.Serialize(Terminal(null) with { Shell = null }).Replace(",\"Shell\":null", "");
    Assert.DoesNotContain("\"Shell\"", saved);
    Assert.Null(JsonSerializer.Deserialize<SessionDefinition>(saved)!.Shell);
    Assert.Null(JsonSerializer.Deserialize<GeneralPreferences>("""{"CopyOnSelect":true}""")!.TerminalShell);
  }

  [Fact]
  public void TheShellSurvivesARoundTrip()
  {
    var definition = Terminal(TerminalShells.CommandPrompt);
    Assert.Equal(TerminalShells.CommandPrompt, JsonSerializer.Deserialize<SessionDefinition>(JsonSerializer.Serialize(definition))!.Shell);
    var preferences = new GeneralPreferences(TerminalShell: TerminalShells.PowerShell7);
    Assert.Equal(TerminalShells.PowerShell7, JsonSerializer.Deserialize<GeneralPreferences>(JsonSerializer.Serialize(preferences))!.TerminalShell);
  }

  private static SessionDefinition Terminal(string? shell) => new(Guid.NewGuid().ToString(), "shell", @"C:\work", TerminalShells.Label(shell), Shell: shell);
}
