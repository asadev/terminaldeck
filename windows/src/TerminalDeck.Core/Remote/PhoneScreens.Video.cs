using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TerminalDeck.Core.Remote;

/// stream step 2: This PC's screen as H.264 for a phone that asks for it (`sims.watch {video:["h264"]}`).
public interface IScreenVideoHost
{
  /// A capturer + encoder for one watch, or null with the reason (no encoder, the screen cannot be read).
  IScreenVideoSource? Open(string displayId, int maxSide, int fps, bool drawCursor, out string? problem);
}

public interface IScreenVideoSource : IDisposable
{
  /// Which encoder runs ("hardware: …" / "software: …").
  string Encoder { get; }
  /// Captures and encodes one picture; returns every encoded picture that is ready, in order (an encoder may hand one
  /// over late). Null with no problem when the screen has not changed (and neither `key` nor `still` was asked); null
  /// with a problem when it cannot be read. `still`: a sharp keyframe of a screen that stopped moving.
  IReadOnlyList<ScreenVideoFrame>? Next(bool key, bool still, out string? problem);
}

/// One picture: AVCC (4-byte lengths), SPS/PPS on keyframes, the capture time (Unix ms).
public sealed record ScreenVideoFrame(byte[] Avcc, bool Key, byte[]? Sps, byte[]? Pps, int Width, int Height, long CapturedAt, bool Still);

// Contract §6 and §11.7, as the Mac (BackendPhoneDevices.pushVideo / videoMessages): video goes on the link and nowhere
// else. A watch makes no frame until its connection has moved onto its link; then deltas go on td.rt and keyframes
// and the still on td.rel (M5: a keyframe is never given up on a lossy path; a delta td.rt cannot take at once is
// dropped, never sent another way; the next is a keyframe). The two channels keep no order between them, so after a
// keyframe on td.rel the next frame waits until the viewer has it (its ack, KeyGateMs at most). A delta td.rt gave up
// on (no ack in MovingLostAfterMs) brings a keyframe; LossyAfter of them make the watch send everything on td.rel.
// Over TCP every frame goes on td.rel (RelayHostConnection.SendDirect) and nothing waits. When the connection moves,
// every running watch sends a keyframe first.
public sealed partial class PhoneScreens
{
  public const int VideoMostFps = 30;
  public const int VideoMostSide = 2560;
  public const int StillPartChars = 32_000;
  public const int MostParts = 64;
  /// M5: the longest the next frame waits for a keyframe's ack before it goes anyway.
  public const int KeyGateMs = 1_000;
  /// M5: no new frame while more than this waits on the moving frames' channel.
  public const long LinkBacklogBytes = 64_000;
  /// M5: a delta on td.rt not acked after this long was given up on the way (the channel retries 150 ms); this many
  /// within LossyWindowMs make the watch send every frame on td.rel.
  public const int MovingLostAfterMs = 1_000;
  public const int LossyAfter = 3;
  public const int LossyWindowMs = 10_000;

  /// The H.264 path; null = no screen can be shown.
  public IScreenVideoHost? Video { get; set; }
  /// Whether a connection has moved onto its link.
  public Func<string, bool>? OnLink { get; set; }
  /// Whether a connection's link is still coming (nothing is sent for it until it has moved).
  public Func<string, bool>? AwaitsLink { get; set; }
  /// Whether a connection has a live direct link (moved or about to): only such a connection may watch (§11.7).
  public Func<string, bool>? HasLink { get; set; }
  /// A message on a link channel: null not moved, true sent, false dropped.
  public Func<string, byte[], LinkLane, bool?>? Direct { get; set; }
  /// How a connection's link carries video now (M5): null not moved.
  public Func<string, LinkVideo?>? LinkVideo { get; set; }

  /// The connection moved onto its link: its watches send a keyframe first.
  public void LinkMoved(string channel)
  {
    foreach (var watch in watches.Values.Where(w => w.Channel == channel)) Volatile.Write(ref watch.KeyAsked, 1);
  }

  private static bool WantsVideo(JsonElement message) =>
    message.TryGetProperty("video", out var codecs) && codecs.ValueKind == JsonValueKind.Array && codecs.GetArrayLength() <= 4 &&
    codecs.EnumerateArray().Any(c => c.ValueKind == JsonValueKind.String && c.GetString() == "h264");

