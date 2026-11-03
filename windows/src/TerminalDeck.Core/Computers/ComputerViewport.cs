namespace TerminalDeck.Core.Computers;

public static class ComputerViewport
{
  public static (double X, double Y) Follow(double pointerX, double pointerY, double width, double height, double viewWidth, double viewHeight, double offsetX, double offsetY, double margin = 64)
  {
    static double Axis(double point, double extent, double viewport, double offset, double edge)
    {
      if (!double.IsFinite(point) || !double.IsFinite(extent) || !double.IsFinite(viewport) || extent <= 0 || viewport <= 0) return 0;
      edge = Math.Min(Math.Max(0, edge), viewport / 3); var position = Math.Clamp(point, 0, 1) * extent;
      if (position < offset + edge) offset = position - edge;
      else if (position > offset + viewport - edge) offset = position - viewport + edge;
      return Math.Clamp(offset, 0, Math.Max(0, extent - viewport));
    }
    return (Axis(pointerX, width, viewWidth, offsetX, margin), Axis(pointerY, height, viewHeight, offsetY, margin));
  }
}
