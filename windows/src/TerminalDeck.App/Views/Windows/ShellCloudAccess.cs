using Microsoft.UI.Xaml;
using TerminalDeck.App.Shell;
using TerminalDeck.App.ViewModels;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private bool? shownCloudAccess;
  private bool CloudPageAllowed(ShellPage page) => Runtime.CloudServicesAllowed || page is not (ShellPage.Cloud or ShellPage.CloudChat or ShellPage.Devices);
  private FrameworkElement CloudSurface(FrameworkElement content) => new CloudAccessSurface(content, () => Runtime.CloudServicesAllowed, h => Runtime.Changed += h, h => Runtime.Changed -= h);
  private void ShowCloudSubscription()
  {
    ShowSettingsPanel();
    if (settingsPanel is not null) _ = settingsPanel.SelectAsync(Runtime.Cloud.Snapshot.Subscription.ShowsSubscription ? CloudSubscriptionPageText.Id : "profile");
  }
  private void RefreshCloudAccessUi()
  {
    if (windowState is null || sidebar is null || shownCloudAccess == Runtime.CloudServicesAllowed) return;
    shownCloudAccess = Runtime.CloudServicesAllowed; RenderSidebarPages(); RenderCloudSessionRows();
    if (!Runtime.CloudServicesAllowed) morePagesFlyout?.Hide();
    renderedWindowsStructure = ""; RenderWindows();
  }
  private IEnumerable<ShellCommand> VisibleShellCommands(string query) => ShellCommands.Matching(query).Where(command => CloudPaidInventory.ShowsCommand(Runtime.Cloud.Snapshot.Subscription, command.Id));
}
