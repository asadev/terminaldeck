namespace TerminalDeck.App.Shell;

public sealed record WorkspaceTabSizing(bool Title, bool ProjectPicture, bool Close)
{
  public const double Minimum = 36;
  public const double Maximum = 220;
  public const double TitleMinimum = 64;
  public const double ArrowWidth = 28;
  public const double Gap = 4;
  public const double SelectedMinimum = 120;
  public static double Width(int count, double available) => count <= 0 ? 0 : Math.Clamp(Math.Floor(Math.Max(0, available - (count - 1) * Gap) / count), Minimum, Maximum);
  public static bool Overflows(int count, double available) => count > 0 && (count - 1) * (Minimum + Gap) + SelectedMinimum > Math.Max(0, available);
  public static double Viewport(int count, double available) => Math.Max(0, available - (Overflows(count, available) ? 2 * ArrowWidth : 0));
  public static double[] Widths(int count, double available, int selected)
  {
    if (count <= 0) return [];
    var width = Width(count, available); var widths = Enumerable.Repeat(width, count).ToArray();
    if (selected >= 0 && selected < count && width < SelectedMinimum)
    {
      widths[selected] = SelectedMinimum;
      var other = count == 1 ? Minimum : Math.Clamp((available - SelectedMinimum - (count - 1) * Gap) / (count - 1), Minimum, Maximum);
      for (var i = 0; i < count; i++) if (i != selected) widths[i] = other;
    }
    return widths;
  }
  public static int Reorder(IReadOnlyList<double> widths, int from, double offset)
  {
    var left = widths.Take(from).Sum() + from * Gap + offset; var right = left + widths[from]; var at = 0d; var to = from;
    for (var i = 0; i < widths.Count; i++)
    {
      var middle = at + widths[i] / 2;
      if (i > from && right > middle) to = i;
      if (i < from && left < middle) { to = i; break; }
      at += widths[i] + Gap;
    }
    return to;
  }
  public static WorkspaceTabSizing ForWidth(double width) => new(width >= TitleMinimum, width >= 140, width >= 156);
}
