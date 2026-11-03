using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Integration;

namespace TerminalDeck.App.Views.Hooks;

public sealed class HooksPage : UserControl
{
  private readonly StackPanel rows = new() { Spacing = 16 };
  private readonly TextBlock notice = new() { TextWrapping = TextWrapping.Wrap };
  public HooksPage(AppRuntime runtime, Func<HookAccountStatus[]>? fixtureStatuses = null)
  {
    if (fixtureStatuses is not null && Environment.GetEnvironmentVariable("TD_PARITY_PROOF") != "1") throw new InvalidOperationException("Synthetic hook statuses require the isolated parity renderer.");
    var body = new StackPanel { Spacing = 16, Padding = new Thickness(24), MaxWidth = 900, HorizontalAlignment = HorizontalAlignment.Stretch };
    body.Children.Add(new TextBlock { Text = "Session updates", FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
    body.Children.Add(new TextBlock { Text = "Coding AIs report when they start, need you or finish. Install for each account you use. Your other hooks stay in place.", TextWrapping = TextWrapping.Wrap });
    body.Children.Add(notice); body.Children.Add(rows); Content = new ScrollViewer { Content = body };
    void Refresh()
    {
      rows.Children.Clear();
      foreach (var row in (fixtureStatuses?.Invoke() ?? runtime.ProviderHookStatuses()))
      {
        var card = new StackPanel { Spacing = 8 };
        card.Children.Add(new TextBlock { Text = row.Name + " · " + row.Provider + " · " + row.Status.State, FontSize = 16, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
        card.Children.Add(new TextBlock { Text = row.Status.Message, TextWrapping = TextWrapping.Wrap });
        card.Children.Add(new TextBlock { Text = row.Status.InstalledEvents.Length + " installed · " + row.Status.MissingEvents.Length + " missing · " + row.Status.ForeignHooks + " other hooks", TextWrapping = TextWrapping.Wrap });
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        foreach (var install in new[] { true, false })
        {
          var button = new Button { Content = install ? "Install or repair" : "Remove app hooks", IsEnabled = fixtureStatuses is null && row.Status.State != "error" };
          button.Click += (_, _) =>
          {
            try { var status = runtime.ChangeProviderHooks(row.AccountId, install); notice.Text = install ? "Session updates installed. " + status.Message : "This app's hooks removed. Other hooks kept."; }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException) { notice.Text = e.Message; }
            Refresh();
          };
          actions.Children.Add(button);
        }
        card.Children.Add(actions); rows.Children.Add(card);
      }
      if (rows.Children.Count == 0) rows.Children.Add(new TextBlock { Text = "Add a coding AI account in Settings first." });
    }
    Refresh();
  }
}
