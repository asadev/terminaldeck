using System.Security.Cryptography;
using System.Text;

namespace TerminalDeck.Core.Remote;

// stream step 2 (dc2, 2 Nov 2026; Asad: "whatever it takes, real experience, better speed AND quality, anywhere,
// no VPN"): ONE WebRTC peer connection per sealed relay connection carries the whole protocol (terminal output,
// keystrokes, every message) on an ordered data channel and This PC's video on two more.
// Direct only (batch #27, 3 Nov; Asad: "keep the new two, direct link and TURN backup, and remove old relay
// completely... It's okay if it will not connect"): the link is the only way data goes. The Worker relay is only the
// meeting point: pairing, the sealed hello, signalling, pings (presence) and alerts (push.*). When no link comes up the
// phone is told so (`link.peer end`) and nothing else crosses the relay.
// Contract: td-native-shell macos/night/codex/stream-step2-contract.md (the Mac host is the reference:
// BackendRemoteLink.swift + PeerLink.swift on lane/stream-step2).
//
// This file is the part every WebRTC stack shares: the channels, the DTLS-fingerprint binding to the sealed
// channel, part framing and path names. The stack itself plugs in through ILinkEngine.

/// The link's three negotiated data channels (contract §4).
public enum LinkLane
{
  /// `td.rt`: moving video frames (deltas); ordered, retried at most 150 ms.
  Moving = 1,
  /// `td.rel`: keyframes and the still frame's parts (M5); ordered, reliable. Over TCP every video frame.
  Still = 2,
  /// `td.ctl`: every other message, both ways; ordered, reliable.
  Control = 3,
}

/// One ICE server: STUN, or a TURN login from the Worker's `/v1/turn`.
public sealed record LinkIceServer(IReadOnlyList<string> Urls, string? Username = null, string? Credential = null);

/// The ICE servers a new link uses and its path policy ("all" in the product; "nohost" / "relay" only to measure).
public sealed record LinkServers(IReadOnlyList<LinkIceServer> Servers, string Policy);

/// What a stack reports for one link. `Message` is one whole message (parts already joined), called in arrival
/// order, one at a time. `Closed` is called at most once and never after ILinkConnection.Close.
public sealed record LinkEvents(Action<string, string?, int> Candidate, Action<string> Open, Action<string> Closed, Action<byte[], LinkLane> Message);

public interface ILinkConnection
{
  /// The offer SDP, already the local description (host side).
  Task<string> OfferAsync(CancellationToken cancellationToken);
  Task AcceptAsync(string answer, CancellationToken cancellationToken);
  /// A candidate from the other side; held until the remote description is set.
  void AddCandidate(string candidate, string? mid, int index);
  /// One whole message on `lane` (the stack cuts it into parts). False when the channel is not open, the moving
  /// channel has more than LinkFrames.MostQueuedMoving waiting, or the stack refused it.
  bool Send(ReadOnlySpan<byte> message, LinkLane lane);
  void Close();
  /// The selected path crosses TCP: a TURN leg over TCP or TLS on either side (UDP blocked). SCTP then never loses a
  /// packet and a frame with a lifetime only ever expires in a queue, so video goes the reliable way (M5).
  bool OverTcp => false;
  /// Bytes waiting to go on `lane`.
  long Queued(LinkLane lane) => 0;
}

/// How a connection's link carries video now (M5): every frame on `td.rel` when the path crosses TCP, and the bytes
/// waiting on `td.rt` and on `td.rel`.
public sealed record LinkVideo(bool ReliableOnly, long QueuedMoving, long QueuedStill);

/// The answering end of a link (a desktop guest, "Other computers"; the phones and the web have their own): the same
/// three negotiated channels and failure rules as the host's end.
public interface ILinkAnswerConnection
{
  /// The answer SDP for the host's offer, already the local description.
  Task<string> AnswerAsync(string offer, CancellationToken cancellationToken);
  void AddCandidate(string candidate, string? mid, int index);
  bool Send(ReadOnlySpan<byte> message, LinkLane lane);
  void Close();
}

