using System.Text.Json;
using Microsoft.UI.Xaml;
using TerminalDeck.App.Shell;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Servers;
using static TerminalDeck.App.Views.Servers.ServerUi;

namespace TerminalDeck.App.Views.Servers;

public sealed partial class ServersPage
{
  private Grid? settingsFrame;
  private StackPanel? settingsFields;
  private StackPanel? settingsTabs;
  private TextBlock? settingsTitle;
  private Notices.CompactNotice? settingsNotice;
  private string? settingsSnapshot;
  private string renderedSettingsSection = "";
  public Task ShowServerSettingsAsync(string id, string section = "Access") => ServerSettingsWindow.ShowAsync(XamlRoot, Model, host, id, section);
  private void RenderServerSettings()
  {
    if (settingsFrame is null)
    {
      settingsFrame = new Grid(); settingsFrame.RowDefinitions.Add(new() { Height = GridLength.Auto }); settingsFrame.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) }); settingsFrame.RowDefinitions.Add(new() { Height = GridLength.Auto });
      var heading = Stack(8); heading.Margin = new Thickness(20, 16, 20, 10);
      settingsTitle = Words("", 13); settingsTitle.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; settingsTitle.HorizontalAlignment = HorizontalAlignment.Center; heading.Children.Add(settingsTitle);
      settingsTabs = Horizontal(); settingsTabs.Spacing = 4; settingsTabs.HorizontalAlignment = HorizontalAlignment.Center;
      var switches = new Border { Child = settingsTabs, Padding = new Thickness(4), CornerRadius = new CornerRadius(14), HorizontalAlignment = HorizontalAlignment.Center, MaxWidth = 450 };
      switches.SetResourceReference(Border.BackgroundProperty, "DeckGlassBrush"); heading.Children.Add(switches); settingsFrame.Children.Add(heading);
      settingsFields = Stack(16); settingsFields.Margin = new Thickness(20); var content = Scroll(settingsFields); Grid.SetRow(content, 1); settingsFrame.Children.Add(content);
      settingsNotice = new Notices.CompactNotice { IsClosable = false, Margin = new Thickness(20, 0, 20, 16) }; Grid.SetRow(settingsNotice, 2); settingsFrame.Children.Add(settingsNotice); Children.Add(settingsFrame);
    }
    settingsNotice!.Message = Model.Message; settingsNotice.Severity = Model.IsError ? InfoBarSeverity.Error : InfoBarSeverity.Informational; settingsNotice.IsOpen = Model.Message.Length > 0;
    settingsFields!.IsHitTestVisible = !Model.IsBusy; settingsFields.Opacity = Model.IsBusy ? 0.6 : 1; settingsTabs!.IsHitTestVisible = !Model.IsBusy; settingsTabs.Opacity = Model.IsBusy ? 0.6 : 1;
    if (Model.Selected is not { } server)
    {
      settingsTitle!.Text = "Server removed"; settingsTabs!.Children.Clear(); settingsFields!.Children.Clear(); settingsFields.Children.Add(Words("This server is no longer in the list. Close this window to continue.", muted: true)); return;
    }
    settingsTitle!.Text = server.Name;
    var section = Model.Section switch { "Access" or "Sign-in" or "Apps setup" or "Alerts" => Model.Section, _ => "Advanced" };
    var snapshot = JsonSerializer.Serialize(new { server, Model.Settings });
    if (Model.IsBusy || snapshot == settingsSnapshot && section == renderedSettingsSection) return;
    settingsSnapshot = snapshot; renderedSettingsSection = section; settingsTabs!.Children.Clear(); settingsFields!.Children.Clear();
    foreach (var (id, label, glyph) in new[] { ("Access", "Access", "shield"), ("Sign-in", "Sign-in", "key"), ("Apps setup", "Apps setup", "store"), ("Alerts", "Alerts", "bell"), ("Advanced", "Advanced", "settings") })
    {
      var face = Stack(6); face.HorizontalAlignment = HorizontalAlignment.Center; face.Children.Add(Icon(glyph, 15)); face.Children.Add(Words(label, 11));
      var tab = Button(label, () => { Model.Tab(id); return Task.CompletedTask; }); tab.Content = face; tab.MinHeight = 44; tab.Width = 84; tab.MinWidth = 84; tab.CornerRadius = new CornerRadius(10); tab.Padding = new Thickness(12, 6, 12, 6);
      tab.SetResourceReference(Control.BackgroundProperty, section == id ? "DeckCardBrush" : "DeckTransparentBrush");
      tab.SetResourceReference(Control.ForegroundProperty, section == id ? "AccentFillColorDefaultBrush" : "DeckSecondaryInkBrush"); settingsTabs.Children.Add(tab);
    }
    switch (section)
    {
      case "Access": Access(settingsFields, server); ShownAppsSettings(settingsFields, server); break;
      case "Sign-in": ServerSignInSettings(settingsFields, server); break;
      case "Apps setup": ServerHostingSettings(settingsFields, server); break;
      case "Alerts": ServerAlertsSettings(settingsFields, server); break;
      default: ServerAdvancedSettings(settingsFields, server); break;
    }
    // The object window's title and tabs already name this form.
    if (section == "Access" && settingsFields.Children.FirstOrDefault() is TextBlock) settingsFields.Children.RemoveAt(0);
  }
}
