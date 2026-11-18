using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  // Called once after CloudTools.Register. The same account answer controls tool discovery and use.
  private void InitializeCloudSubscription()
  {
    var previous = Door.ToolOffered;
    Door.ToolOffered = id => previous?.Invoke(id) != false && CloudPaidInventory.ShowsTool(Cloud.Snapshot.Subscription, id);
    CloudSubscriptionTools.Register(Cloud, Door);
    Cloud.Changed += _ => Changed?.Invoke();
  }
}
