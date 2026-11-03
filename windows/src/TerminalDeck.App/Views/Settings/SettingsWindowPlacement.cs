namespace TerminalDeck.App.Views.Settings;

// Desktop coordinates are physical pixels, including negative monitor origins.
public sealed record SettingsWindowPlacement(int X, int Y, int Width, int Height, double Scale = 1)
{
  public static SettingsWindowPlacement Initial(SettingsWindowPlacement main, double sidebar, double toolbar) =>
    new(main.X + (int)Math.Round((sidebar + 8) * main.Scale), main.Y + (int)Math.Round((toolbar + 8) * main.Scale),
      (int)Math.Round(760 * main.Scale),
      (int)Math.Round(560 * main.Scale), main.Scale);

  public SettingsWindowPlacement Fit(SettingsWindowPlacement area, double scale, double minimumWidth = 680, double minimumHeight = 440)
  {
    if (!double.IsFinite(Scale) || Scale <= 0 || !double.IsFinite(scale) || scale <= 0 || area.Width <= 0 || area.Height <= 0)
      throw new ArgumentException("Use a valid display and scale.");
    var width = (int)Math.Clamp(Math.Round(Width * scale / Scale), Math.Min(area.Width, minimumWidth * scale), area.Width);
    var height = (int)Math.Clamp(Math.Round(Height * scale / Scale), Math.Min(area.Height, minimumHeight * scale), area.Height);
    return new(Math.Clamp(X, area.X, area.X + area.Width - width), Math.Clamp(Y, area.Y, area.Y + area.Height - height), width, height, scale);
  }
}
