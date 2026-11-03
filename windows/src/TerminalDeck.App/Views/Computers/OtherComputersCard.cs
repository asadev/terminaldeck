using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Integration;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.App.Views.Computers;

public sealed class OtherComputersCard : StackPanel
{
  private readonly OtherComputersService service;
  private readonly TextBlock notice = new() { TextWrapping = TextWrapping.Wrap };
  private readonly StackPanel rows = new() { Spacing = 12 };
  private bool busy;
  public OtherComputersCard(OtherComputersService service)
  {
    this.service = service; Spacing = 12;
    // Same frame as the Devices rows above it: section heading, then a setting row with the code and Pair on the right.
    Margin = new Thickness(0, 12, 0, 0);
    Children.Add(new TextBlock { Text = "Other computers", FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
    var code = new TextBox { PlaceholderText = "Six digits", MaxLength = 16, Width = 140, VerticalAlignment = VerticalAlignment.Center, InputScope = new() { Names = { new(Microsoft.UI.Xaml.Input.InputScopeNameValue.Number) } } };
    Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(code, "Code from the other computer");
    var pair = new Button { Content = "Pair", IsEnabled = false, VerticalAlignment = VerticalAlignment.Center };
    code.TextChanged += (_, _) => pair.IsEnabled = !busy && PairingCode.Normalize(code.Text) is not null;
    pair.Click += async (_, _) =>
    {
      busy = true; pair.IsEnabled = false; pair.Content = "Pairing…"; notice.Text = "";
      try { await service.PairAsync(code.Text, CancellationToken.None); code.Text = ""; notice.Text = "Choose Let it in on the other computer, then Connect below."; }
      catch (Exception ex) when (ex is not OutOfMemoryException) { notice.Text = ex is ArgumentException or InvalidOperationException or ProtocolException ? ex.Message : "Couldn’t pair. Make a new code on the other computer and try again."; }
      finally { busy = false; pair.Content = "Pair"; pair.IsEnabled = PairingCode.Normalize(code.Text) is not null; }
    };
    var entry = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center }; entry.Children.Add(code); entry.Children.Add(pair);
    Children.Add(Settings.SettingsPanel.SettingRow("Pair another computer", "Enter the code shown on the other computer to use its sessions, Hoot, services and screens. That computer chooses your access.", entry));
    notice.Margin = new Thickness(12, 0, 12, 0); rows.Margin = new Thickness(12, 0, 12, 0);
    Children.Add(notice); Children.Add(rows);
    Loaded += (_, _) => { service.Changed += Changed; Render(); };
    Unloaded += (_, _) => service.Changed -= Changed;
    Render();
  }
  private void Changed() => DispatcherQueue.TryEnqueue(Render);
  private void Render()
  {
    rows.Children.Clear();
    foreach (var computer in service.List())
    {
      var row = new StackPanel { Spacing = 6 };
      row.Children.Add(new TextBlock { Text = computer.Name, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
      row.Children.Add(new TextBlock { Text = (computer.Platform switch { "darwin" or "mac" => "Mac", "win32" or "windows" => "Windows PC", "linux" => "Linux computer", _ => "Computer" }) + " · " + computer.State + (computer.State == "Online" && !string.IsNullOrWhiteSpace(computer.AppVersion) ? " · " + computer.AppVersion : ""), TextWrapping = TextWrapping.Wrap });
      if (computer.Fingerprint.Length > 0)
      {
        var fingerprint = new TextBlock { Text = computer.Fingerprint, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap, FontFamily = DeckFonts.Mono };
        ToolTipService.SetToolTip(fingerprint, "Compare this fingerprint with the one on that computer."); row.Children.Add(fingerprint);
      }
      if (computer.Note is not null) row.Children.Add(new TextBlock { Text = computer.Note, TextWrapping = TextWrapping.Wrap });
      var browserConsent = new CheckBox { Content = "Let its sessions use browser windows here", IsChecked = service.DrivesBrowser(computer.Id) };
      browserConsent.Click += async (_, _) =>
      {
        try { await service.SetBrowserConsentAsync(computer.Id, browserConsent.IsChecked == true); }
        catch (Exception ex) when (ex is not OutOfMemoryException) { notice.Text = ex.Message; browserConsent.IsChecked = service.DrivesBrowser(computer.Id); }
      };
      row.Children.Add(browserConsent);
      var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
      var connection = new Button { Content = computer.State == "Online" ? "Disconnect" : "Connect", IsEnabled = computer.State != "Connecting" };
      connection.Click += async (_, _) => await ActAsync(connection, async () => { if (computer.State == "Online") await service.DisconnectAsync(computer.Id); else await service.ConnectAsync(computer.Id); });
      var forget = new Button { Content = "Forget…" };
      forget.Click += async (_, _) =>
      {
        var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Forget " + computer.Name + "?", Content = "This removes this computer’s saved connection here. Pair it again to reconnect.", PrimaryButtonText = "Forget", CloseButtonText = "Keep", DefaultButton = ContentDialogButton.Close };
        if (await dialog.ShowAsync() == ContentDialogResult.Primary) await ActAsync(forget, () => service.ForgetAsync(computer.Id));
      };
      actions.Children.Add(connection); actions.Children.Add(forget); row.Children.Add(actions);
      if (computer.State == "Online" && !computer.Capabilities.Contains("sims")) row.Children.Add(new TextBlock { Text = "Screen sharing is not available with this computer’s current version or access level.", TextWrapping = TextWrapping.Wrap });
      if (computer.State == "Online")
      {
        var services = new Button { Content = "Sessions and services" };
        services.Click += (_, _) => ComputerServicesWindow.Open(service, computer, ActualTheme);
        row.Children.Add(services);
      }
      foreach (var display in computer.Displays)
      {
        var id = OtherComputersService.Text(display, "id", "");
        if (id.Length == 0) continue;
        var name = OtherComputersService.Text(display, "name", id);
        var canWatch = !display.TryGetProperty("canWatch", out var allowed) || allowed.ValueKind == System.Text.Json.JsonValueKind.True;
        var open = new Button { Content = "Open " + name, IsEnabled = canWatch };
        ToolTipService.SetToolTip(open, OtherComputersService.Text(display, "note", "Show this display in its own window"));
        open.Click += (_, _) => ComputerScreenWindow.Open(service, computer, display, ActualTheme);
        row.Children.Add(open);
        var displayDetail = OtherComputersService.Text(display, "runtime", "");
        if (displayDetail.Length > 0) row.Children.Add(new TextBlock { Text = displayDetail, FontSize = 12, Opacity = .7, TextWrapping = TextWrapping.Wrap });
      }
      rows.Children.Add(row);
    }
  }
  private async Task ActAsync(Button button, Func<Task> action)
  {
    button.IsEnabled = false; notice.Text = "";
    try { await action(); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { notice.Text = ex is ArgumentException or InvalidOperationException or ProtocolException ? ex.Message : "The connection action could not finish. Try again."; }
    finally { button.IsEnabled = true; }
  }
}
