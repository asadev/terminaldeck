using TerminalDeck.App.Views.Settings;

namespace TerminalDeck.App.Views;

public interface ISettingsPageNavigation
{
  Task OpenSettingsAsync(string section);
}

public sealed partial class ShellWindow : ISettingsPageNavigation
{
  public async Task OpenSettingsAsync(string section)
  {
    ShowSettingsPanel();
    await settingsPanel!.SelectAsync(section);
  }
}

public sealed partial class BrowserPane
{
  public Func<Task>? OpenSettingsRequested { get; set; }
  private Task OpenProfileSettingsAsync() => OpenSettingsRequested?.Invoke() ?? Task.FromException(new InvalidOperationException("Open Browser settings from the main window."));
}
