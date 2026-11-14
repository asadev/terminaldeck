using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TerminalDeck.App.Views.Chat;

// The bar over a chat: the title on the first line; the project and the account chip on the second
// line, joined by a dot; the session's own controls at the trailing end. The open chat's pane bar
// (WorkspaceSurface) and the New session page both build it from these parts.
internal static class ChatBar
{
  public static Grid Frame(bool splitPane)
  {
    var bar = new Grid { MinHeight = splitPane ? 34 : 48, Padding = splitPane ? new(10, 0, 10, 0) : new(16, 6, 16, 6), ColumnSpacing = 8 };
    bar.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); bar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    return bar;
  }
  public static StackPanel Identity() => new() { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
  public static TextBlock Title(string text, bool splitPane = false) => new() { Text = text, FontSize = splitPane ? 13 : 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, MaxLines = 1, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
  // The second line.
  public static StackPanel Line() => new() { Orientation = Orientation.Horizontal, Spacing = 5, VerticalAlignment = VerticalAlignment.Center };
  // The project (folder) chip on the second line.
  public static Button ProjectChip(string text)
  {
    var chip = new Button { Content = new TextBlock { Text = text, TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 180 }, Style = (Style)Application.Current.Resources["DeckToolbarButtonStyle"], FontSize = 11, MinHeight = 20, Height = 20, Width = double.NaN, MinWidth = 0, HorizontalAlignment = HorizontalAlignment.Left, HorizontalContentAlignment = HorizontalAlignment.Stretch, Padding = new(0) };
    chip.SetResourceReference(Control.ForegroundProperty, "DeckSecondaryInkBrush");
    return chip;
  }
  // The account chip after the dot.
  public static Button AccountChip(string label)
  {
    var chip = new Button { Content = label, FontSize = 11, MaxWidth = 150, MinWidth = 0, Height = 24, MinHeight = 24, Padding = new(6, 0, 6, 0) };
    // Mac uses no account chip when no AI/default run command is available.
    chip.Style = (Style)Application.Current.Resources["DeckToolbarButtonStyle"];
    chip.Width = double.NaN; chip.HorizontalAlignment = HorizontalAlignment.Left;
    chip.SetResourceReference(Control.ForegroundProperty, "DeckSecondaryInkBrush");
    return chip;
  }
  public static TextBlock Dot() => new() { Text = "·", VerticalAlignment = VerticalAlignment.Center };
}
