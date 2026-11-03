using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Integration;

namespace TerminalDeck.App.Views.Computers;

public static class ComputerSessionPicker
{
  // False continues the existing local picker. Remote folders never pass into
  // the local launcher, filesystem checks or local session ledger.
  public static async Task<bool> ChooseAsync(XamlRoot root, OtherComputersService service, CancellationToken ct = default)
  {
    var computers = service.List().Where(c => c.State == "Online" && c.Capabilities.Contains("create")).ToArray();
    if (computers.Length == 0) return false;
    var location = new ComboBox { Header = "Run on", HorizontalAlignment = HorizontalAlignment.Stretch };
    location.Items.Add(new ComboBoxItem { Content = "This PC", Tag = "" });
    foreach (var computer in computers) location.Items.Add(new ComboBoxItem { Content = computer.Name, Tag = computer.Id });
    location.SelectedIndex = 0;
    var dialog = new ContentDialog { XamlRoot = root, Title = "New session", Content = location, PrimaryButtonText = "Continue", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
    if (await dialog.ShowAsync() != ContentDialogResult.Primary) return true;
    if (location.SelectedItem is not ComboBoxItem { Tag: string id } || id.Length == 0) return false;
    ct.ThrowIfCancellationRequested();
    var form = new StackPanel { Spacing = 12, MinWidth = 360 };
    var folder = new ComboBox { Header = "Folder on " + computers.Single(c => c.Id == id).Name, IsEditable = true, HorizontalAlignment = HorizontalAlignment.Stretch };
    foreach (var value in service.Services(id).Folders) folder.Items.Add(value);
    if (folder.Items.Count > 0) folder.SelectedIndex = 0;
    var provider = new ComboBox { Header = "AI", ItemsSource = new[] { "claude", "codex", "gemini", "shell" }, SelectedIndex = 0, HorizontalAlignment = HorizontalAlignment.Stretch };
    var note = new TextBlock { Text = "This computer chooses which folders and agent accounts it shares.", TextWrapping = TextWrapping.Wrap };
    form.Children.Add(folder); form.Children.Add(provider); form.Children.Add(note);
    var start = new ContentDialog { XamlRoot = root, Title = "Start on " + computers.Single(c => c.Id == id).Name, Content = form, PrimaryButtonText = "Start", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
    var starting = false;
    start.Closing += (_, e) => e.Cancel = starting;
    start.PrimaryButtonClick += async (_, e) =>
    {
      e.Cancel = true; if (starting) return; starting = true; var defer = e.GetDeferral(); start.IsPrimaryButtonEnabled = false; start.IsSecondaryButtonEnabled = false; note.Text = "Starting…";
      try
      {
        var fields = new System.Text.Json.Nodes.JsonObject { ["provider"] = provider.SelectedItem?.ToString() };
        if (!string.IsNullOrWhiteSpace(folder.Text)) fields["cwd"] = folder.Text;
        var session = await service.CreateSessionAsync(id, fields, ct);
        var pane = new RemoteSessionPane(service, id, session.GetProperty("id").GetString()!);
        var window = new Window { Title = OtherComputersService.Text(session, "title", "Remote session"), Content = pane };
        window.Closed += async (_, _) => await pane.DisposeAsync(); window.Activate(); starting = false; start.Hide();
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { note.Text = ex.Message; }
      finally { starting = false; start.IsPrimaryButtonEnabled = true; start.IsSecondaryButtonEnabled = true; defer.Complete(); }
    };
    await start.ShowAsync(); return true;
  }
}
