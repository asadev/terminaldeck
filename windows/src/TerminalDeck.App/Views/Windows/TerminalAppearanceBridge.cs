using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;

namespace TerminalDeck.App.Shell;

internal static class TerminalAppearanceBridge
{
  private static readonly object gate = new();
  private static JsonElement light, dark;
  internal static event Action? Changed;
  internal static JsonElement Read(bool isDark) { lock (gate) return isDark ? dark : light; }
  // Invoke on WinUI's thread. Existing brush identities stay live in selected
  // tabs/headers/content, so a preview never requires rebuilding those views.
  internal static void Update(JsonElement lightSnapshot, JsonElement darkSnapshot)
  {
    lock (gate) { light = lightSnapshot.Clone(); dark = darkSnapshot.Clone(); }
    foreach (var (theme, snapshot) in new[] { ("Light", lightSnapshot), ("Default", darkSnapshot) })
      if (snapshot.TryGetProperty("theme", out var palette) && palette.TryGetProperty("background", out var background) && background.GetString() is { } color) ApplyPaper(Application.Current.Resources, theme, color);
    Changed?.Invoke();
  }
  internal static void EnsureInkResources() => EnsureInk(Application.Current.Resources);
  private static void EnsureInk(ResourceDictionary resources)
  {
    foreach (var key in new[] { "Light", "Default", "HighContrast" })
      if (resources.ThemeDictionaries.TryGetValue(key, out var dictionary) && dictionary is ResourceDictionary theme && theme.ContainsKey("DeckPaperBrush") && !theme.ContainsKey("DeckTerminalInkBrush") && theme.TryGetValue("DeckInkBrush", out var ink) && ink is SolidColorBrush brush) theme["DeckTerminalInkBrush"] = new SolidColorBrush(brush.Color);
    foreach (var merged in resources.MergedDictionaries) EnsureInk(merged);
  }
  private static void ApplyPaper(ResourceDictionary resources, string theme, string color)
  {
    if (resources.ThemeDictionaries.TryGetValue(theme, out var dictionary) && dictionary is ResourceDictionary themed)
    {
      Set(themed, "DeckPaperBrush", color);
      var snapshot = theme == "Default" ? dark : light;
      if (snapshot.TryGetProperty("theme", out var palette) && palette.TryGetProperty("foreground", out var foreground) && foreground.GetString() is { } text) Set(themed, "DeckTerminalInkBrush", text);
    }
    foreach (var merged in resources.MergedDictionaries) ApplyPaper(merged, theme, color);
  }
  private static void Set(ResourceDictionary resources, string key, string css)
  {
    var hex = css.TrimStart('#');
    if (hex.Length is 3 or 4) hex = string.Concat(hex.Select(c => new string(c, 2)));
    if (hex.Length is not (6 or 8) || hex.Any(c => !char.IsAsciiHexDigit(c))) return;
    byte Part(int offset) => Convert.ToByte(hex.Substring(offset, 2), 16);
    var color = Microsoft.UI.ColorHelper.FromArgb(hex.Length == 8 ? Part(6) : (byte)255, Part(0), Part(2), Part(4));
    if (resources.TryGetValue(key, out var value) && value is SolidColorBrush brush) brush.Color = color;
    else resources[key] = new SolidColorBrush(color);
  }
}
