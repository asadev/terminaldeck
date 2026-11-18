using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.Shell;

namespace TerminalDeck.App.Views;

public sealed record BrowserSessionChoice(string Id, string Title, string Machine = "This computer");

public sealed partial class BrowserPane
{
  public Func<IReadOnlyList<BrowserSessionChoice>> SessionChoices { get; set; } = () => [];
  public Action<string>? OpenBrowserSettings { get; set; }
  private object ConnectLabel(BrowserTab tab, bool full)
  {
    var binding = Core.Get(tab.Id); var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5 };
    if (binding.SessionId is null || full) label.Children.Add(new DeckIcon { Glyph = "\uE71B", FontSize = 12 });
    if (binding.SessionId is { } linked)
    {
      label.Children.Add(new TextBlock { Text = binding.SessionSlot, FontSize = 11, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
      if (full) label.Children.Add(new TextBlock { Text = SessionChoices().FirstOrDefault(s => s.Id == linked)?.Title ?? "Session", MaxWidth = 150, TextTrimming = TextTrimming.CharacterEllipsis, FontSize = 12 });
    }
    else if (full) label.Children.Add(new TextBlock { Text = "Connect", FontSize = 12 });
    return label;
  }
  private FrameworkElement SessionButton(BrowserTab tab, out Action<bool> refresh)
  {
    var button = TextAction("Connect", () => { }); button.CornerRadius = new(13); button.Padding = new(7, 0, 7, 0); button.MinHeight = button.Height = 26;
    var menu = DeckMenu.CreateFor(tab.View); button.Flyout = menu;
    var disconnect = WorkspaceSurface.IconButton("Disconnect this page", "\uE711", async () => await GuardAsync(async () => { await Core.AttachAsync(tab.Id, null); RefreshShellViews(); ShellChanged?.Invoke(); }, tab));
    disconnect.Width = disconnect.Height = disconnect.MinWidth = disconnect.MinHeight = 22; disconnect.Padding = new(0); disconnect.CornerRadius = new(11);
    var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 0, VerticalAlignment = VerticalAlignment.Center }; row.Children.Add(button); row.Children.Add(disconnect);
    var capsule = new Border { CornerRadius = new(13), Height = 26, Child = row, VerticalAlignment = VerticalAlignment.Center };
    refresh = full =>
    {
      var connected = Core.Get(tab.Id).SessionId is not null; button.Content = ConnectLabel(tab, full); disconnect.Visibility = connected ? Visibility.Visible : Visibility.Collapsed;
      var ink = (SolidColorBrush)ShellTheme.Resource(button, connected ? "DeckProjectBlueBrush" : "DeckSecondaryInkBrush");
      button.Foreground = disconnect.Foreground = ink;
      capsule.Background = connected ? new SolidColorBrush(ink.Color) { Opacity = .16 } : (Brush)ShellTheme.Resource(button, "DeckTransparentBrush");
      capsule.BorderThickness = connected ? new(0) : new(1); capsule.BorderBrush = (Brush)ShellTheme.Resource(button, "DeckDividerBrush");
      ToolTipService.SetToolTip(button, connected ? "Change connected session" : "Connect a session");
    };
    menu.Opening += (_, _) =>
    {
      menu.Items.Clear(); var linked = Core.Get(tab.Id);
      menu.Items.Add(new MenuFlyoutItem { Text = "Connect this page to", IsEnabled = false });
      if (linked.SessionId is not null) menu.Items.Add(MenuAction("Disconnect", tab, async () => { await Core.AttachAsync(tab.Id, null); RefreshShellViews(); ShellChanged?.Invoke(); }));
      foreach (var session in SessionChoices())
      {
        var item = new ToggleMenuFlyoutItem { Text = session.Title + " · " + session.Machine, IsChecked = linked.SessionId == session.Id };
        item.Click += async (_, _) => await GuardAsync(async () => { await Core.AttachAsync(tab.Id, session.Id); RefreshShellViews(); ShellChanged?.Invoke(); }, tab); menu.Items.Add(item);
      }
      DeckMenu.CompactRows(menu.Items);
    };
    refresh(true); return capsule;
  }
}
