using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;

namespace TerminalDeck.App.Views.Chat;

// Shared by the two conversation surfaces so their spacing and controls cannot drift.
internal static class ChatAppearance
{
  // One weight for conversation body text. Regular renders visibly thinner than
  // the Mac's body text; Medium matches its weight without reading as bold. The
  // bundled Inter has a true Medium on Windows 10 and 11 alike (DeckFonts).
  public static readonly Windows.UI.Text.FontWeight BodyWeight = Microsoft.UI.Text.FontWeights.Medium;
  public const double BodySize = 13.5;
  public static string ProviderName(string provider) => provider switch
  { "claude" => "Claude Code", "codex" => "Codex", "gemini" => "Gemini", _ => provider };
  public static string EffortName(string effort) => effort switch
  { "xhigh" => "Extra high", "auto" or "" => "Auto", _ => char.ToUpperInvariant(effort[0]) + effort[1..] };
  public static void IconButton(Button button, string glyph, string label, bool accent = false)
  {
    if (!accent) button.Style = (Style)Application.Current.Resources["DeckToolbarButtonStyle"];
    button.Width = button.Height = 32; button.MinWidth = button.MinHeight = 32;
    button.Padding = new Thickness(0); button.CornerRadius = new CornerRadius(16);
    button.Content = new DeckIcon { FontFamily = TerminalDeck.App.Views.DeckFonts.Icons, Glyph = glyph, FontSize = 14 };
    AutomationProperties.SetName(button, label); ToolTipService.SetToolTip(button, label);
  }
  public static Expander ToolStep(string text, string details, bool working, bool failed = false)
  {
    var row = new Expander
    {
      Header = new TextBlock { Text = (working ? "◌  " : failed ? "!  " : "✓  ") + text, FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis },
      Content = new TextBlock { Text = details, FontSize = 12, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true, FontFamily = TerminalDeck.App.Views.DeckFonts.Mono },
      HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
      Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), MinHeight = 28
    };
    AutomationProperties.SetName(row, text + (working ? ", Working…" : failed ? ", Failed" : ", Done"));
    return row;
  }
  public static Grid Reply(FrameworkElement content, string provider)
  {
    var row = new Grid { ColumnSpacing = 10, HorizontalAlignment = HorizontalAlignment.Stretch };
    row.ColumnDefinitions.Add(new() { Width = new GridLength(26) }); row.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) });
    var avatar = Avatar(provider, 26);
    AutomationProperties.SetName(avatar, ProviderName(provider)); row.Children.Add(avatar); Grid.SetColumn(content, 1); row.Children.Add(content); return row;
  }
  internal static FrameworkElement Avatar(string provider, double size)
  {
    if (string.Equals(provider, "hoot", StringComparison.OrdinalIgnoreCase))
    {
      var owl = new Grid { Width = size, Height = size, VerticalAlignment = VerticalAlignment.Top };
      owl.Children.Add(new Image { Source = new SvgImageSource(new Uri("ms-appx:///Assets/icons/hoot.svg")), Width = size, Height = size });
      AutomationProperties.SetAccessibilityView(owl, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
      AutomationProperties.SetName(owl, "Hoot"); return owl;
    }
    var avatar = new BrandIcon { Kind = provider, Width = size, Height = size, VerticalAlignment = VerticalAlignment.Top };
    AutomationProperties.SetName(avatar, ProviderName(provider)); return avatar;
  }
  public static StackPanel Empty(string text, string provider = "")
  {
    var panel = new StackPanel { Spacing = 16, Margin = new Thickness(0, 100, 0, 28), HorizontalAlignment = HorizontalAlignment.Center };
    panel.Children.Add(Avatar(provider, 48));
    panel.Children.Add(new TextBlock { Text = text, FontSize = 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center });
    return panel;
  }
}
