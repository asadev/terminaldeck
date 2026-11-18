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
    title.Children.Add(Words(CloudSubscriptionPageText.Benefit));
    body.Children.Add(title);
    if (answer.Entitled)
    {
      var rows = new List<FrameworkElement>();
      if (answer.State == "gift" || answer.Plan is not null) rows.Add(SettingsPanel.SettingRow("Plan", "", SettingsPanel.StateText(answer.State == "gift" ? "Included" : answer.Plan == "yearly" ? "Yearly" : "Monthly")));
      if (answer.PaidUntil is { } until) rows.Add(SettingsPanel.SettingRow("Paid until", "", SettingsPanel.StateText(CloudSubscriptionPageText.Date(until))));
      if (answer.Source is "apple" or "google") rows.Add(SettingsPanel.SettingRow("Paid through", "", SettingsPanel.StateText(answer.Source == "apple" ? "Apple" : "Google Play")));
      var storage = (long)answer.IncludedGb + answer.ExtraGb;
      rows.Add(SettingsPanel.SettingRow("Storage", $"{answer.IncludedGb} GB included" + (answer.ExtraGb > 0 ? $" · {answer.ExtraGb} GB extra" : ""), SettingsPanel.StateText(storage + " GB")));
      body.Children.Add(SettingsPanel.GroupRows(rows));
      if (answer.Source is "apple" or "google") body.Children.Add(Words("Change or cancel it in the " + TerminalDeck.Core.Brand.Name + " app on your " + (answer.Source == "apple" ? "iPhone." : "Android phone.")));
    }
    else
    {
      if (answer.State == "lapsed")
      {
        var ended = answer.PaidUntil is { } until ? "Your plan ended on " + CloudSubscriptionPageText.Date(until) + "." : "Your plan ended.";
        if (answer.DataKeptUntil is { } kept) ended += " Your Cloud data is kept until " + CloudSubscriptionPageText.Date(kept) + ".";
        body.Children.Add(Words(ended));
      }
      var price = Words(CloudSubscriptionPageText.Price); price.FontSize = 15; price.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; body.Children.Add(price);
      body.Children.Add(Words(CloudSubscriptionPageText.Subscribe));
    }
  }

  private static TextBlock Words(string words)
  {
    var text = new TextBlock { Text = words, FontSize = 13, MaxWidth = 400, TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
    text.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
    return text;
  }
}
