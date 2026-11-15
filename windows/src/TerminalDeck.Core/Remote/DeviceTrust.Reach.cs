using System.Security.Cryptography;

namespace TerminalDeck.Core.Remote;

// Reach by account in the phone host's trust (port of the Mac's BackendRemoteTrustStore reach part and BackendRemoteHost's
// `reach:` hello). Nothing here is saved: the paired-device file is never touched, so a PC updated from 0.21.x keeps every
// paired phone exactly as it was. An account device exists here only while it is connected: the relay connection tells
// which sealed channel the door admitted (AdmitReachChannel), and only that channel may say `reach:<deviceId>`, with the
// key the door admitted. It gets full access, as the person's own device (no folder or login questions).
public sealed partial class DeviceTrust
{
  private readonly Dictionary<string, ReachAdmission> reachChannels = [];
  private readonly Dictionary<string, ReachAdmission> reachDevices = [];
  private Func<string, bool>? reachJudge;
  private object? reachJudgeOwner;
  private bool pairingLockedByReach;

  /// While reach by account is live on this PC, no pairing code can be made or redeemed (owner, 13 Nov: devices join by
  /// signing in). Off, pairing is exactly as before. Devices paired earlier keep working either way.
  public bool PairingLockedByReach { get { lock (gate) return pairingLockedByReach; } }
  public void SetPairingLockedByReach(bool on)
  {
    bool changed;
    lock (gate) { changed = pairingLockedByReach != on; pairingLockedByReach = on; }
    if (on) Pairing.Cancel();
    if (changed) Changed?.Invoke();
  }

  public void SetReachJudge(object owner, Func<string, bool> judge) { lock (gate) { reachJudgeOwner = owner; reachJudge = judge; } }
  /// Ends this owner's judge: from now on every reach hello is refused (a later owner's judge is never undone).
  public void EndReachJudge(object owner) { lock (gate) if (ReferenceEquals(reachJudgeOwner, owner)) reachJudge = _ => false; }

  /// The relay connection's door admitted this sealed channel for this device (never set by a message).
  public void AdmitReachChannel(string channel, ReachAdmission admission) { lock (gate) reachChannels[channel] = admission; }
  public bool IsReachChannel(string channel) { lock (gate) return reachChannels.ContainsKey(channel); }

  /// A `reach:<deviceId>` hello. Taken only on a channel the door admitted, naming that same device, with the key the
  /// door admitted, while the gate still admits it. Any paired credential on such a channel is refused too.
  public ApprovedDevice AuthenticateReach(string channel, string token, ReadOnlySpan<byte> peerKey)
  {
    lock (gate)
    {
      if (!reachChannels.TryGetValue(channel, out var admission) || token != admission.HelloToken || peerKey.Length != 32 ||
        !CryptographicOperations.FixedTimeEquals(peerKey, admission.ReachKey)) throw Refused();
      if (reachJudge is { } judge && !judge(admission.DeviceId)) throw new ProtocolException("This device can no longer reach this PC.");
      reachDevices[admission.HostDeviceId] = admission;
      return ReachView(admission);
    }
  }

  /// Every hello's credential check: a `reach:` hello, or any hello on an account channel, goes the reach way; every
  /// other one is today's paired check, unchanged.
  public ApprovedDevice AuthenticateHello(string channel, string token, ReadOnlySpan<byte> peerKey) =>
    IsReachChannel(channel) || token.StartsWith("reach:", StringComparison.Ordinal) ? AuthenticateReach(channel, token, peerKey) : Authenticate(token, peerKey);

  /// The account devices connected now (their account device ids).
  public IReadOnlySet<string> ReachConnectedDeviceIds()
  {
    lock (gate) return connectedChannels.Where(c => reachChannels.ContainsKey(c.Key) && ReachAdmission.IsHostId(c.Value)).Select(c => reachChannels[c.Key].DeviceId).ToHashSet();
  }
  /// The phone host ids of the account devices welcomed now (for the direct-link logins).
  public IReadOnlyCollection<string> ReachDeviceIds() { lock (gate) return reachDevices.Keys.ToArray(); }

  /// Removed, switched off or signed out: these account devices (null = every one) are forgotten here; the relay
  /// connection closes their channels.
  public void DropReachDevices(IReadOnlyCollection<string>? deviceIds)
  {
    lock (gate)
    {
      foreach (var channel in reachChannels.Where(c => deviceIds is null || deviceIds.Contains(c.Value.DeviceId)).Select(c => c.Key).ToArray())
      { reachChannels.Remove(channel); connectedChannels.Remove(channel); }
      foreach (var id in reachDevices.Where(d => deviceIds is null || deviceIds.Contains(d.Value.DeviceId)).Select(d => d.Key).ToArray()) reachDevices.Remove(id);
    }
    Changed?.Invoke();
  }

  private ApprovedDevice ReachView(ReachAdmission a) =>
    new(a.HostDeviceId, a.Label, a.Platform, PhoneAccess.Full, null, clock.GetUtcNow(), connectedChannels.Values.Contains(a.HostDeviceId));

  // Under `gate`: the reach device behind a phone host id, when its key matches and the gate still admits it.
  private ApprovedDevice? CurrentReach(string id, ReadOnlySpan<byte> peerKey)
  {
    if (!reachDevices.TryGetValue(id, out var admission) || peerKey.Length != 32 || !CryptographicOperations.FixedTimeEquals(peerKey, admission.ReachKey)) return null;
    if (reachJudge is { } judge && !judge(admission.DeviceId)) return null;
    return ReachView(admission);
  }
  private ApprovedDevice? ReachFor(ReadOnlySpan<byte> peerKey)
  {
    foreach (var admission in reachDevices.Values)
      if (peerKey.Length == 32 && CryptographicOperations.FixedTimeEquals(peerKey, admission.ReachKey)) return ReachView(admission);
    return null;
  }
  private void ReachChannelGone(string channel) => reachChannels.Remove(channel);
}
