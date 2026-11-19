using TerminalDeck.Core.Cloud;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private readonly SemaphoreSlim subscriptionLifecycle = new(1, 1);
  private Action<CloudSnapshot>? subscriptionChanged;
  private bool? appliedCloudAccess;
  public bool CloudServicesAllowed => Cloud.Snapshot.Subscription.AllowsCloudServices;
  /// 19 Nov free plan: the relay itself stays open for a free account (its devices reach this PC's sessions, this PC
  /// reaches its other computers' sessions); what each request may do is decided per kind (RemoteFreePlan).
  public bool RemoteSessionsAllowed => Cloud.Snapshot.Subscription.AllowsRemoteSessions;
  /// The Devices page and its switch: paid, or kept by a free account (19 Nov free plan).
  public bool DevicesAllowed => Cloud.Snapshot.Subscription.Offers(CloudPaidPlace.Devices);

  // The service projection alone controls discovery, stale calls and transport
  // admission. Off/old/unavailable answers preserve the app's previous behavior.
  private void InitializeCloudSubscription()
  {
    var previous = Door.ToolOffered;
    Door.ToolOffered = id => previous?.Invoke(id) != false && CloudPaidInventory.ShowsTool(Cloud.Snapshot.Subscription, id);
    var relayAllowed = Door.RelayAllowed;
    Door.RelayAllowed = () => relayAllowed?.Invoke() != false && CloudServicesAllowed;
    // The relay transport follows remote sessions (free or paid); AI apps through the relay (Door.RelayAllowed above),
    // the Cloud pages and every paid place keep following the paid plan.
    Remote.CloudServicesAllowed = () => RemoteSessionsAllowed;
    OtherComputers.CloudServicesAllowed = () => CloudServicesAllowed;
    OtherComputers.RemoteSessionsAllowed = () => RemoteSessionsAllowed;
    CloudSubscriptionTools.Register(Cloud, Door);
    var shown = Cloud.Snapshot.Subscription.ShowsSubscription;
    var allowed = CloudServicesAllowed;
    var remote = RemoteSessionsAllowed;
    var limited = Cloud.Snapshot.Subscription.LimitsRemoteToSessions;
    appliedCloudAccess = remote;
    subscriptionChanged = snapshot =>
    {
      var next = snapshot.Subscription;
      var accessChanged = allowed != next.AllowsCloudServices || remote != next.AllowsRemoteSessions;
      var visibilityChanged = shown != next.ShowsSubscription;
      var becameFree = !limited && next.LimitsRemoteToSessions;
      allowed = next.AllowsCloudServices; remote = next.AllowsRemoteSessions; shown = next.ShowsSubscription; limited = next.LimitsRemoteToSessions;
      // A lapse (Decker, 20 Nov): at the plan read that makes the account free, the connections that were served a paid
      // kind end whole, with their browser, screen and tunnel streams (code 1001 on the Mac; a relay close here).
      if (becameFree) { _ = FreePlanBeganAsync(); _ = JoinAccountMachinesAsync(); }
      if (accessChanged) { Changed?.Invoke(); _ = ReconcileCloudSubscriptionAsync(); }
      else if (visibilityChanged || becameFree) Changed?.Invoke();
    };
    Cloud.Changed += subscriptionChanged;
  }

  private async Task ReconcileCloudSubscriptionAsync()
  {
    await subscriptionLifecycle.WaitAsync();
    try
    {
      if (Volatile.Read(ref runtimeDisposed) != 0) return;
      var allowed = RemoteSessionsAllowed;
      if (appliedCloudAccess == allowed) return;
      await Remote.ReconcileCloudServicesAsync();
      await OtherComputers.ReconcileCloudServicesAsync();
      appliedCloudAccess = allowed;
      Changed?.Invoke();
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { WriteCloudLog("subscription: transport reconciliation failed: " + ex.GetType().Name); }
    finally { subscriptionLifecycle.Release(); }
  }

  private async Task FreePlanBeganAsync()
  {
    try
    {
      if (Volatile.Read(ref phoneHostFeatures) is not { } features) return;
      var channels = features.FreePlanBegan();
      if (channels.Count == 0) return;
      WriteCloudLog("free plan: " + channels.Count + " connection(s) with paid streams closed");
      await Remote.CloseChannelsAsync(channels);
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { WriteCloudLog("free plan: closing paid streams failed: " + ex.GetType().Name); }
  }
}
