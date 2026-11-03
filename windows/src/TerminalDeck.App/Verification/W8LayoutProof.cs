using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.Views;
using TerminalDeck.App.Views.Chat;

namespace TerminalDeck.App.Verification;

internal static class W8LayoutProof
{
  public static async Task CheckAsync(ShellWindow window, ChatPage page, string directory, Action<string, bool> check)
  {
    var original = window.AppWindow.Size;
    try
    {
      foreach (var width in new[] { 1280, 920 })
      foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        window.AppWindow.Resize(new Windows.Graphics.SizeInt32(width, 840));
        window.SetTheme(theme); await Task.Delay(350); page.UpdateLayout();
        var name = $"w8-chat-{width}-{theme}";
        var history = Tree(page).OfType<ScrollViewer>().Single(s => AutomationProperties.GetAutomationId(s) == "chat.history");
        var cards = Tree(page).OfType<Border>().Where(b => AutomationProperties.GetName(b).StartsWith("approval:", StringComparison.Ordinal) || AutomationProperties.GetName(b).StartsWith("assistant:", StringComparison.Ordinal) || AutomationProperties.GetName(b).StartsWith("user:", StringComparison.Ordinal)).ToArray();
        check(name + " bubbles and approval use their full measured content height", cards.Length >= 3 && cards.All(c => c.ActualHeight + 1 >= c.DesiredSize.Height && c.ActualHeight > 0));
        check(name + " cards fit the history width", cards.All(c => { var box = c.TransformToVisual(history).TransformBounds(new Windows.Foundation.Rect(0, 0, c.ActualWidth, c.ActualHeight)); return box.X >= -1 && box.Right <= history.ActualWidth + 1; }));
        var tool = Tree(page).OfType<Expander>().First(e => e.Header is TextBlock);
        var closed = tool.ActualHeight; tool.IsExpanded = true; await Task.Delay(150); page.UpdateLayout();
        check(name + " tool details expand to their measured content", tool.ActualHeight > closed && tool.ActualHeight + 1 >= tool.DesiredSize.Height);
        var composer = Tree(page).OfType<TextBox>().Single(t => AutomationProperties.GetAutomationId(t) == "chat.composer");
        var chips = Tree(page).OfType<Button>().Where(b => AutomationProperties.GetAutomationId(b) is "chat.model" or "chat.account" or "chat.send").ToArray();
        check(name + " composer chips and Send fit the pane", chips.Length == 3 && chips.All(b => { var box = b.TransformToVisual(page).TransformBounds(new Windows.Foundation.Rect(0, 0, b.ActualWidth, b.ActualHeight)); return box.X >= 0 && box.Right <= page.ActualWidth + 1 && box.Bottom <= page.ActualHeight + 1 && b.ActualWidth >= 40; }) && composer.ActualWidth <= page.ActualWidth);
        tool.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false, VerticalAlignmentRatio = 0 });
        await Snapshot(directory, name + "-tool");
        var details = Tree(page).OfType<Expander>().Single(e => e.Header as string == "Details");
        details.IsExpanded = true; await Task.Delay(150); page.UpdateLayout();
        var allow = Tree(page).OfType<Button>().Single(b => b.Content as string == "Allow once");
        allow.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false, VerticalAlignmentRatio = 1 });
        await Task.Delay(250); page.UpdateLayout();
        var action = allow.TransformToVisual(history).TransformBounds(new Windows.Foundation.Rect(0, 0, allow.ActualWidth, allow.ActualHeight));
        check(name + " expanded approval actions remain scrollable into view", action.Y >= -1 && action.Bottom <= history.ActualHeight + 1);
        await Snapshot(directory, name + "-approval");
        var queued = Tree(page).OfType<Button>().Single(b => b.Content as string == "Send now");
        queued.StartBringIntoView(new BringIntoViewOptions { AnimationDesired = false, VerticalAlignmentRatio = 1 });
        await Snapshot(directory, name + "-queue");
        tool.IsExpanded = false; details.IsExpanded = false;
      }
    }
    finally { window.AppWindow.Resize(original); }
  }
  private static IEnumerable<DependencyObject> Tree(DependencyObject node)
  {
    yield return node;
    for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++)
      foreach (var child in Tree(VisualTreeHelper.GetChild(node, i))) yield return child;
  }
  private static async Task Snapshot(string directory, string name)
  {
    await Task.Delay(300);
    await File.WriteAllTextAsync(Path.Combine(directory, "stage.json"), JsonSerializer.Serialize(new { name }));
    var until = DateTimeOffset.UtcNow.AddSeconds(30);
    while (!File.Exists(Path.Combine(directory, name + ".ack")))
    { if (DateTimeOffset.UtcNow > until) throw new TimeoutException("W8 screenshot was not captured."); await Task.Delay(100); }
  }
}
