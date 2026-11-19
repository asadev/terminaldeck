using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.App.Integration;

public sealed partial class OtherComputersService
{
  private Func<bool> cloudServicesAllowed = static () => true;
  public Func<bool> CloudServicesAllowed
  {
    get => Volatile.Read(ref cloudServicesAllowed);
    set => Volatile.Write(ref cloudServicesAllowed, value ?? throw new ArgumentNullException(nameof(value)));
  }
  // 19 Nov free plan: reaching other computers' sessions through the relay is free (RemoteAllowed); their browser windows,
  // screens, pairing by code and this PC's browser for their sessions stay paid (PaidAllowed). Unset, it follows the plan.
  private Func<bool>? remoteSessionsAllowed;
  public Func<bool> RemoteSessionsAllowed
  {
    get => Volatile.Read(ref remoteSessionsAllowed) ?? CloudServicesAllowed;
    set => Volatile.Write(ref remoteSessionsAllowed, value ?? throw new ArgumentNullException(nameof(value)));
  }
  public bool RemoteAllowed => RemoteSessionsAllowed();
  public bool PaidAllowed => CloudServicesAllowed();
  private void RequireRemoteAccess()
  {
    if (!RemoteAllowed) throw new InvalidOperationException(CloudRelayLifecycle.SubscriptionRequired);
  }
  private void RequirePaidAccess()
  {
    if (!PaidAllowed) throw new InvalidOperationException(CloudSubscriptionPageText.Subscribe);
  }
  public async Task ReconcileCloudServicesAsync()
  {
    if (RemoteAllowed)
    {
      foreach (var id in wanted.Keys) if (!List().Any(row => row.Id == id && row.State is "Online" or "Connecting")) ScheduleReconnect(id);
      Changed?.Invoke(); return;
    }
    Changed?.Invoke();
    await mutations.WaitAsync();
    try
    {
      foreach (var pair in links.ToArray())
      {
        links.Remove(pair.Key); pair.Value.Stop.Cancel(); await pair.Value.Channel.DisposeAsync();
        FailRequests(pair.Key); CancelUpload(pair.Key); RevokeBrowser(pair.Key);
      }
      lock (views)
        foreach (var id in views.Keys.ToArray()) views[id] = views[id] with { State = "Disconnected", Capabilities = [], Displays = [] };
    }
    finally { mutations.Release(); }
    foreach (var reach in reaches.Values.ToArray()) await ClosePortAsync(reach.Computer, reach.Remote);
    Changed?.Invoke();
  }
}