  private async Task VideoPumpAsync(Watch watch)
  {
    var ct = watch.Stop.Token;
    var source = watch.Source!;
    Trace.WriteLine(DateTimeOffset.Now.ToString("o") + " This PC video for " + watch.Phone + ": " + source.Encoder);
    try
    {
      await send(watch.Channel, Json(State(watch.Device, "live", "")));
      long lastSent = 0, changedAt = Now;
      var stillSent = false; var failures = 0;
      Volatile.Write(ref watch.KeyAsked, 1);
      while (!ct.IsCancellationRequested)
      {
        // Nothing until the connection has moved onto its link (its watch stops when the connection ends).
        if (OnLink?.Invoke(watch.Channel) != true) { await Task.Delay(20, ct); continue; }
        await KeyGateAsync(watch, ct);
        LostMoving(watch);
        // M5: a frame is made only when the channel the moving frames take has room (about 100 ms), never made and
        // left to expire in a queue, which the phone would only see as a gap, if a later frame got through at all.
        if (LinkVideo?.Invoke(watch.Channel) is { } video &&
            (video.ReliableOnly || watch.ReliableVideo ? video.QueuedStill : video.QueuedMoving) > LinkBacklogBytes) { await Task.Delay(10, ct); continue; }
        var wait = lastSent + 1000.0 / watch.Fps - Now;
        if (wait > 1) await Task.Delay(TimeSpan.FromMilliseconds(wait), ct);
        if (!allowed()) { await EndAsync(watch, refusal); return; }
        if (watch.Resend) { watch.Resend = false; Volatile.Write(ref watch.KeyAsked, 1); }
        var key = Interlocked.Exchange(ref watch.KeyAsked, 0) != 0;
        var frames = source.Next(key, still: false, out var problem);
        if (frames is null && problem is not null)
        {
          if (key) Volatile.Write(ref watch.KeyAsked, 1);
          if (++failures >= 3) { await EndAsync(watch, problem); return; }
          await Task.Delay(100, ct);
          continue;
        }
        failures = 0;
        if (frames is null)
        {
          if (key) Volatile.Write(ref watch.KeyAsked, 1);
          if (!stillSent && Now - changedAt >= StillAfterMs)
          {
            // The screen has been still for a moment: one sharp keyframe.
            stillSent = true;
            if (source.Next(key: true, still: true, out _) is { } stills) foreach (var still in stills) SendVideo(watch, still);
            lastSent = Now;
            continue;
          }
          await Task.Delay(Now - changedAt > 2_000 ? 150 : (int)Math.Max(15, 1000.0 / watch.Fps), ct);
          continue;
        }
        changedAt = Now; stillSent = false;
        if (key && !frames.Any(f => f.Key)) Volatile.Write(ref watch.KeyAsked, 1);
        // Contract §6 (M5): deltas on td.rt, keyframes on td.rel (SendVideo). In order; once one is dropped the rest
        // of this run cannot be decoded either.
        foreach (var frame in frames)
          if (!SendVideo(watch, frame)) { Volatile.Write(ref watch.KeyAsked, 1); break; }
        lastSent = Now;
      }
    }
    catch (OperationCanceledException) { }
    catch (Exception ex) when (ex is IOException or InvalidOperationException or System.Runtime.InteropServices.COMException or ArgumentException)
    { await EndAsync(watch, "This PC stopped sending its screen: " + ex.Message); }
    finally { source.Dispose(); }
  }

