using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Quality;

namespace TerminalDeck.App.Views.Quality;

public sealed class DeploymentHistory : StackPanel
{
  private readonly Deployments ledger;
  private readonly string project;
  public DeploymentHistory(Deployments ledger, string project)
  {
    this.ledger = ledger; this.project = project; Spacing = 8;
    Loaded += (_, _) => { ledger.Changed += Changed; Render(); }; Unloaded += (_, _) => ledger.Changed -= Changed; Render();
  }
  private void Changed() => DispatcherQueue.TryEnqueue(Render);
  private void Render()
  {
    Children.Clear(); var runs = ledger.Read(project).Take(30).ToArray();
    Children.Add(new TextBlock { Text = "Deployments", FontSize = 16, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
    if (runs.Length == 0) Children.Add(new TextBlock { Text = "No deployment has been reported for this project yet.", TextWrapping = TextWrapping.Wrap });
    foreach (var run in runs)
    {
      var detail = new StackPanel { Spacing = 6 };
      detail.Children.Add(new TextBlock { Text = "Reported by " + run.Actor + " · " + run.UpdatedAt.ToLocalTime().ToString("g"), TextWrapping = TextWrapping.Wrap });
      foreach (var step in run.Steps) detail.Children.Add(new TextBlock { Text = step.Name + " · " + step.State + " · " + step.Tool + "\n" + step.Result + (step.Passed is { } p ? "\n" + p + " passed · " + (step.Failed ?? 0) + " failed" : ""), TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
      Children.Add(new Expander { Header = run.Title, Content = detail, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch });
    }
  }
}
