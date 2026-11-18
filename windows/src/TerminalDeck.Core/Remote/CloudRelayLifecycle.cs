namespace TerminalDeck.Core.Remote;

public enum CloudRelayMode { Stopped, Receiver, Phones }

// This owns runtime intent, never a preference file or device trust. The app
// supplies the service answer; old services and paywall-off keep the true default.
public sealed class CloudRelayLifecycle
{
  private Func<bool> allowed = static () => true;
  public Func<bool> CloudServicesAllowed
  {
    get => Volatile.Read(ref allowed);
    set => Volatile.Write(ref allowed, value ?? throw new ArgumentNullException(nameof(value)));
  }
  public bool Allowed => CloudServicesAllowed();
  public bool PhonesRequested { get; private set; }
  public static string SubscriptionRequired => Brand.Name + " Cloud is needed for access through the relay. Subscribe in the phone app, or use this computer’s local features.";
  public void RequireAllowed() { if (!Allowed) throw new InvalidOperationException(SubscriptionRequired); }
  public void RequestPhones(bool enabled, bool existingAtLaunch = false)
  {
    if (enabled && !existingAtLaunch) RequireAllowed();
    PhonesRequested = enabled;
  }
  public CloudRelayMode Wanted(bool receiverRequested) => !Allowed ? CloudRelayMode.Stopped
    : PhonesRequested ? CloudRelayMode.Phones : receiverRequested ? CloudRelayMode.Receiver : CloudRelayMode.Stopped;

  // The transport owner holds its normal lifecycle lock around this operation.
  // Re-read both entitlement and intent after a stop: neither is frozen across await.
  public async Task ReconcileAsync(Func<bool> receiverRequested, Func<CloudRelayMode> current,
    Func<Task> stopRelay, Func<bool, Task> startRelay)
  {
    var wanted = Wanted(receiverRequested());
    if (current() == wanted) return;
    if (current() != CloudRelayMode.Stopped) await stopRelay();
    wanted = Wanted(receiverRequested());
    if (wanted != CloudRelayMode.Stopped) await startRelay(wanted == CloudRelayMode.Phones);
  }
}
