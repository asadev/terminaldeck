using TerminalDeck.App.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;

namespace TerminalDeck.App.Views.Usage;

// Every header meter (this PC's CPU and memory, a session's context window and
// plan limits) draws the same ring in the same capsule, so the row reads as one
// set; only the fill colour tells them apart.
internal static class MeterRing
{
  internal const double Size = 14, Line = 2;
  private const double CapsuleHeight = Size + 6;

  internal static Grid Create() => new() { Width = Size, Height = Size, VerticalAlignment = VerticalAlignment.Center };

  // A ring or a short text figure sits in the same capsule at the same height.
  internal static Border Capsule(UIElement? content = null)
  {
    var capsule = new Border { Height = CapsuleHeight, MinWidth = Size + 12, CornerRadius = new(CapsuleHeight / 2), Padding = new(6, 0, 6, 0), Child = content, VerticalAlignment = VerticalAlignment.Center };
    capsule.SetResourceReference(Border.BackgroundProperty, "DeckHoverBrush");
    return capsule;
  }

  // The meter's button is exactly its capsule, with the capsule's rounded hover.
  internal static void Host(Button button, UIElement content)
  {
    button.Style = (Style)Application.Current.Resources["DeckToolbarButtonStyle"];
    button.Content = content; button.Padding = new(0); button.MinWidth = 0; button.MinHeight = 0; button.BorderThickness = new(0);
    button.Width = double.NaN; button.Height = double.NaN; button.CornerRadius = new(CapsuleHeight / 2);
    button.Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent); button.VerticalAlignment = VerticalAlignment.Center;
  }

  internal static void Draw(Grid ring, double? percent, string fill) => Draw(ring, percent, (Brush)Application.Current.Resources[fill]);

  internal static void Draw(Grid ring, double? percent, Brush fill)
  {
    ring.Children.Clear();
    var track = new Ellipse { Width = Size, Height = Size, StrokeThickness = Line, Opacity = 0.3 };
    track.SetResourceReference(Shape.StrokeProperty, "DeckSecondaryInkBrush"); ring.Children.Add(track);
    var filled = Math.Clamp((percent ?? 0) / 100, 0, 1);
    if (filled <= 0) return;
    if (filled >= 0.999) { ring.Children.Add(new Ellipse { Width = Size, Height = Size, StrokeThickness = Line, Stroke = fill }); return; }
    // An Ellipse strokes inside its bounds, so the arc shares the track's centre line.
    const double centre = Size / 2, radius = (Size - Line) / 2;
    var angle = filled * 2 * Math.PI;
    var figure = new PathFigure { StartPoint = new(centre, centre - radius), IsClosed = false };
    figure.Segments.Add(new ArcSegment { Point = new(centre + radius * Math.Sin(angle), centre - radius * Math.Cos(angle)), Size = new(radius, radius), SweepDirection = SweepDirection.Clockwise, IsLargeArc = filled > 0.5 });
    var geometry = new PathGeometry(); geometry.Figures.Add(figure);
    ring.Children.Add(new Microsoft.UI.Xaml.Shapes.Path { Data = geometry, Stroke = fill, StrokeThickness = Line, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round });
  }
}
