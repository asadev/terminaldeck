namespace TerminalDeck.Core.Browser;

public enum BrowserDrawTool { Draw, Box, Arrow, Text }
public sealed record BrowserDrawPoint(double X, double Y);
public sealed record BrowserDrawMark(BrowserDrawTool Tool, BrowserDrawPoint[] Points, string Text = "");
public sealed class BrowserDrawing
{
  private readonly List<BrowserDrawMark> marks = [];
  public IReadOnlyList<BrowserDrawMark> Marks => marks.Select(m => m with { Points = [.. m.Points] }).ToArray();
  public void Add(BrowserDrawMark mark)
  {
    if (!Enum.IsDefined(mark.Tool) || mark.Points.Length is 0 or > 20000 || mark.Text.Length > 1000 ||
      mark.Points.Any(p => !double.IsFinite(p.X) || !double.IsFinite(p.Y) || p.X is < 0 or > 1 || p.Y is < 0 or > 1)) throw new ArgumentException("Choose a mark inside the picture.");
    if (mark.Tool == BrowserDrawTool.Text && string.IsNullOrWhiteSpace(mark.Text)) throw new ArgumentException("Enter the text for this mark.");
    marks.Add(mark with { Points = [.. mark.Points] });
  }
  public void Undo() { if (marks.Count > 0) marks.RemoveAt(marks.Count - 1); }
  public void Clear() => marks.Clear();
}
