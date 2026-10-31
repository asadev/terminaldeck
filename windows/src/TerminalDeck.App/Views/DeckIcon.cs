using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Markup;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace TerminalDeck.App.Views;

// Accept existing glyph values at the boundary, but draw each meaning once.
// UserControl keeps inherited Foreground live in selected rows and both themes.
public sealed class DeckIcon : UserControl
{
  public static readonly DependencyProperty GlyphProperty = DependencyProperty.Register(nameof(Glyph), typeof(string), typeof(DeckIcon), new PropertyMetadata("terminal", (target, _) => ((DeckIcon)target).Refresh()));
  public string Glyph { get => (string)GetValue(GlyphProperty); set => SetValue(GlyphProperty, value); }
  public DeckIcon()
  {
    IsTabStop = false;
    HorizontalContentAlignment = HorizontalAlignment.Center;
    VerticalContentAlignment = VerticalAlignment.Center;
    AutomationProperties.SetAccessibilityView(this, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw);
    RegisterPropertyChangedCallback(FontSizeProperty, (_, _) => Refresh());
    RegisterPropertyChangedCallback(ForegroundProperty, (_, _) => Refresh());
    Loaded += (_, _) => { Refresh(); EnsureTooltip(); };
    ActualThemeChanged += (_, _) => Refresh();
    Refresh();
  }
  private void EnsureTooltip()
  {
    DependencyObject? ancestor = VisualTreeHelper.GetParent(this);
    while (ancestor is not null && ancestor is not ButtonBase) ancestor = VisualTreeHelper.GetParent(ancestor);
    if (ancestor is not ButtonBase button || ToolTipService.GetToolTip(button) is not null || HasText(button)) return;
    var name = AutomationProperties.GetName(button);
    if (string.IsNullOrWhiteSpace(name) && DeckIconCatalog.Find(Glyph) is { } definition)
    {
      name = definition.Name switch
      {
        "compose" => "New session", "new-window" => "Move to new window", "settings" => "Settings",
        "browser" => "Browser", "split" => "Split view", "sidebar" => "Toggle sidebar",
        _ => char.ToUpperInvariant(definition.Name[0]) + definition.Name[1..].Replace('-', ' ')
      };
      AutomationProperties.SetName(button, name);
    }
    if (!string.IsNullOrWhiteSpace(name)) ToolTipService.SetToolTip(button, name);
  }
  private static bool HasText(DependencyObject parent)
  {
    if (parent is TextBlock text && !string.IsNullOrWhiteSpace(text.Text)) return true;
    for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
      if (HasText(VisualTreeHelper.GetChild(parent, i))) return true;
    return false;
  }
  private void Refresh()
  {
    var ink = Foreground ?? (Brush)Application.Current.Resources["TextFillColorPrimaryBrush"];
    if (DeckIconCatalog.Find(Glyph) is not { } icon)
    {
      // Less common Windows-only actions retain Microsoft's licensed Fluent glyph.
      Content = new FontIcon { Glyph = Glyph, FontFamily = TerminalDeck.App.Views.DeckFonts.Icons, FontSize = FontSize, Foreground = ink };
      return;
    }
    var path = (Microsoft.UI.Xaml.Shapes.Path)XamlReader.Load($"<Path xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" Data=\"{icon.Path}\" StrokeThickness=\"1.5\" StrokeStartLineCap=\"Round\" StrokeEndLineCap=\"Round\" StrokeLineJoin=\"Round\" />");
    if (DeckIconCatalog.Solid(icon.Name)) path.Fill = ink;
    else path.Stroke = ink;
    var canvas = new Canvas { Width = 16, Height = 16 };
    if (DeckIconCatalog.FilledPart(icon.Name) is { } filledPath)
    {
      var fill = (Microsoft.UI.Xaml.Shapes.Path)XamlReader.Load($"<Path xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" Data=\"{filledPath}\" />");
      fill.Fill = ink; canvas.Children.Add(fill);
    }
    canvas.Children.Add(path);
    Content = new Viewbox { Width = FontSize, Height = FontSize, Child = canvas };
  }
}