public interface ILinkAnswerEngine
{
  ILinkAnswerConnection ConnectAnswerer(LinkServers servers, LinkEvents events);
}

public interface ILinkEngine
{
  /// A new peer connection with the three negotiated channels (unified plan, max-bundle, rtcp-mux require,
  /// continual gathering, ICE transport policy from `servers.Policy`).
  ILinkConnection Connect(LinkServers servers, LinkEvents events);
}

/// A phone host's link: the stack and where a device's ICE servers come from (its own TURN login, Security M2). A
/// relay connection with a setup offers every approved phone ONE link, the only way its data goes (contract §11); one
/// without (the pairing beacon, the receiver-only host) offers none.
public sealed record LinkSetup(ILinkEngine Engine, Func<string, CancellationToken, ValueTask<LinkServers>> Servers)
{
  /// The device a sealed connection's key belongs to when it may have a link: approved, any access (contract §11.6:
  /// Hoot-only too, it has nothing else to talk over); never pending or revoked. Null = no link. The default offers nothing.
  public Func<ReadOnlyMemory<byte>, string?> Eligible { get; init; } = _ => null;
  /// A device's TURN login is withdrawn: its last link closed (`force` false: only the login this run gave it) or it
  /// was unpaired or lost access (`force` true: whatever it holds).
  public Func<string, bool, Task> Release { get; init; } = (_, _) => Task.CompletedTask;
  /// How long a login stays after its device's last link closed (§11.6: a reconnect within it reuses the login).
  public TimeSpan ReleaseAfter { get; init; } = TimeSpan.FromMinutes(2);
}

/// Who may have a link and a TURN login (Security M2, revised by contract §11.6): every approved device, Hoot-only
/// included. Pending and revoked devices get neither.
public static class LinkEligibility
{
  public static bool Allows(ApprovedDevice device) => true;

  /// The connection key → device lookup a host uses at the welcome.
  public static Func<ReadOnlyMemory<byte>, string?> For(DeviceTrust trust) =>
    key => trust.ApprovedFor(key.Span) is { } device && Allows(device) ? device.Id : null;

  /// The devices that may hold a TURN login now (each may have a link), and every device the trust store knows
  /// (approved or pending).
  public static (IReadOnlyCollection<string> Eligible, IReadOnlyCollection<string> Known) Devices(DeviceTrust trust) =>
    (trust.List().Where(Allows).Select(d => d.Id).ToHashSet(), trust.List().Concat(trust.Pending()).Select(d => d.Id).ToHashSet());
}

/// A phone host whose WebRTC stack is missing or broken still has a setup: every link it tries fails with the reason,
/// the phone is told it cannot reach this PC directly, and nothing goes over the relay instead (no hidden fallback).
public sealed class UnavailableLinkEngine(string why) : ILinkEngine, ILinkAnswerEngine
{
  public string Why { get; } = why;
  public ILinkConnection Connect(LinkServers servers, LinkEvents events) => throw new InvalidOperationException(Why);
  public ILinkAnswerConnection ConnectAnswerer(LinkServers servers, LinkEvents events) => throw new InvalidOperationException(Why);
}

/// Contract §3: bind = base64(HMAC-SHA256(key = sealed channel binding, "td.link.v2|" + role + "|" + fp)).
///
/// The channel binding (the final Noise handshake hash) is PUBLIC: anyone who saw the handshake and knows this PC's key
/// can compute it, the relay included. So `bind` is a consistency check, not a signature. What protects a DTLS
/// fingerprint is that it travels only inside the sealed, mutually authenticated Noise channel; libwebrtc then refuses
/// any DTLS certificate that differs from the SDP's fingerprint (Security S2 / W4).
public static class LinkBinding
{
  public const string Capability = "link.dc2";
  /// Contract §11: nothing app-level on the relay, both ways (claimed by the client, answered by a host that offers the link).
  public const string OnlyCapability = "link.only";

  private static byte[] Data(string role, string fingerprint) => Encoding.UTF8.GetBytes("td.link.v2|" + role + "|" + fingerprint);

