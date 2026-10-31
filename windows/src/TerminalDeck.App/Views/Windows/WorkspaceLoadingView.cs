using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
namespace TerminalDeck.App.Shell;

internal sealed class WorkspaceLoadingView : Grid
{
  internal WorkspaceLoadingView(bool browser = false)
  {
    this.SetResourceReference(BackgroundProperty, browser ? "DeckPaperBrush" : "DeckCanvasBrush");
    AutomationProperties.SetName(this, browser ? "Opening browser" : "Loading page");
    RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
    if (browser)
    {
      var bar = new Grid { Padding = new(12, 8, 12, 8), ColumnSpacing = 8 };
      bar.ColumnDefinitions.Add(new() { Width = GridLength.Auto }); bar.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); bar.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
      bar.Children.Add(Shape(28, 28)); var address = Shape(double.NaN, 32); SetColumn(address, 1); bar.Children.Add(address); var profile = Shape(28, 28); SetColumn(profile, 2); bar.Children.Add(profile); Children.Add(bar);
    }
    var body = new StackPanel { Spacing = 16, Margin = new(32), MaxWidth = 640, HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Top };
    body.Children.Add(new TextBlock { Text = browser ? "Opening browser…" : "Loading…", FontSize = 20, Margin = new(0, 8, 0, 8) });
    body.Children.Add(Shape(160, 20)); body.Children.Add(Shape(double.NaN, 88));
    body.Children.Add(Shape(double.NaN, 12)); body.Children.Add(Shape(240, 12));
    SetRow(body, 1); Children.Add(body);
  }
  private static Border Shape(double width, double height)
  {
    var shape = new Border { Width = width, Height = height, CornerRadius = new(8), Opacity = 0.45, HorizontalAlignment = double.IsNaN(width) ? HorizontalAlignment.Stretch : HorizontalAlignment.Left };
    shape.SetResourceReference(Border.BackgroundProperty, "DeckTileBrush"); AutomationProperties.SetAccessibilityView(shape, Microsoft.UI.Xaml.Automation.Peers.AccessibilityView.Raw); return shape;
  }
}
