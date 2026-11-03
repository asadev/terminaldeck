using TerminalDeck.App.Shell;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Quality;

namespace TerminalDeck.App.Views.Quality;

// Compact, unbordered single line. Every visible step opens the real reported
// details; +N opens the remainder, never a second row of pills.
public sealed class DeploymentStrip : StackPanel
{
  private readonly Deployments ledger;
  private readonly string? project, session;
  public DeploymentStrip(Deployments ledger, string? project = null, string? session = null)
  {
    this.ledger = ledger; this.project = project; this.session = session;
    Orientation = Orientation.Horizontal; Spacing = 6; Margin = new(12, 3, 12, 3);
    Loaded += (_, _) => { ledger.Changed += Changed; Render(); }; Unloaded += (_, _) => ledger.Changed -= Changed;
    SizeChanged += (_, _) => Render();
    Render();
  }
  private void Changed() => DispatcherQueue.TryEnqueue(Render);
  private void Render()
  {
    Children.Clear();
    var run = ledger.Read(project, session).FirstOrDefault(); Visibility = run is null ? Visibility.Collapsed : Visibility.Visible;
    if (run is null) return;
    var active = Array.FindIndex(run.Steps, s => s.State == "running");
    var limit = Math.Clamp((int)(ActualWidth / 150), 1, 3);
    var selected = run.Steps.Select((step, index) => (step, index)).OrderBy(x => x.index == active ? -1 : x.index).Take(limit).OrderBy(x => x.index).ToArray();
    foreach (var (step, _) in selected)
    {
      var glyph = step.State switch { "done" => "✓", "failed" => "!", "running" => "●", "skipped" => "–", _ => "○" };
      var button = new Button { Content = glyph + " " + step.Name, FontSize = 11, MaxWidth = 160, MinWidth = 0, MinHeight = 24, Padding = new(4, 0, 4, 0), Style = (Style)Application.Current.Resources["DeckToolbarButtonStyle"] };
      if (step.State == "running") button.SetResourceReference(Control.ForegroundProperty, "AccentFillColorDefaultBrush");
      button.Flyout = Details(run, [step]); Children.Add(button);
    }
    var more = run.Steps.Length - selected.Length;
    if (more > 0) Children.Add(new Button { Content = "+" + more, FontSize = 11, MinHeight = 24, Padding = new(4, 0, 4, 0), Flyout = Details(run, run.Steps), Style = (Style)Application.Current.Resources["DeckToolbarButtonStyle"] });
    ToolTipService.SetToolTip(this, run.Title + " · reported by " + run.Actor + " · " + run.UpdatedAt.ToLocalTime().ToString("g"));
  }
  private static Flyout Details(DeploymentRun run, IEnumerable<DeploymentStep> steps)
  {
    var body = new StackPanel { Spacing = 8, MaxWidth = 360 };
    body.Children.Add(new TextBlock { Text = run.Title, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap });
    foreach (var step in steps) body.Children.Add(new TextBlock { Text = step.Name + " · " + step.State + "\n" + step.Tool + " · " + step.Result + (step.Passed is { } passed ? "\n" + passed + " passed · " + (step.Failed ?? 0) + " failed" : ""), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
    return new Flyout { Content = new ScrollViewer { Content = body, MaxHeight = 480 } };
  }
}
