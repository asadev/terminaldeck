using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private readonly SemaphoreSlim subscriptionLifecycle = new(1, 1);
  private Action<CloudSnapshot>? subscriptionChanged;
  private bool? appliedCloudAccess;
  public bool CloudServicesAllowed => Cloud.Snapshot.Subscription.AllowsCloudServices;

  // The service projection alone controls discovery, stale calls and transport
  // admission. Off/old/unavailable answers preserve the app's previous behavior.
  private void InitializeCloudSubscription()
  {
    var previous = Door.ToolOffered;
    Door.ToolOffered = id => previous?.Invoke(id) != false && CloudPaidInventory.ShowsTool(Cloud.Snapshot.Subscription, id);
    var relayAllowed = Door.RelayAllowed;
    Door.RelayAllowed = () => relayAllowed?.Invoke() != false && CloudServicesAllowed;
    Remote.CloudServicesAllowed = () => CloudServicesAllowed;
    OtherComputers.CloudServicesAllowed = () => CloudServicesAllowed;
    CloudSubscriptionTools.Register(Cloud, Door);
    var shown = Cloud.Snapshot.Subscription.ShowsSubscription;
    var allowed = CloudServicesAllowed;
    appliedCloudAccess = allowed;
    subscriptionChanged = snapshot =>
    {
      var next = snapshot.Subscription;
      var accessChanged = allowed != next.AllowsCloudServices;
      var visibilityChanged = shown != next.ShowsSubscription;
      allowed = next.AllowsCloudServices; shown = next.ShowsSubscription;
      if (accessChanged) { Changed?.Invoke(); _ = ReconcileCloudSubscriptionAsync(); }
      else if (visibilityChanged) Changed?.Invoke();
    };
    Cloud.Changed += subscriptionChanged;
  }

  private async Task ReconcileCloudSubscriptionAsync()
  {
    await subscriptionLifecycle.WaitAsync();
    try
    {
      if (Volatile.Read(ref runtimeDisposed) != 0) return;
      var allowed = CloudServicesAllowed;
      if (appliedCloudAccess == allowed) return;
      await Remote.ReconcileCloudServicesAsync();
      await OtherComputers.ReconcileCloudServicesAsync();
      appliedCloudAccess = allowed;
      Changed?.Invoke();
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { WriteCloudLog("subscription: transport reconciliation failed: " + ex.GetType().Name); }
    finally { subscriptionLifecycle.Release(); }
  }
}
