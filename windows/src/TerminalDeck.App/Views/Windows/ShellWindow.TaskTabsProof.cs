using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  // The caller's task-proof gate has already required a marked scratch root.
  private async Task RunTaskTabsProofAsync(string output)
  {
    var frames = new List<object>();
    var checks = new List<object>();
    var oldHeader = WorkspaceHeader.Content;
    var oldVisible = sidebarVisible;
    var oldTheme = Root.RequestedTheme;
    using var renderWindow = new W13RenderWindow(this);
    try
    {
      WorkspaceHeader.Visibility = Visibility.Visible;
      PageTitle.Visibility = Visibility.Collapsed;
      foreach (var count in new[] { 5, 15, 30 })
      {
        var fixture = new WorkspaceState();
        for (var index = 0; index < count; index++) fixture.Ensure("tabs-proof-" + index, "tabs-proof", "tabs-proof-" + index, index % 3 == 0 ? "browser" : "terminal", "Session " + (index + 1) + " — a long title that must truncate inside its tab");
        var surface = new WorkspaceSurface(fixture, "main", _ => new Grid(), (_, _) => { }, _ => Task.CompletedTask, _ => Task.CompletedTask,
          _ => { }, _ => { }, _ => { }, (_, _) => Task.CompletedTask, _ => "", _ => "", _ => null, (_, _) => Task.CompletedTask, _ => Task.CompletedTask, _ => { });
        WorkspaceHeader.Content = surface.Header;
        surface.RenderHeader("tabs-proof-0");
        foreach (var width in new[] { 1280, 1920 })
        foreach (var visible in new[] { true, false })
        foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
        {
          if (sidebarVisible != visible) SidebarToggle_Click(this, new());
          SetTheme(theme);
          renderWindow.Resize(width, width == 1920 ? 1080 : 840);
          await Task.Delay(180);
          Root.UpdateLayout();
          var snapshot = surface.TabProofSnapshot(Root);
          var data = JsonSerializer.SerializeToElement(snapshot);
          double Left(FrameworkElement element) => element.TransformToVisual(Root).TransformPoint(new(0, 0)).X;
          var headerLeft = data.GetProperty("HeaderLeft").GetDouble();
          var headerRight = data.GetProperty("HeaderRight").GetDouble();
          var ok = data.GetProperty("EqualWidths").GetBoolean() && data.GetProperty("MinimumRespected").GetBoolean() &&
            data.GetProperty("ArrowsOnlyAfterMinimum").GetBoolean() && data.GetProperty("TitlesMatchWidth").GetBoolean() &&
            data.GetProperty("NoOverflowWithoutArrows").GetBoolean() &&
            data.GetProperty("ViewportClearOfNewTabButtons").GetBoolean() && data.GetProperty("ViewportInsideHeader").GetBoolean() &&
            headerLeft >= Left(SidebarToggle) + SidebarToggle.ActualWidth && headerRight <= Left(CaptionSpace) &&
            Math.Abs(Root.ActualWidth - width) < 2;
          var name = $"tabs-{count}-{width}-{(visible ? "sidebar" : "hidden")}";
          checks.Add(new { Name = name, Theme = theme.ToString(), Passed = ok, Snapshot = snapshot });
          frames.Add(await Verification.W10Proof.CaptureAsync(Root, output, name, theme.ToString().ToLowerInvariant(),
            "Synthetic tabs only; no sessions or external services started", _ => { }));
        }
      }
      File.WriteAllText(Path.Combine(output, "tabs-proof.json"), JsonSerializer.Serialize(new { Checks = checks, Frames = frames }, new JsonSerializerOptions { WriteIndented = true }));
      if (checks.Any(check => !JsonSerializer.SerializeToElement(check).GetProperty("Passed").GetBoolean())) throw new InvalidOperationException("Native tab bounds proof failed; see tabs-proof.json.");
    }
    finally
    {
      WorkspaceHeader.Content = oldHeader;
      if (sidebarVisible != oldVisible) SidebarToggle_Click(this, new());
      SetTheme(oldTheme);
    }
  }
}
