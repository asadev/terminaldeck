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
}
