using System.Text.Json;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Computers;

/// One H.264 picture ready for the decoder: AVCC (4-byte lengths) with SPS/PPS on keyframes.
public sealed record ComputerVideoFrame(string Display, int Sequence, bool Key, byte[] Avcc, byte[]? Sps, byte[]? Pps, int Width, int Height, bool Still);

/// What the viewer does with one `sims.video` message: decode a picture, ack a sequence, ask for a keyframe.
public sealed record ComputerVideoStep(ComputerVideoFrame? Decode, int? Ack, bool AskKey);

// "Other computers" watches another computer's screen the way the phones do (contract §6, §11.7): `sims.video` parts are
// joined per sequence; a sequence at or below the last one handed to the decoder is stale (acked, dropped); a delta
// that does not follow the last one handed on (or comes before the first keyframe) is dropped and a keyframe is asked
// for, at once at a gap and then at most once a second; only a frame handed to the decoder moves "last handed on"
// (M5), so a keyframe that comes late on td.rel is never read as stale. Every frame handed on or dropped is acked.
public sealed class ComputerScreenVideo(string display)
{
  /// Parts per picture (the phones' SimsWire rule: 64).
  public const int MostParts = PhoneScreens.MostParts;
  public const int MostBytes = 4 * 1024 * 1024;
  /// Unfinished pictures kept at once (Security S2, #27): a host that only ever sends first parts cannot grow memory.
  public const int MostUnfinished = 4;
  /// Characters held in unfinished pictures at once (about 2 full-size keyframes).
  public const long MostHeldChars = 2L * (MostBytes / 3 * 4 + 4);
  private readonly SortedDictionary<int, string?[]> joining = [];
  private long heldChars;
  /// Pictures waiting for their other parts now (for tests).
  public int Unfinished => joining.Count;
  private int last = -1;
  private bool needKey = true;
  private long askedAt = long.MinValue / 2;
  private bool askedSinceGap;

  public void Reset() { joining.Clear(); heldChars = 0; last = -1; needKey = true; askedSinceGap = false; askedAt = long.MinValue / 2; }

  private void Forget(int seq)
  {
    if (!joining.Remove(seq, out var pieces)) return;
    heldChars -= pieces.Sum(p => (long)(p?.Length ?? 0));
  }

  /// The decoder could not take a picture: wait for a keyframe again.
  public void Broken() { needKey = true; askedSinceGap = false; }

  public ComputerVideoStep Accept(JsonElement message, long nowMs)
  {
    if (!message.TryGetProperty("t", out var t) || t.GetString() != "sims.video" || !message.TryGetProperty("id", out var id) || id.GetString() != display)
      return new(null, null, false);
    if (!message.TryGetProperty("seq", out var s) || !s.TryGetInt32(out var seq) || seq < 0) throw new ProtocolException("A screen picture has no usable sequence.");
    var parts = message.TryGetProperty("parts", out var p) && p.TryGetInt32(out var pn) ? pn : 1;
    var part = message.TryGetProperty("part", out var q) && q.TryGetInt32(out var qn) ? qn : 0;
    if (parts is < 1 or > MostParts || part < 0 || part >= parts) throw new ProtocolException("A screen picture has unusable parts.");
    if (!message.TryGetProperty("data", out var d) || d.ValueKind != JsonValueKind.String) throw new ProtocolException("A screen picture has no data.");
    if (seq <= last) { Forget(seq); return new(null, seq, false); }
    if (!joining.TryGetValue(seq, out var pieces) || pieces.Length != parts)
    {
      Forget(seq);
      // At most MostUnfinished pictures wait for parts; the oldest goes first (it is the least likely to be usable).
      while (joining.Count >= MostUnfinished) Forget(joining.Keys.First());
      joining[seq] = pieces = new string?[parts];
    }
    var data = d.GetString()!;
    heldChars += data.Length - (pieces[part]?.Length ?? 0);
    pieces[part] = data;
    // Too much held in unfinished pictures: keep only this one (a keyframe gets its chance), drop the rest.
    while (heldChars > MostHeldChars && joining.Count > 1) Forget(joining.Keys.First(k => k != seq));
    if (heldChars > MostHeldChars) { Forget(seq); return new(null, seq, false); }
    if (pieces.Any(x => x is null)) return new(null, null, false);
    Forget(seq);
    // A newer whole picture: older unfinished ones can never be used.
    foreach (var old in joining.Keys.Where(k => k < seq).ToArray()) Forget(old);
    var key = message.TryGetProperty("key", out var k) && k.ValueKind == JsonValueKind.True;
    if (!key && (needKey || (last >= 0 && seq != last + 1)))
    {
      var gap = !needKey;
      needKey = true;
      var ask = (gap || !askedSinceGap) ? nowMs - askedAt >= 250 : nowMs - askedAt >= 1_000;
      if (ask) { askedAt = nowMs; askedSinceGap = true; }
      return new(null, seq, ask);
    }
    var text = string.Concat(pieces);
    if (text.Length > MostBytes / 3 * 4 + 4) throw new ProtocolException("A screen picture is too large.");
    byte[]? Bytes(string name) => key && message.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? Convert.FromBase64String(v.GetString()!) : null;
    var width = message.TryGetProperty("w", out var w) && w.TryGetInt32(out var wn) ? wn : 0;
    var height = message.TryGetProperty("h", out var h) && h.TryGetInt32(out var hn) ? hn : 0;
    if (width is < 2 or > 8192 || height is < 2 or > 8192) throw new ProtocolException("A screen picture has an unusable size.");
    // Handed to the decoder: it moves "last handed on".
    last = seq; needKey = false; askedSinceGap = false;
    return new(new(display, seq, key, Convert.FromBase64String(text), Bytes("sps"), Bytes("pps"), width, height,
      message.TryGetProperty("still", out var st) && st.ValueKind == JsonValueKind.True), seq, false);
  }
}
