namespace TerminalDeck.Core.Cloud;

// Joining (owner, 13 Nov): after sign-in Cloud is on for this PC by itself (the sign-in registers this PC and opens
// Cloud; there is no second step). The person can turn it off with one switch, "Use Cloud on this PC", in Settings →
// Cloud. The choice lives in the protected record with the sign-in, so it goes with the sign-in at sign-out.
public sealed partial class CloudAccountClient
{
  /// The person's switch. Off keeps the sign-in, the device and the trusted list; it only marks Cloud off here (the
  /// sync core reads `Snapshot.UseCloud` before it sends or applies anything). On asks Cloud again.
  public async Task SetUseCloudAsync(bool on, CancellationToken ct = default)
  {
    await work.WaitAsync(ct);
    try
    {
      if (!Load() || Snapshot.Phase is not (CloudPhase.SignedIn or CloudPhase.Paused)) throw new CloudFailure("gate_closed");
      if (saved!.CloudOff == !on) return;
      Save(saved with { CloudOff = !on });
      Publish(Snapshot with { Phase = on ? CloudPhase.SignedIn : CloudPhase.Paused });
      if (on) await RefreshLockedAsync(generation, ct);
    }
    finally { work.Release(); }
  }
}
