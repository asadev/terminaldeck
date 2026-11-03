using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Integration;
using TerminalDeck.App.Shell;
using TerminalDeck.Platform.Windows.Accounts;

namespace TerminalDeck.App.Views;

internal static class CodingAiInstallSheet
{
  private sealed record OpenInstall(Window Window, Func<string> Read, Task Closed);
  private static readonly Dictionary<string, OpenInstall> active = [];
  private static readonly Dictionary<string, string> previous = [];
  internal static async Task<JsonElement> ControlAsync(string provider, string action)
  {
    if (action is not ("state" or "cancel")) throw new ArgumentException("Choose state or cancel.");
    if (active.TryGetValue(provider, out var open) && action == "cancel") { open.Window.Close(); await open.Closed; }
    return JsonSerializer.SerializeToElement(new { provider, state = active.TryGetValue(provider, out open) ? open.Read() : previous.GetValueOrDefault(provider, "idle"), isOpen = active.ContainsKey(provider), checkedAt = DateTimeOffset.UtcNow });
  }
  public static async Task ShowAsync(AppRuntime runtime, string provider, FrameworkElement owner, nint ownerHandle, bool alreadyApproved = false, FrameworkElement? themeOwner = null)
  {
    if (active.TryGetValue(provider, out var existing)) { existing.Window.Activate(); return; }
    var name = TerminalDeck.Core.Agents.AgentSeats.ProviderName(provider);
    if (!alreadyApproved)
    {
      var approval = new ContentDialog { XamlRoot = owner.XamlRoot, RequestedTheme = owner.ActualTheme, Title = "Install " + name + "?", Content = "Run this AI’s official installer for your Windows user?\n\n" + WindowsAiInstaller.Command(provider), PrimaryButtonText = "Install", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
      if (await approval.ShowAsync() != ContentDialogResult.Primary) return;
    }
    var state = "starting";
    var window = new Window { Title = "Install " + name }; AccountSignInSheet.SetOwner(window, ownerHandle);
    var themeSource = themeOwner ?? owner;
    var content = new Grid { Padding = new Thickness(24), RowSpacing = 16, RequestedTheme = themeSource.ActualTheme };
    content.SetResourceReference(Grid.BackgroundProperty, "DeckCanvasBrush");
    void ThemeChanged(FrameworkElement sender, object args) => content.RequestedTheme = sender.ActualTheme;
    themeSource.ActualThemeChanged += ThemeChanged;
    window.Closed += (_, _) => themeSource.ActualThemeChanged -= ThemeChanged;
    content.RowDefinitions.Add(new() { Height = GridLength.Auto }); content.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) }); content.RowDefinitions.Add(new() { Height = GridLength.Auto });
    var words = new TextBlock { Text = "Installing " + name + "…", TextWrapping = TextWrapping.Wrap };
    var progress = new ProgressBar { IsIndeterminate = true }; var heading = new StackPanel { Spacing = 12, Children = { words, progress } };
    content.Children.Clear(); content.Children.Add(heading);
    var host = new Grid(); Grid.SetRow(host, 1); content.Children.Add(host);
    var close = new Button { Content = "Cancel", HorizontalAlignment = HorizontalAlignment.Right }; Grid.SetRow(close, 2); content.Children.Add(close);
    window.Content = content; window.AppWindow.Resize(new(840, 620));
    var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously); CliTerminalView? terminal = null;
    active[provider] = new(window, () => state, done.Task);
    window.Closed += (_, _) => { if (state is "starting" or "installing") state = "cancelled"; previous[provider] = state; active.Remove(provider); done.TrySetResult(); }; close.Click += (_, _) => window.Close(); window.Activate();
    try
    {
      var selected = runtime.Accounts.Default(provider) ?? runtime.Accounts.List(provider).First();
      terminal = new(WindowsAiInstaller.Plan(provider, runtime.Root, selected.HomeId), runtime.Root); host.Children.Add(terminal); state = "installing";
      _ = CompleteAsync();
      async Task CompleteAsync()
      {
        try
        {
          var code = await terminal.Exited;
          if (done.Task.IsCompleted) return;
          var account = runtime.Accounts.List(provider).First();
          var status = await runtime.Accounts.InstallationAsync(account.Id);
          state = status.Installed == true && code == 0 ? "succeeded" : "failed";
          words.Text = status.Installed == true && code == 0 ? name + " installed" + (status.Version is null ? "." : " · " + status.Version) : "The installer did not finish. Close this sheet, then try Install again.";
        }
        catch (Exception ex) when (ex is not OutOfMemoryException) { if (!done.Task.IsCompleted) { state = "failed"; words.Text = "The installer could not finish. Close this sheet and try again."; } }
        if (!done.Task.IsCompleted) { progress.Visibility = Visibility.Collapsed; close.Content = "Done"; }
      }
    }
    catch (Exception ex) when (ex is IOException or InvalidOperationException or ArgumentException) { state = "failed"; words.Text = ex.Message; progress.Visibility = Visibility.Collapsed; close.Content = "Done"; }
    await done.Task; previous[provider] = state; active.Remove(provider);
    if (terminal is not null) await terminal.DisposeAsync();
  }
}
