using Microsoft.UI.Xaml.Media;
namespace TerminalDeck.App.Shell;

internal static class WorkspaceTabShape
{
  internal static PathGeometry Outline(double width, double height, double corner, double flare)
  {
    var round = Math.Min(corner, Math.Max(0, width / 2)); var right = flare + width;
    var edge = new PathFigure { StartPoint = new(0, height), IsClosed = true, IsFilled = true };
    edge.Segments.Add(new QuadraticBezierSegment { Point1 = new(flare, height), Point2 = new(flare, height - flare) });
    edge.Segments.Add(new LineSegment { Point = new(flare, round) });
    edge.Segments.Add(new QuadraticBezierSegment { Point1 = new(flare, 0), Point2 = new(flare + round, 0) });
    edge.Segments.Add(new LineSegment { Point = new(right - round, 0) });
    edge.Segments.Add(new QuadraticBezierSegment { Point1 = new(right, 0), Point2 = new(right, round) });
    edge.Segments.Add(new LineSegment { Point = new(right, height - flare) });
    edge.Segments.Add(new QuadraticBezierSegment { Point1 = new(right, height), Point2 = new(right + flare, height) });
    var geometry = new PathGeometry(); geometry.Figures.Add(edge); return geometry;
  }
  // The selected tab's rim: the same top, sides and flared feet as Outline, half
  // a pixel inside so a 1 px stroke stays sharp, and open along the bottom where
  // the tab runs into its pane.
  internal static PathGeometry Edge(double width, double height, double corner, double flare)
  {
    const double half = 0.5;
    var round = Math.Min(corner, Math.Max(0, width / 2)); var left = flare + half; var right = flare + width - half;
    var rim = new PathFigure { StartPoint = new(0, height), IsClosed = false, IsFilled = false };
    rim.Segments.Add(new QuadraticBezierSegment { Point1 = new(left, height), Point2 = new(left, height - flare) });
    rim.Segments.Add(new LineSegment { Point = new(left, round) });
    rim.Segments.Add(new QuadraticBezierSegment { Point1 = new(left, half), Point2 = new(left + round, half) });
    rim.Segments.Add(new LineSegment { Point = new(right - round, half) });
    rim.Segments.Add(new QuadraticBezierSegment { Point1 = new(right, half), Point2 = new(right, round) });
    rim.Segments.Add(new LineSegment { Point = new(right, height - flare) });
    rim.Segments.Add(new QuadraticBezierSegment { Point1 = new(right, height), Point2 = new(width + 2 * flare, height) });
    var geometry = new PathGeometry(); geometry.Figures.Add(rim); return geometry;
  }
}