  public static string Make(ReadOnlySpan<byte> binding, string role, string fingerprint) =>
    Convert.ToBase64String(HMACSHA256.HashData(binding, Data(role, fingerprint)));

  public static bool Check(string? bind, ReadOnlySpan<byte> binding, string role, string fingerprint)
  {
    if (bind is null || bind.Length > 64) return false;
    var given = new byte[32];
    if (!Convert.TryFromBase64String(bind, given, out var length) || length != 32) return false;
    var expected = HMACSHA256.HashData(binding, Data(role, fingerprint));
    return CryptographicOperations.FixedTimeEquals(given, expected);
  }

  /// The SHA-256 DTLS fingerprint an SDP announces (everything after `a=fingerprint:`); null when there is none, or
  /// when the SDP names two different ones (which certificate would DTLS accept? — W4).
  public static string? Fingerprint(string sdp)
  {
    string? found = null;
    foreach (var raw in sdp.Split('\n'))
    {
      var line = raw.TrimEnd('\r');
      if (!line.StartsWith("a=fingerprint:", StringComparison.Ordinal)) continue;
      var value = line["a=fingerprint:".Length..].Trim();
      if (!value.StartsWith("sha-256 ", StringComparison.OrdinalIgnoreCase)) continue;
      if (found is not null && !string.Equals(found, value, StringComparison.OrdinalIgnoreCase)) return null;
      found ??= value;
    }
    return found;
  }
}

/// Contract §4 framing: a text longer than MostMessageBytes goes as parts (first byte 0x01 more / 0x02 last, then
/// at most MostMessageBytes - 1 bytes); a whole message starts with `{`. Joined messages are at most MostJoinedBytes.
public static class LinkFrames
{
  public const int MostMessageBytes = 200_000;
  public const int MostJoinedBytes = 4 * 1024 * 1024;
  /// A moving frame that cannot go at once (this much already waiting on `td.rt`) is dropped.
  public const long MostQueuedMoving = 1_500_000;
  public const int MovingLifetimeMs = 150;
  /// ICE "disconnected" longer than this ends the link (contract §7).
  public static readonly TimeSpan Disconnected = TimeSpan.FromSeconds(5);

  public static IReadOnlyList<byte[]> Parts(ReadOnlySpan<byte> message)
  {
    if (message.Length <= MostMessageBytes) return [message.ToArray()];
    var parts = new List<byte[]>();
    const int step = MostMessageBytes - 1;
    for (var at = 0; at < message.Length; at += step)
    {
      var length = Math.Min(step, message.Length - at);
      var part = new byte[length + 1];
      part[0] = at + length == message.Length ? (byte)0x02 : (byte)0x01;
      message.Slice(at, length).CopyTo(part.AsSpan(1));
      parts.Add(part);
    }
    return parts;
  }

  public enum Result { Whole, Waiting, Failure }

  /// One received data-channel message. `pending` holds the parts so far (one per channel).
  public static Result Join(ReadOnlySpan<byte> message, ref MemoryStream? pending, out byte[]? whole)
  {
    whole = null;
    if (message.IsEmpty) { pending = null; return Result.Failure; }
    if (message[0] is 0x01 or 0x02)
    {
      pending ??= new MemoryStream();
      if (pending.Length + message.Length - 1 > MostJoinedBytes) { pending = null; return Result.Failure; }
      pending.Write(message[1..]);
      if (message[0] == 0x01) return Result.Waiting;
      whole = pending.ToArray();
      pending = null;
      return Result.Whole;
    }
    // A whole message in the middle of parts breaks the rules.
    if (pending is not null) { pending = null; return Result.Failure; }
    whole = message.ToArray();
    return Result.Whole;
  }
}

/// Remote candidates a host passes on (Security S4 / W6): at most MostPerLink a link; the connection address is parsed
/// as an IP and loopback, unspecified, multicast and broadcast are dropped (IPv4-mapped forms too, and any spelling the
/// parser accepts); an mDNS `.local` name passes (a browser's host candidate); any other name is dropped.
public static class LinkCandidates
{
  public const int MostPerLink = 32;

