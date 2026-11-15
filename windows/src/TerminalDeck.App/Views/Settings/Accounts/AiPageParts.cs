using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;

namespace TerminalDeck.App.Views;

// The rows Coding AIs and AI apps are made of (Mac, 15 Nov): a name, at most one short second line,
// one control at the right. Anything longer sits behind an info button. No ids, paths or addresses.
public sealed partial class SettingsPane
{
  private static Style AiPagePlainButton => (Style)Application.Current.Resources["DeckNavigationButtonStyle"];

  // A titled block: the group's title (optionally the AI's mark and an info button), then its groups.
  private static StackPanel AiPageSection(string title, string? provider, string? info, params FrameworkElement[] groups)
  {
    var section = new StackPanel { Spacing = 8 };
    var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(8, 12, 0, 0) };
    if (provider is not null) line.Children.Add(new BrandIcon { Kind = provider, Width = 16, Height = 16, VerticalAlignment = VerticalAlignment.Center });
    line.Children.Add(new TextBlock { Text = title, FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
    if (!string.IsNullOrWhiteSpace(info)) line.Children.Add(AiPageInfo(title, info));
    section.Children.Add(line);
    foreach (var group in groups) section.Children.Add(group);
    return section;
  }

  private static Button AiPageInfo(string title, string text)
  {
    var info = new Button { Content = new DeckIcon { Glyph = "", FontSize = 12 }, Padding = new Thickness(2), MinWidth = 20, MinHeight = 20, VerticalAlignment = VerticalAlignment.Center };
    info.Style = AiPagePlainButton;
    ToolTipService.SetToolTip(info, "About " + title); AutomationProperties.SetName(info, "About " + title);
    info.Flyout = new Flyout { Content = new TextBlock { Text = text, MaxWidth = 300, TextWrapping = TextWrapping.Wrap } };
    return info;
  }

  // Green: ready. Orange: needs him (sign in, or a key). Said once, here, on the account's own row.
  private static Microsoft.UI.Xaml.Shapes.Ellipse AiPageDot(bool ready, string state)
  {
    var dot = new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 8, Height = 8, VerticalAlignment = VerticalAlignment.Center };
    dot.SetResourceReference(Microsoft.UI.Xaml.Shapes.Shape.FillProperty, ready ? "DeckProjectGreenBrush" : "DeckProjectOrangeBrush");
    ToolTipService.SetToolTip(dot, state); AutomationProperties.SetName(dot, state);
    return dot;
  }

  // One row: [dot] name / second line ........ [info] [control]
  private static Border AiPageRow(string title, string? detail, FrameworkElement? control, FrameworkElement? dot = null, string? info = null)
  {
    var row = new Grid { ColumnSpacing = 10 };
    row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    row.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    if (dot is not null) row.Children.Add(dot);
    var words = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
    words.Children.Add(new TextBlock { Text = title, FontSize = 13, TextTrimming = TextTrimming.CharacterEllipsis });
    if (!string.IsNullOrWhiteSpace(detail))
    {
      var second = new TextBlock { Text = detail, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis };
      second.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
      words.Children.Add(second);
    }
    Grid.SetColumn(words, 1); row.Children.Add(words);
    var end = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
    if (!string.IsNullOrWhiteSpace(info)) end.Children.Add(AiPageInfo(title, info));
    if (control is not null) { control.VerticalAlignment = VerticalAlignment.Center; end.Children.Add(control); }
    Grid.SetColumn(end, 2); row.Children.Add(end);
    var card = new Border { Padding = new Thickness(12, 10, 12, 10), Child = row };
    card.SetResourceReference(Border.BackgroundProperty, "DeckCardBrush");
    AutomationProperties.SetAutomationId(card, "settings.row");
    return card;
  }

  // The plain three dots (not a circled mark) that open a row's menu.
  private static Button AiPageMenu(MenuFlyout menu, string label)
  {
    var more = new Button { Content = new DeckIcon { Glyph = "", FontSize = 13 }, Flyout = menu, Padding = new Thickness(6), MinWidth = 28, MinHeight = 28 };
    more.Style = AiPagePlainButton;
    more.SetResourceReference(Control.ForegroundProperty, "DeckSecondaryInkBrush");
    AutomationProperties.SetName(more, label); ToolTipService.SetToolTip(more, label);
    return more;
  }

  // A row that opens another page: its name and a chevron.
  private FrameworkElement AiPageLinkRow(string title, Func<Task> open)
  {
    var go = new Button { Content = new DeckIcon { Glyph = "", FontSize = 12 }, Padding = new Thickness(6), MinWidth = 28, MinHeight = 28 };
    go.Style = AiPagePlainButton;
    AutomationProperties.SetName(go, title);
    go.Click += async (_, _) => await AiPageRunAsync(go, open);
    return AiPageRow(title, null, go);
  }

  // "+ Add account" / "+ New key": the last row of its group.
  private FrameworkElement AiPageAddRow(string text, string automationId, Func<Task> clicked)
  {
    var label = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    label.Children.Add(new DeckIcon { Glyph = "", FontSize = 12, VerticalAlignment = VerticalAlignment.Center });
    label.Children.Add(new TextBlock { Text = text, FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
    var add = new Button { Content = label, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new Thickness(12, 10, 12, 10) };
    add.Style = AiPagePlainButton;
    AutomationProperties.SetName(add, text); AutomationProperties.SetAutomationId(add, automationId);
    add.Click += async (_, _) => await AiPageRunAsync(add, clicked);
    return add;
  }

  private async Task AiPageRunAsync(Button button, Func<Task> action)
  {
    button.IsEnabled = false;
    try { await action(); }
    catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or IOException or TerminalDeck.Core.Platform.ProviderUnavailableException) { model.Notice = ex.Message; }
    finally { button.IsEnabled = true; }
  }
}
