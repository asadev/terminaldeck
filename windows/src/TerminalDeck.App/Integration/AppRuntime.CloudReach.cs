using System.Text.Json;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Remote;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Integration;

/// Reach by account on this PC (Devices seat, port of the Mac's NativeReachAccount.swift): joins the phone host and the
/// signed-in Cloud account into ONE ReachAccountCoordinator. Built only while signed in. The switch ("Let my signed-in
/// devices open this PC", on the Devices page) is ON by default: a PC that never chose is switched on once, here; a
/// choice the person made is kept, and a damaged settings file still reads as OFF. Devices paired with a code before
/// keep working whatever the switch says; while it is on, no new code is offered (devices join by signing in).
public sealed partial class AppRuntime
{
  private readonly SemaphoreSlim reachGate = new(1, 1);
  private string? reachFor;
  private bool reachSuspended;
  /// Null while signed out.
  public ReachAccountCoordinator? Reach { get; private set; }
  /// This PC reaching his other machines by the same sign-in (the live chat page). Null while signed out.
  public ReachGuest? ReachGuest { get; private set; }
  /// The last reach notice, also shown on the Devices page (names only).
  public string? ReachNotice { get; private set; }
  public event Action? ReachChanged;

  /// Called once after InitializeCloud (start-up wiring line).
  private void InitializeReach()
  {
    // 19 Nov free plan: reach by account is the relay, which a free account keeps (sessions only).
    OtherComputers.AccountGuest = () => RemoteSessionsAllowed ? ReachGuest : null;
    Cloud.Changed += snapshot => { _ = FollowCloudForReachAsync(); };
    ReachAccountTools.Register(Door, async () => Reach is { } reach ? await reach.StatusAsync() : null);
    _ = FollowCloudForReachAsync();
  }

  /// The account's event socket (wiring line in the sync bridge): `devices`, `gate`, `hello`.
  public void ReachEvent(string type, JsonElement payload)
  {
    if (type is not ("devices" or "gate" or "hello") || Reach is not { } reach) return;
    _ = Task.Run(async () =>
    {
      try { await reach.EventAsync(type, payload); }
      catch (Exception ex) when (ex is not OutOfMemoryException) { WriteCloudLog("reach: event failed: " + ex.GetType().Name); }
      ReachChanged?.Invoke();
    });
  }

  private async Task FollowCloudForReachAsync()
  {
    await reachGate.WaitAsync();
    try
    {
      var identity = Cloud.ReachIdentity;
      var allowed = RemoteSessionsAllowed;
      var wanted = identity is { } id ? id.Subject + "/" + id.DeviceId : null;
      if (allowed ? !reachSuspended && wanted == reachFor : reachSuspended) return;
      var sameAccountResume = allowed && reachSuspended && wanted == reachFor;
      reachSuspended = !allowed;
      if (allowed && !sameAccountResume) await OtherComputers.DisconnectAccountMachinesAsync();
      if (!allowed) await OtherComputers.ReconcileCloudServicesAsync();
      // Signed out, or another account or device id: nothing of the old one stays reachable.
      if (Reach is { } old)
      {
        Reach = null; ReachGuest?.Forget(); ReachGuest = null;
        try { if (allowed) await old.SignedOutAsync(); await old.StopAsync(); }
        catch (Exception ex) when (ex is not OutOfMemoryException) { WriteCloudLog("reach: stop failed: " + ex.GetType().Name); }
      }
      if (allowed) reachFor = wanted;
      if (!allowed || wanted is null) { ReachChanged?.Invoke(); return; }
      var port = new ReachAccountPort(
        () => Cloud.ReachIdentity?.Subject, () => Cloud.ReachIdentity?.DeviceId,
        async ct => (await Cloud.CredentialsAsync(ct)).AccessToken, Cloud.SignPack);
      var service = new ReachAccountHttpService(new Uri(CloudWire.ProductionBase), new HttpClientCloudSyncHttp(), port);
      var folder = Path.Combine(Root.DirectoryPath, "remote");
      var made = new ReachAccountCoordinator(folder, service, notice => { ReachNotice = notice.Sentence; ReachChanged?.Invoke(); },
        Remote.Trust, Remote.ReachCard, Remote.ReachLink, () => WindowsRemoteInputGuard.JustNow);
      // One Remove means one thing: reach's Remove also stops this PC taking that device's synced changes.
      made.SetTrustLink(id => Cloud.RemoveJoinedDeviceAsync(id));
      made.Changed += () => ReachChanged?.Invoke();
      var dpapi = new CurrentUserDpapi(Root);
      ReachGuest = new ReachGuest(service, new ReachGuestKeyFile(folder, plain => dpapi.Protect(plain), sealed_ => dpapi.Unprotect(sealed_)), RelayEndpoint.Default);
      // On by default: only a PC that never chose (no settings file yet) is switched on, once, without a press.
      made.Gate.SwitchOnByDefaultIfNeverChosen();
      Reach = made;
      await made.StartAsync();
      ReachChanged?.Invoke();
      if (Cloud.Snapshot.Subscription.LimitsRemoteToSessions) _ = JoinAccountMachinesAsync();
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { WriteCloudLog("reach: start failed: " + ex.GetType().Name); }
    finally { reachGate.Release(); }
  }

  /// 19 Nov free plan: the side panel lists his other computers' running sessions live, so every computer that is on is
  /// joined: at reach start, when the account becomes free, and when the app comes to the front (20 s apart at most).
  /// No timer; the links are kept while free (OtherComputersService never lets a link go when idle).
  private async Task JoinAccountMachinesAsync()
  {
    Volatile.Write(ref joinedAt, Environment.TickCount64);
    try
    {
      var missed = await OtherComputers.ConnectAccountMachinesAsync();
      if (missed > 0) WriteCloudLog("free plan: " + missed + " other computer(s) not reached");
    }
    catch (Exception ex) when (ex is not OutOfMemoryException) { WriteCloudLog("free plan: listing other computers failed: " + ex.GetType().Name); }
  }
  private long joinedAt;
  public void CameToFront()
  {
    var last = Volatile.Read(ref joinedAt);
    if (!Cloud.Snapshot.Subscription.LimitsRemoteToSessions || last != 0 && Environment.TickCount64 - last < 20_000) return;
    _ = JoinAccountMachinesAsync();
  }

  /// The switch, from the Devices page. On is a trust press (refused within 2 s of this PC's own remote input).
  public async Task<string?> SetReachEnabledAsync(bool on)
  {
    if (!DevicesAllowed) return CloudSubscriptionPageText.Subscribe;
    if (Reach is not { } reach) return "Sign in to your Terminal Deck account first.";
    try { await reach.SetEnabledAsync(on); return null; }
    catch (ReachRemoteInputException) { return "Turn this on at the PC itself, not from a connected device."; }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return "This could not be changed. Try again."; }
    finally { ReachChanged?.Invoke(); }
  }

  /// "Remove" on a device that reaches this PC by sign-in.
  public async Task<string?> RemoveReachDeviceAsync(string deviceId)
  {
    if (!DevicesAllowed) return CloudSubscriptionPageText.Subscribe;
    if (Reach is not { } reach) return null;
    try { await reach.RemoveAsync(deviceId); return null; }
    catch (CloudTrustRefusal) { return "It can no longer reach this PC, but this PC could not stop taking its changes yet. Remove it again in a moment."; }
    catch (Exception ex) when (ex is not OutOfMemoryException) { return "It can no longer reach this PC, but your account could not be told yet. It will be told next time."; }
    finally { ReachChanged?.Invoke(); }
  }
}
