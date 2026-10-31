using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using static TerminalDeck.App.Views.Projects.ProjectAgentUi;

namespace TerminalDeck.App.Views.Tasks;

// The same column measurements are used by headings and rows. Secondary columns
// give way first so the task name stays readable in a narrow window.
internal static class TaskLayout
{
  private static readonly string[] Keys = ["name", "assignee", "due", "priority", "status", "project", "created", "goal"];
  private static readonly double[] Widths = [240, 150, 104, 100, 128, 120, 92, 132];
  public static double RequiredWidth(IReadOnlySet<string> shown, bool statusGroups, bool projectSections) => Widths[0] + Keys.Select((key, i) =>
    shown.Contains(key) && !(key == "status" && statusGroups) && !(key == "project" && projectSections) ? Widths[i] : 0).Sum() + 16;
  public static Grid Columns(IReadOnlySet<string> shown, IReadOnlyList<string> order, bool statusGroups, bool projectSections, params FrameworkElement[] cells)
  {
    var grid = new Grid { ColumnSpacing = 0, MinHeight = 48, Padding = new Thickness(8, 0, 8, 0) };
    var ordered = new[] { "name" }.Concat(order).ToArray();
    foreach (var key in ordered)
    {
      var at = Array.IndexOf(Keys, key); if (at < 0 || at >= cells.Length) continue;
      var visible = at == 0 || shown.Contains(key) && !(key == "status" && statusGroups) && !(key == "project" && projectSections);
      var column = grid.ColumnDefinitions.Count;
      grid.ColumnDefinitions.Add(new() { Width = at == 0 ? new GridLength(1, GridUnitType.Star) : new GridLength(visible ? Widths[at] : 0) });
      cells[at].Visibility = visible ? Visibility.Visible : Visibility.Collapsed; cells[at].VerticalAlignment = VerticalAlignment.Center;
      Grid.SetColumn(cells[at], column); grid.Children.Add(cells[at]);
    }
    return grid;
  }
  public static TextBlock Cell(string text, bool muted = false) => new()
  {
    Text = text, FontSize = 13, Opacity = muted ? 0.68 : 1,
    TextTrimming = TextTrimming.CharacterEllipsis, MaxLines = 1
  };
  public static Button Quiet(string title, Action action)
  {
    var button = Button(title, action); button.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent);
    button.Padding = new Thickness(8, 4, 8, 4); button.MinHeight = 28; button.CornerRadius = new CornerRadius(8); button.Style = (Style)Application.Current.Resources["DeckNavigationButtonStyle"]; button.BorderThickness = new Thickness(0); return button;
  }
  public static FrameworkElement Glyph(string glyph)
  {
    return new DeckIcon { Glyph = glyph, FontSize = 13, Opacity = 0.5 };
  }
  public static Button Icon(string glyph, string label, Action action)
  {
    var button = Quiet("", action); button.Content = new DeckIcon { Glyph = glyph, FontSize = 13 };
    button.Width = 28; AutomationProperties.SetName(button, label); ToolTipService.SetToolTip(button, label); return button;
  }
  public static Border Status(string status, bool prominent = false)
  {
    var brush = status switch
    {
      "Done" => "SystemFillColorSuccessBrush", "Stuck" => "SystemFillColorCriticalBrush",
      "Working on it" => "SystemFillColorCautionBrush", "In Progress" => "AccentFillColorDefaultBrush",
      _ => "TextFillColorSecondaryBrush"
    };
    var text = Cell(prominent ? status.ToUpperInvariant() : status);
    text.FontSize = 12; text.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
    text.Style = (Style)XamlReader.Load($$"""
      <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="TextBlock">
        <Setter Property="FontFamily" Value="{ThemeResource DeckTextFontFamily}" />
        <Setter Property="Foreground" Value="{ThemeResource {{brush}}}" />
      </Style>
      """);
    return new Border { Style = (Style)XamlReader.Load($$"""
      <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Border">
        <Setter Property="Background" Value="{ThemeResource SubtleFillColorSecondaryBrush}" />
      </Style>
      """), Child = text, Padding = new Thickness(8, 3, 8, 3), CornerRadius = new CornerRadius(12), HorizontalAlignment = HorizontalAlignment.Left };
  }
  public static Border Surface(UIElement child) => new()
  {
    Child = child, Padding = new Thickness(16), CornerRadius = new CornerRadius(8),
    Style = (Style)XamlReader.Load("""
      <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Border">
        <Setter Property="Background" Value="{ThemeResource DeckCardBrush}" />
      </Style>
      """)
  };
}
