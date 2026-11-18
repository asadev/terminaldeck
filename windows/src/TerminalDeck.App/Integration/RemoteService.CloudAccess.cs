using TerminalDeck.Core.Remote;

namespace TerminalDeck.App.Integration;

public sealed partial class RemoteService
{
  private readonly CloudRelayLifecycle cloudLifecycle = new();
  public Func<bool> CloudServicesAllowed
  {
    get => cloudLifecycle.CloudServicesAllowed;
    set => cloudLifecycle.CloudServicesAllowed = value;
  }
  public bool CloudRelayAllowed => cloudLifecycle.Allowed;
  private CloudRelayMode RunningCloudMode => relay is null ? CloudRelayMode.Stopped : phonesEnabled ? CloudRelayMode.Phones : CloudRelayMode.Receiver;
  private bool ReceiverWanted() => ReceiverTransportRequired?.Invoke() == true;

  // Use for the existing automatic launch, so a known unpaid answer never
  // aborts initialization of local sessions, accounts, hooks or WhatsApp.
  public async Task StartAtLaunchAsync()
  {
    await lifecycleGate.WaitAsync(stop.Token);
    try
    {
      cloudLifecycle.RequestPhones(true, existingAtLaunch: true);
      if (CloudRelayAllowed)
      {
        if (relay is not null && !phonesEnabled) await EndHostEpochAsync(CancellationToken.None);
        await StartHostCoreAsync();
      }
    }
    catch { await EndHostEpochAsync(CancellationToken.None, preserveLocal: !CloudRelayAllowed); throw; }
    finally { lifecycleGate.Release(); }
  }
  public async Task ReconcileCloudServicesAsync()
  {
    await lifecycleGate.WaitAsync(stop.Token);
    try
    {
      await cloudLifecycle.ReconcileAsync(ReceiverWanted, () => RunningCloudMode,
        EndCloudRelayAsync, StartHostCoreAsync);
    }
    catch { await EndHostEpochAsync(CancellationToken.None, preserveLocal: !CloudRelayAllowed); throw; }
    finally { lifecycleGate.Release(); }
  }
  private async Task EndCloudRelayAsync()
  {
    await EndHostEpochAsync(CancellationToken.None, preserveLocal: true);
  }
}
