using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Views.Settings;

// A desktop only reads the service's plan. Purchases and management stay with the store that sold it.
public sealed class CloudSubscriptionPage : UserControl
{
  private readonly CloudAccountClient account;
  private readonly StackPanel body = AccountPages.Body();
  private readonly Action<CloudSnapshot> changed;
  public CloudSubscriptionPage(CloudAccountClient account)
  {
    this.account = account;
    AutomationProperties.SetAutomationId(this, "settings.subscription");
    Content = AccountPages.Scroll(body);
    changed = _ => DispatcherQueue.TryEnqueueHandled(Render);
    Loaded += (_, _) => { account.Changed += changed; Render(); };
    Unloaded += (_, _) => account.Changed -= changed;
    Render();
  }

  private void Render()
  {
    body.Children.Clear();
    var snapshot = account.Snapshot.Subscription;
    if (!snapshot.ShowsSubscription || snapshot.LastAnswer is not { } answer) return;
    var title = new StackPanel { Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center, Margin = new(0, 12, 0, 0) };
    title.Children.Add(SettingsPanel.IconTile("", "DeckAgentIndigoBrush", 56));
    title.Children.Add(new TextBlock { Text = CloudSubscriptionPageText.Title, FontSize = 17, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, HorizontalAlignment = HorizontalAlignment.Center });
    if (answer.State == "gift") title.Children.Add(Words(CloudSubscriptionPageText.Gift));
    if (!answer.Entitled)
    {
      // Free or ended: what it adds, the price and where to subscribe (this PC sells nothing, so there is no button).
      if (CloudSubscriptionPageText.Ended(answer) is { } ended)
      {
        var line = Words(ended); line.SetResourceReference(TextBlock.ForegroundProperty, "DeckInkBrush"); title.Children.Add(line);
      }
      title.Children.Add(Words(CloudSubscriptionPageText.Benefit(answer.IncludedGb)));
      title.Children.Add(new TextBlock { Text = CloudSubscriptionPageText.Price, FontSize = 15, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, Margin = new(0, 8, 0, 0), HorizontalAlignment = HorizontalAlignment.Center });
      title.Children.Add(Words(CloudSubscriptionPageText.Subscribe));
      body.Children.Add(title);
      return;
    }
    body.Children.Add(title);
    var rows = new List<FrameworkElement>();
    if (answer.State == "paid")
    {
      rows.Add(SettingsPanel.SettingRow("Plan", "", SettingsPanel.StateText(CloudSubscriptionPageText.Plan(answer.Plan))));
      if (answer.PaidUntil is { } until) rows.Add(SettingsPanel.SettingRow("Paid until", "", SettingsPanel.StateText(CloudSubscriptionPageText.Date(until))));
      if (CloudSubscriptionPageText.Source(answer.Source) is { } source) rows.Add(SettingsPanel.SettingRow("Paid through", "", SettingsPanel.StateText(source)));
    }
    rows.Add(SettingsPanel.SettingRow("Storage", CloudSubscriptionPageText.StorageInfo(answer) ?? "", SettingsPanel.StateText(CloudSubscriptionPageText.Storage(answer))));
    body.Children.Add(SettingsPanel.GroupRows(rows));
    if (CloudSubscriptionPageText.Manage(answer.Source) is { } manage) body.Children.Add(Words(manage));
    // A gift can still be upgraded to the paid plan (Asad, 19 Nov: "so that user can at least upgrade").
    if (answer.State == "gift") body.Children.Add(Words(CloudSubscriptionPageText.Subscribe));
  }

  private static TextBlock Words(string words)
  {
    var text = new TextBlock { Text = words, FontSize = 13, MaxWidth = 400, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
    text.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
    return text;
  }
}
