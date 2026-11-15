using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Sessions;
using Windows.Storage.Pickers;

namespace TerminalDeck.App.Views.Agents;

internal static class CustomTerminalProviderWindow
{
  internal const string About = "Choose a Windows executable and literal arguments. Custom CLIs run in terminals; structured chat controls belong to the built-in AI adapters. Saving or removing a definition does not stop existing sessions.";

  internal static void Open(CustomTerminalProviders providers, ElementTheme theme)
  {
    var window = new Window { Title = "Custom terminal CLIs" };
    var body = Form(providers, () => WinRT.Interop.WindowNative.GetWindowHandle(window), true);
    body.RequestedTheme = theme; body.Padding = new(20); body.SetResourceReference(StackPanel.BackgroundProperty, "DeckCanvasBrush");
    window.Content = new ScrollViewer { Content = body, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled }; window.Activate();
  }

  // The form itself: its own window (above), or a second page of Settings > Coding AIs (15 Nov), which
  // gives no heading because its top bar names the page.
  internal static StackPanel Form(CustomTerminalProviders providers, Func<nint> windowHandle, bool heading)
  {
    var body = new StackPanel { Spacing = 12 };
    if (heading)
    {
      body.Children.Add(new TextBlock { Text = "Custom terminal CLIs", FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
      body.Children.Add(new TextBlock { Text = About, TextWrapping = TextWrapping.Wrap });
    }
    var choices = new ComboBox { Header = "Custom CLI", HorizontalAlignment = HorizontalAlignment.Stretch };
    var id = new TextBox { Header = "Key", PlaceholderText = "custom-my-ai", MaxLength = 39 }; var name = new TextBox { Header = "Name", MaxLength = 80 }; var executable = new TextBox { Header = "Executable (.exe)", PlaceholderText = "Full executable path" };
    var browse = new Button { Content = "Choose executable…" }; browse.Click += async (_, _) => { var handle = windowHandle(); if (handle == 0) return; var picker = new FileOpenPicker(); picker.FileTypeFilter.Add(".exe"); WinRT.Interop.InitializeWithWindow.Initialize(picker, handle); if (await picker.PickSingleFileAsync() is { } file) executable.Text = file.Path; };
    var arguments = new TextBox { Header = "Arguments · one literal argument per line", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 80, MaxHeight = 160 };
    var environment = new TextBox { Header = "Environment · NAME=value, one per line", AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, MinHeight = 80, MaxHeight = 160 };
    var inherited = new ToggleSwitch { Header = "Inherit this computer's environment", IsOn = true }; var enabled = new ToggleSwitch { Header = "Available in New session", IsOn = true }; var notice = new TextBlock { TextWrapping = TextWrapping.Wrap };
    void Refresh(string? selected = null)
    {
      choices.Items.Clear(); choices.Items.Add(new ComboBoxItem { Content = "New custom CLI", Tag = "" });
      foreach (var row in providers.List()) choices.Items.Add(new ComboBoxItem { Content = row.Name + (row.Enabled ? "" : " · Disabled"), Tag = row.Id });
      choices.SelectedItem = choices.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (string)i.Tag == selected) ?? choices.Items[0];
    }
    choices.SelectionChanged += (_, _) =>
    {
      var selected = choices.SelectedItem is ComboBoxItem { Tag: string key } ? providers.List().FirstOrDefault(p => p.Id == key) : null;
      id.IsEnabled = selected is null; id.Text = selected?.Id ?? "custom-"; name.Text = selected?.Name ?? ""; executable.Text = selected?.Executable ?? ""; arguments.Text = string.Join('\n', selected?.Arguments ?? []); environment.Text = string.Join('\n', selected?.Environment.Select(p => p.Key + "=" + p.Value) ?? []); inherited.IsOn = selected?.InheritEnvironment ?? true; enabled.IsOn = selected?.Enabled ?? true;
    };
    var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; var save = new Button { Content = "Save CLI" }; var remove = new Button { Content = "Remove definition" };
    save.Click += (_, _) =>
    {
      try
      {
        var variables = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in environment.Text.Split('\n', StringSplitOptions.RemoveEmptyEntries)) { var split = line.IndexOf('='); if (split <= 0) throw new ArgumentException("Use NAME=value for each environment line."); variables.Add(line[..split].Trim(), line[(split + 1)..].TrimEnd('\r')); }
        if (!File.Exists(executable.Text.Trim())) throw new ArgumentException("Choose an installed executable.");
        providers.Save(new(id.Text.Trim(), name.Text.Trim(), executable.Text.Trim(), arguments.Text.Length == 0 ? [] : arguments.Text.Replace("\r", "", StringComparison.Ordinal).Split('\n'), variables, enabled.IsOn, inherited.IsOn)); notice.Text = "Saved. The CLI is available in terminal session choices."; Refresh(id.Text.Trim());
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { notice.Text = ex.Message; }
    };
    remove.Click += (_, _) => { if (choices.SelectedItem is not ComboBoxItem { Tag: string key } || key.Length == 0) return; try { providers.Remove(key); Refresh(); notice.Text = "Definition removed. Existing terminal sessions keep running."; } catch (Exception ex) when (ex is not OutOfMemoryException) { notice.Text = ex.Message; } };
    actions.Children.Add(save); actions.Children.Add(remove);
    foreach (var element in new UIElement[] { choices, id, name, executable, browse, arguments, environment, inherited, enabled, actions, notice }) body.Children.Add(element);
    Refresh();
    return body;
  }
}