  public static bool Usable(string line)
  {
    var words = (line.StartsWith("a=", StringComparison.Ordinal) ? line[2..] : line).Split(' ', StringSplitOptions.RemoveEmptyEntries);
    return words.Length > 5 && UsableAddress(words[4]);
  }

  public static bool UsableAddress(string text)
  {
    if (System.Net.IPAddress.TryParse(text, out var address))
    {
      if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
      if (System.Net.IPAddress.IsLoopback(address)) return false;
      var bytes = address.GetAddressBytes();
      if (address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
        return !(bytes[0] == 0 || bytes[0] == 127 || bytes[0] is >= 224 and <= 239 || bytes.All(b => b == 255));
      if (address.Equals(System.Net.IPAddress.IPv6Any) || address.IsIPv6Multicast) return false;
      return true;
    }
    // Not an address (TryParse also accepts forms like "1" or "0x7f000001", which land above): only mDNS names pass.
    var name = text.ToLowerInvariant();
    return name.EndsWith(".local", StringComparison.Ordinal) && name.Length <= 255 && name.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '.');
  }
}

/// The path name a stack reports when the link opens ("host", "internet" or "turn"), from the selected candidate pair.
public static class LinkPaths
{
  public static readonly LinkIceServer CloudflareStun = new(["stun:stun.cloudflare.com:3478"]);

  /// "host", "srflx", "prflx" or "relay" from a candidate line.
  public static string? CandidateType(string candidate)
  {
    var words = candidate.Split(' ', StringSplitOptions.RemoveEmptyEntries);
    var at = Array.IndexOf(words, "typ");
    return at >= 0 && at + 1 < words.Length ? words[at + 1] : null;
  }

  public static string Name(string local, string remote)
  {
    string?[] types = [CandidateType(local), CandidateType(remote)];
    if (types.Contains("relay")) return "turn";
    // A peer-reflexive candidate is an address learned from the checks themselves: on the same network it is a
    // private one, so the addresses decide, not the type.
    if (IsPrivate(Address(local)) && IsPrivate(Address(remote))) return "host";
    if (types.Contains("srflx") || types.Contains("prflx")) return "internet";
    return types.Contains("host") ? "host" : "unknown";
  }

  /// The same from a stats report's selected pair (candidateType + address of each side).
  public static string Name(string? localType, string? localAddress, string? remoteType, string? remoteAddress)
  {
    if (localType == "relay" || remoteType == "relay") return "turn";
    if (IsPrivate(localAddress) && IsPrivate(remoteAddress)) return "host";
    if (localType is "srflx" or "prflx" || remoteType is "srflx" or "prflx") return "internet";
    return localType == "host" || remoteType == "host" ? "host" : "unknown";
  }

  private static string? Address(string candidate)
  {
    var words = candidate.Split(' ', StringSplitOptions.RemoveEmptyEntries);
    return words.Length > 5 ? words[4] : null;
  }

  /// Loopback, private IPv4, link-local, shared (100.64/10), or IPv6 ULA / link-local / loopback.
  public static bool IsPrivate(string? address)
  {
    if (address is null) return false;
    var a = address.ToLowerInvariant();
    if (a.Contains(':')) return a == "::1" || a.StartsWith("fe80:", StringComparison.Ordinal) || a.StartsWith("fc", StringComparison.Ordinal) || a.StartsWith("fd", StringComparison.Ordinal);
    var parts = a.Split('.');
    if (parts.Length != 4 || !parts.All(p => int.TryParse(p, out _))) return false;
    var n = parts.Select(int.Parse).ToArray();
    // 100.64/10 is shared address space (carrier NAT, Tailscale): never the public internet.
    return n[0] == 10 || n[0] == 127 || (n[0] == 172 && n[1] is >= 16 and <= 31) || (n[0] == 192 && n[1] == 168) || (n[0] == 169 && n[1] == 254) ||
      (n[0] == 100 && n[1] is >= 64 and <= 127);
  }
}
