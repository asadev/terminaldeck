namespace TerminalDeck.App.Shell;

// All tabs share the available width before the strip is allowed to scroll.
public sealed record WorkspaceTabSizing(bool Title, bool ProjectPicture, bool Close)
{
  public const double Minimum = 40;
  public const double Maximum = 220;
  public const double TitleMinimum = 72;
  public const double ArrowWidth = 28;
  public static double Width(int count, double available) => count <= 0 ? 0 : Math.Clamp(Math.Floor(Math.Max(0, available) / count), Minimum, Maximum);
  public static bool Overflows(int count, double available) => count > 0 && count * Minimum > Math.Max(0, available);
  public static double Viewport(int count, double available) => Math.Max(0, available - (Overflows(count, available) ? 2 * ArrowWidth : 0));
  public static WorkspaceTabSizing ForWidth(double width) => new(width >= TitleMinimum, width >= 112, width >= 156);
}
