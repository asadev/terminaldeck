namespace TerminalDeck.App.Shell;

public sealed record WorkspaceWindowBounds(int X, int Y, int Width, int Height, double Scale = 1)
{
  public WorkspaceWindowBounds AtScale(double scale)
  {
    if (!double.IsFinite(scale) || scale <= 0 || !double.IsFinite(Scale) || Scale <= 0) throw new ArgumentException("Use a valid display scale.");
    return this with { Width = (int)Math.Clamp(Math.Round(Width * scale / Scale), 1, int.MaxValue), Height = (int)Math.Clamp(Math.Round(Height * scale / Scale), 1, int.MaxValue), Scale = scale };
  }
  public WorkspaceWindowBounds Fit(WorkspaceWindowBounds area)
  {
    var width = Math.Clamp(Width, Math.Min(520, area.Width), area.Width);
    var height = Math.Clamp(Height, Math.Min(340, area.Height), area.Height);
    return new(Math.Clamp(X, area.X, area.X + area.Width - width), Math.Clamp(Y, area.Y, area.Y + area.Height - height), width, height, Scale);
  }
  public long Intersection(WorkspaceWindowBounds other) => (long)Math.Max(0, Math.Min(X + Width, other.X + other.Width) - Math.Max(X, other.X)) * Math.Max(0, Math.Min(Y + Height, other.Y + other.Height) - Math.Max(Y, other.Y));
}
public sealed record WorkspaceGeometry(Dictionary<string, WorkspaceWindowBounds> Windows);
