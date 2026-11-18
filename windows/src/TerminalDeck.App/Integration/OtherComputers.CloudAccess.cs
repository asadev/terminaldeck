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
  public bool CloudAllowed => CloudServicesAllowed();
  private void RequireCloudAccess()
  {
    if (!CloudAllowed) throw new InvalidOperationException(CloudRelayLifecycle.SubscriptionRequired);
  }
  public async Task ReconcileCloudServicesAsync()
  {
    if (CloudAllowed)
    {
      foreach (var id in wanted.Keys) if (!List().Any(row => row.Id == id && row.State is "Online" or "Connecting")) ScheduleReconnect(id);
      Changed?.Invoke(); return;
    }
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
