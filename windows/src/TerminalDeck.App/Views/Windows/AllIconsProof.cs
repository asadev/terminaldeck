using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.Shell;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  // Called only inside the existing GUID/marker-guarded scratch proof runner.
  private async Task RunAllIconsProofAsync(string output)
  {
    double[] sizes = [9, 10, 11, 12, 13, 14, 16, 20, 24, 28, 30, 48];
    var frames = new List<object>();
    var original = Root.RequestedTheme;
    var sheet = new Grid { Padding = new(24), HorizontalAlignment = HorizontalAlignment.Stretch, VerticalAlignment = VerticalAlignment.Stretch };
    Grid.SetColumnSpan(sheet, Math.Max(1, Root.ColumnDefinitions.Count));
    Grid.SetRowSpan(sheet, Math.Max(1, Root.RowDefinitions.Count));
    Canvas.SetZIndex(sheet, 10000); Root.Children.Add(sheet);
    try
    {
      foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        SetTheme(theme);
        sheet.Background = (Brush)ShellTheme.Resource(sheet, "DeckCanvasBrush");
        foreach (var group in DeckIconCatalog.All.Chunk(24).Select((icons, index) => (icons, index)))
        {
          sheet.Children.Clear(); sheet.RowDefinitions.Clear(); sheet.ColumnDefinitions.Clear();
          for (var i = 0; i < 3; i++) sheet.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) });
          for (var i = 0; i < 8; i++) sheet.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
          for (var i = 0; i < group.icons.Length; i++)
          {
            var icon = group.icons[i];
            var cell = new StackPanel { Spacing = 4, Margin = new(4), VerticalAlignment = VerticalAlignment.Center };
            cell.Children.Add(new TextBlock { Text = icon.Name + " · " + icon.MacSymbol, FontSize = 11, Foreground = (Brush)ShellTheme.Resource(sheet, "DeckInkBrush") });
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
            foreach (var size in sizes) row.Children.Add(new DeckIcon { Glyph = icon.Name, FontSize = size, VerticalAlignment = VerticalAlignment.Center, Foreground = (Brush)ShellTheme.Resource(sheet, "DeckInkBrush") });
            cell.Children.Add(row); Grid.SetRow(cell, i / 3); Grid.SetColumn(cell, i % 3); sheet.Children.Add(cell);
          }
          Root.UpdateLayout(); await Task.Delay(80);
          frames.Add(await Verification.W10Proof.CaptureAsync(sheet, output, "icons-all-" + (int)Root.ActualWidth + "-" + (group.index + 1), theme.ToString().ToLowerInvariant(), "Original vectors at 9,10,11,12,13,14,16,20,24,28,30,48 logical pixels. Scratch proof only.", _ => { }));
        }
        sheet.Children.Clear();
        var brands = new StackPanel { Spacing = 24, Margin = new(16) };
        foreach (var provider in new[] { "hoot", "claude", "codex", "gemini", "shell" })
        {
          var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 16 };
          row.Children.Add(new TextBlock { Text = provider, Width = 100, Foreground = (Brush)ShellTheme.Resource(sheet, "DeckInkBrush") });
          foreach (var size in new double[] { 16, 20, 24, 28, 44, 48 }) row.Children.Add(new BrandIcon { Kind = provider, Width = size, Height = size });
          brands.Children.Add(row);
        }
        Grid.SetColumnSpan(brands, 3); Grid.SetRowSpan(brands, 8); sheet.Children.Add(brands);
        Root.UpdateLayout(); await Task.Delay(80);
        frames.Add(await Verification.W10Proof.CaptureAsync(sheet, output, "icons-identities-" + (int)Root.ActualWidth, theme.ToString().ToLowerInvariant(), "Existing attributed provider identities plus shared original shell vector. Scratch proof only.", _ => { }));
      }
      await File.WriteAllTextAsync(Path.Combine(output, "icons-manifest.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, count = DeckIconCatalog.All.Count, sizes, frames, icons = DeckIconCatalog.All.Select(i => new { i.Name, i.MacSymbol }) }, new JsonSerializerOptions { WriteIndented = true }));
    }
    finally { Root.Children.Remove(sheet); SetTheme(original); }
  }
}
