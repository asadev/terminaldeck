using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.Core.Chats;

namespace TerminalDeck.App.Views.Chat;

// Asad, 6 Nov: consecutive tool steps between two messages are ONE compact row ("Ran 12 commands",
// the running step's name while it works) with a chevron. Open, the steps are compact lines and each
// line still opens its own detail. A failed step marks the row. MCP Apps, pictures and drawings of
// the steps stay visible under the row. Shared by the chat page and Hoot's page.
internal sealed class ChatToolRunView : StackPanel
{
  private readonly TextBlock header = new() { FontSize = 12, TextTrimming = TextTrimming.CharacterEllipsis };
  private readonly StackPanel steps = new() { Spacing = 0, Margin = new Thickness(12, 0, 0, 0) };
  private readonly StackPanel rich = new() { Spacing = 0 };
  private readonly Dictionary<string, (ChatRow Row, UIElement Step, FrameworkElement? Rich)> parts = [];
  public Expander Fold { get; }
  public ChatToolRunView()
  {
    Spacing = 8;
    Fold = new Expander
    {
      Header = header, Content = steps, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
      Background = new SolidColorBrush(Microsoft.UI.Colors.Transparent), BorderThickness = new Thickness(0), MinHeight = 28
    };
    Children.Add(Fold); Children.Add(rich);
  }
  // `step` draws one compact line (a tool step, or reasoning between steps); `richContent` the step's
  // pictures, drawings and MCP App. Unchanged steps keep their elements, so a running MCP App survives
  // the next step arriving.
  private ChatRow[] shown = [];
  public void Update(IReadOnlyList<ChatRow> rows, Func<ChatRow, UIElement> step, Func<ChatRow, FrameworkElement?> richContent)
  {
    // Streaming redraws the page per word; an unchanged run is left as it is.
    if (shown.SequenceEqual(rows)) return;
    shown = rows.ToArray();
    var summary = ChatToolRuns.Summarize(rows);
    header.Inlines.Clear();
    header.Inlines.Add(new Run { Text = (summary.Running is not null ? "◌  " : summary.Failed > 0 ? "!  " : "✓  ") + ChatToolRuns.Line(summary) });
    if (summary.Plus > 0 || summary.Minus > 0) { Add("  +" + summary.Plus, "SystemFillColorSuccessBrush"); Add(" −" + summary.Minus, "SystemFillColorCriticalBrush"); }
    if (summary.Failed > 0) Add(" · " + summary.Failed + " failed", "SystemFillColorCautionBrush");
    AutomationProperties.SetName(Fold, ChatToolRuns.Header(summary) + (summary.Running is null ? "" : ", working"));
    var desiredSteps = new List<UIElement>(); var desiredRich = new List<UIElement>(); var seen = new HashSet<string>();
    foreach (var row in rows)
    {
      var key = row.Kind + ":" + row.Id; seen.Add(key);
      if (!parts.TryGetValue(key, out var part) || part.Row != row)
      {
        var content = row.Kind == "tool" ? richContent(row) : null;
        // Empty content (no picture, drawing or App yet) takes no room; it shows once it has some.
        if (content is not null) content.SizeChanged += (_, e) => content.Margin = e.NewSize.Height > 0 ? new Thickness(0, 0, 0, 8) : default;
        part = (row, step(row), content); parts[key] = part;
      }
      desiredSteps.Add(part.Step); if (part.Rich is { } drawn) desiredRich.Add(drawn);
    }
    foreach (var key in parts.Keys.Where(k => !seen.Contains(k)).ToArray()) parts.Remove(key);
    Sync(steps, desiredSteps); Sync(rich, desiredRich);
  }
  private void Add(string text, string brush)
  {
    var run = new Run { Text = text };
    try { if (Application.Current.Resources[brush] is Brush color) run.Foreground = color; }
    catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException or KeyNotFoundException) { }
    header.Inlines.Add(run);
  }
  private static void Sync(Panel panel, List<UIElement> desired)
  {
    var keep = new HashSet<UIElement>(desired);
    for (var i = panel.Children.Count - 1; i >= 0; i--) if (!keep.Contains(panel.Children[i])) panel.Children.RemoveAt(i);
    for (var i = 0; i < desired.Count; i++)
    {
      if (i < panel.Children.Count && ReferenceEquals(panel.Children[i], desired[i])) continue;
      var old = panel.Children.IndexOf(desired[i]); if (old >= 0) panel.Children.RemoveAt(old);
      panel.Children.Insert(i, desired[i]);
    }
  }
}