  // One picture out on the link (delta → td.rt; keyframe, still → td.rel). False = not sent (dropped; never another way).
  private bool SendVideo(Watch watch, ScreenVideoFrame frame)
  {
    int seq;
    lock (watch.Gate) seq = ++watch.Seq;
    var messages = VideoMessages(watch.Device, seq, frame, frame.Still ? StillPartChars : PartChars);
    if (messages.Count == 0) return false;
    if (OnLink?.Invoke(watch.Channel) == true && Direct is { } direct)
    {
      // Deltas on td.rt, keyframes on td.rel; over TCP and for a watch that keeps losing deltas, everything on td.rel.
      var split = LinkVideo?.Invoke(watch.Channel) is { ReliableOnly: false } && !watch.ReliableVideo;
      var reliable = frame.Still || frame.Key || !split;
      var lane = reliable ? LinkLane.Still : LinkLane.Moving;
      foreach (var message in messages)
        if (direct(watch.Channel, Json(message), lane) != true) return false;
      // The next delta goes on td.rt, which keeps no order with td.rel: it waits for this keyframe's ack (KeyGateAsync).
      // A delta on td.rt is watched for its ack (LostMoving). On one channel there is nothing to wait for.
      if (split)
        lock (watch.Gate)
        {
          watch.SentAt[seq] = Now;
          if (reliable) { watch.KeyGate = seq; watch.KeyGateAt = Now; } else watch.MovingSeqs.Add(seq);
        }
      return true;
    }
    return false;
  }

  /// M5: after a keyframe on td.rel, nothing more until the viewer acked it (it can decode nothing newer before it) or
  /// KeyGateMs passed: a delta on td.rt can then never overtake its keyframe.
  private static async Task KeyGateAsync(Watch watch, CancellationToken ct)
  {
    while (true)
    {
      lock (watch.Gate)
      {
        if (watch.KeyGate < 0) return;
        if (!watch.SentAt.ContainsKey(watch.KeyGate) || Now - watch.KeyGateAt > KeyGateMs)
        {
          watch.SentAt.Remove(watch.KeyGate);
          watch.KeyGate = -1;
          return;
        }
      }
      await watch.Room.WaitAsync(TimeSpan.FromMilliseconds(50), ct);
    }
  }

  /// M5: deltas td.rt gave up on never come back acked, and a slow path may let none through at all, so the phone never
  /// sees a gap to ask about. The PC notices instead: a keyframe next (on td.rel, which always arrives), and a path that
  /// keeps losing deltas gets every frame on td.rel.
  private static void LostMoving(Watch watch)
  {
    lock (watch.Gate)
    {
      var lost = 0;
      foreach (var seq in watch.MovingSeqs.ToArray())
      {
        if (!watch.SentAt.TryGetValue(seq, out var at)) { watch.MovingSeqs.Remove(seq); continue; }
        if (Now - at <= MovingLostAfterMs) continue;
        watch.MovingSeqs.Remove(seq); watch.SentAt.Remove(seq); lost++;
      }
      if (lost == 0) return;
      Volatile.Write(ref watch.KeyAsked, 1);
      var now = Now;
      for (var i = 0; i < lost; i++) watch.LostAt.Add(now);
      watch.LostAt.RemoveAll(t => now - t >= LossyWindowMs);
      if (watch.LostAt.Count >= LossyAfter && !watch.ReliableVideo)
      {
        watch.ReliableVideo = true;
        Trace.WriteLine(DateTimeOffset.Now.ToString("o") + " This PC video for " + watch.Phone + " goes the reliable way (" + watch.LostAt.Count + " frames lost on td.rt)");
      }
    }
  }

  /// One picture as `sims.video` messages: whole when it fits, else in parts; none when it would need more than
  /// MostParts parts (no phone could join it).
  public static IReadOnlyList<JsonObject> VideoMessages(string id, int seq, ScreenVideoFrame frame, int partChars = PartChars)
  {
    var text = Convert.ToBase64String(frame.Avcc);
    var parts = Math.Max(1, (text.Length + partChars - 1) / partChars);
    if (parts > MostParts) return [];
    var messages = new List<JsonObject>(parts);
    for (var part = 0; part < parts; part++)
    {
      var message = new JsonObject
      {
        ["t"] = "sims.video", ["id"] = id, ["seq"] = seq, ["w"] = frame.Width, ["h"] = frame.Height,
        ["data"] = text.Substring(part * partChars, Math.Min(partChars, text.Length - part * partChars)), ["ct"] = frame.CapturedAt
      };
      if (parts > 1) { message["part"] = part; message["parts"] = parts; }
      if (frame.Key)
      {
        message["key"] = true;
        if (frame.Sps is { } sps) message["sps"] = Convert.ToBase64String(sps);
        if (frame.Pps is { } pps) message["pps"] = Convert.ToBase64String(pps);
      }
      if (frame.Still) message["still"] = true;
      messages.Add(message);
    }
    return messages;
  }
}
