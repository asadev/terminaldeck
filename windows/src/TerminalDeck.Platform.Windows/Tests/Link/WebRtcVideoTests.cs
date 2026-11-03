using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Tests.Remote;
using TerminalDeck.Platform.Windows.Link;
using TerminalDeck.Platform.Windows.Phone;
using Xunit.Abstractions;

namespace TerminalDeck.Windows.Tests.Link;

// stream step 2 (M3 on Windows): This PC's video on the same link. The host is the real PhoneScreens with the real
// Media Foundation H.264 encoder (the GPU's when Windows offers one) over a scripted 2560×1600 scrolling page (30
// changes a second, like the Mac's step C measurement); the client joins, gap-checks, decodes (Microsoft's H.264
// decoder), acks and asks for keyframes exactly as the contract says (§6). Relay simulated at 132 ms each way.
// Prints `MEASURE win-link-video-<path> …`: moving fps, glass-to-glass (screen change → decoded picture; capture of a
// real monitor is not in it), KB/s, how soon the sharp still follows, decode failures, frames per path.
[Collection("webrtc")]
public sealed class WebRtcVideoTests(ITestOutputHelper output)
{
  private void Measure(string label, string text)
  {
    var line = "MEASURE " + label + " " + text;
    output.WriteLine(line);
    if (Environment.GetEnvironmentVariable("TD_MEASURE_FILE") is { Length: > 0 } file) File.AppendAllText(file, line + Environment.NewLine);
  }

  private static long UnixMs => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

  /// A 2560×1600 page of "text" that scrolls by `offset`; its frames go through the real encoder.
  private sealed class ScriptedScreen : IScreenHost, IScreenVideoHost
  {
    public const int Width = 2560, Height = 1600, Extra = 6000;
    private readonly byte[] page = new byte[Width * (Height + Extra) * 4];
    private int offset, version;
    private long changedAt = UnixMs;
    public string Encoder = "";
    public double CopyMs, ConvertMs, EncodeMs; public int Encodes;

    public ScriptedScreen()
    {
      var random = new Random(7);
      page.AsSpan().Fill(0xFF);
      for (var line = 0; line * 22 + 16 < Height + Extra; line++)
      {
        var x = 40;
        while (x < Width - 200)
        {
          var word = random.Next(3, 12) * 9;
          for (var y = line * 22 + 4; y < line * 22 + 18; y++)
            for (var dx = 0; dx < word; dx++)
            {
              if (random.Next(5) == 0) continue;
              var i = (y * Width + x + dx) * 4;
              page[i] = 40; page[i + 1] = 40; page[i + 2] = 40;
            }
          x += word + 9;
          if (random.Next(9) == 0) break;
        }
      }
    }

    public void Set(int value) { Volatile.Write(ref changedAt, UnixMs); Volatile.Write(ref offset, value % Extra); Interlocked.Increment(ref version); }

    public IScreenVideoSource? Open(string displayId, int maxSide, int fps, bool drawCursor, out string? problem)
    {
      problem = null;
      var encoder = WindowsH264Encoder.Create(Width, Height, fps, WindowsScreenVideo.Bitrate(Width, Height, fps));
      Encoder = encoder.Name;
      return new Source(this, encoder);
    }

    private sealed class Source(ScriptedScreen screen, WindowsH264Encoder first) : IScreenVideoSource
    {
      private WindowsH264Encoder encoder = first;
      private int seen = -1;
      private readonly byte[] bgra = new byte[Width * Height * 4];
      private byte[]? nv12;
      public string Encoder => encoder.Name;
      public IReadOnlyList<ScreenVideoFrame>? Next(bool key, bool still, out string? problem)
      {
        problem = null;
        var version = Volatile.Read(ref screen.version);
        if (version == seen && !key && !still) return null;
        var seenFirst = seen < 0;
        seen = version;
        var at = Volatile.Read(ref screen.changedAt);
        var t0 = Stopwatch.GetTimestamp();
        Buffer.BlockCopy(screen.page, Volatile.Read(ref screen.offset) * Width * 4, bgra, 0, bgra.Length);
        var t1 = Stopwatch.GetTimestamp();
        nv12 = Nv12.FromBgra(bgra, Width, Height, nv12);
        var t2 = Stopwatch.GetTimestamp();
        var moving = encoder.Bitrate;
        if (still) encoder.Bitrate = Math.Min(moving * 4, 24_000_000);
        try
        {
          var encoded = WindowsH264Encoder.Encode(ref encoder, nv12, key || still || seenFirst);
          screen.CopyMs += Stopwatch.GetElapsedTime(t0, t1).TotalMilliseconds; screen.ConvertMs += Stopwatch.GetElapsedTime(t1, t2).TotalMilliseconds;
          screen.EncodeMs += Stopwatch.GetElapsedTime(t2).TotalMilliseconds; screen.Encodes++;
          return encoded.Select(f => new ScreenVideoFrame(f.Avcc, f.Key, f.Sps, f.Pps, Width, Height, at, still)).ToArray();
        }
        finally { if (still) encoder.Bitrate = moving; }
      }
      public void Dispose() => encoder.Dispose();
    }

    public IReadOnlyList<ScreenDisplay> Displays() => [new ScreenDisplay("mac:1", "Scripted", Width, Height, true)];
    public ScreenPicture? Capture(string displayId, int maxSide, int quality, bool drawCursor, ulong? unlessHash, out string? problem) { problem = "pictures are not scripted"; return null; }
    public ScreenStill? Still(string displayId, out string? problem) { problem = "not scripted"; return null; }
    public byte[] EncodePng(ScreenStill still) => throw new NotSupportedException();
    public byte[] EncodeJpeg(ScreenStill still, int maxSide, int quality, out int width, out int height) => throw new NotSupportedException();
    public string? Post(string displayId, ScreenInput input) => null;
    public ScreenPointer? Pointer(string displayId, int knownShape) => null;
    public bool? TextFocus() => null;
  }

  /// The host chain with This PC's screens on it.
  private sealed class ScreensApplication(ScriptedScreen screen) : EchoApplication
  {
    public readonly PhoneScreens Screens = new(screen, () => true, "off", () => [], (_, _, _, _, _) => ValueTask.FromResult(""));
    protected override ValueTask<PhoneApplicationReply>? Extra(string channel, string type, JsonElement message, CancellationToken ct)
    {
      if (!type.StartsWith("sims.", StringComparison.Ordinal)) return null;
      return Handle(channel, type, message, ct);
    }
    private async ValueTask<PhoneApplicationReply> Handle(string channel, string type, JsonElement message, CancellationToken ct)
    {
      var device = Trust.List().Single();
      var rid = message.TryGetProperty("rid", out var r) ? r.GetString() : null;
      var replies = await Screens.HandleAsync(channel, device, type, message, rid, ct);
      return new(replies.Select(m => JsonSerializer.SerializeToUtf8Bytes(m)).ToArray());
    }
    public override async ValueTask DisconnectedAsync(string channel) { await Screens.ClosedAsync(channel); await base.DisconnectedAsync(channel); }
  }

  /// The phone: joins parts, gap rules, decode, ack, keyframe asks (at most 4 a second).
  private sealed class Viewer : IDisposable
  {
    public sealed record Shown(long ChangedAt, long ReadyAt, int Bytes, bool Still);
    private readonly LinkClient client;
    private readonly TestH264Decoder decoder = new();
    private readonly System.Threading.Channels.Channel<(JsonElement Message, bool ViaLink)> queue = System.Threading.Channels.Channel.CreateUnbounded<(JsonElement, bool)>();
    private readonly Dictionary<int, string?[]> joining = [];
    private readonly Queue<Shown> inside = new();
    private int lastSeq = -1;
    private bool needKey = true;
    private long lastAsk;
    public readonly List<Shown> All = [];
    public int DecodeFailures, KeyAsks, OnLink, OnRelay;
    public double DecodeMs; public int Decodes;
    private readonly Task worker;

    public Viewer(LinkClient client)
    {
      this.client = client;
      client.Other = (message, viaLink, _) => { if (message.GetProperty("t").GetString() == "sims.video") queue.Writer.TryWrite((message, viaLink)); };
      worker = Task.Run(WorkAsync);
    }

    private async Task WorkAsync()
    {
      await foreach (var (message, viaLink) in queue.Reader.ReadAllAsync())
      {
        var seq = message.GetProperty("seq").GetInt32();
        var parts = message.TryGetProperty("parts", out var p) ? p.GetInt32() : 1;
        var part = message.TryGetProperty("part", out var q) ? q.GetInt32() : 0;
        if (!joining.TryGetValue(seq, out var pieces)) joining[seq] = pieces = new string?[parts];
        pieces[part] = message.GetProperty("data").GetString();
        if (pieces.Any(x => x is null)) continue;
        joining.Remove(seq);
        foreach (var old in joining.Keys.Where(k => k < seq).ToArray()) joining.Remove(old);
        if (viaLink) OnLink++; else OnRelay++;
        var id = message.GetProperty("id").GetString()!;
        var key = message.TryGetProperty("key", out var k) && k.ValueKind == JsonValueKind.True;
        if (seq <= lastSeq) { await Ack(id, seq); continue; }
        if (!key && (needKey || (lastSeq >= 0 && seq != lastSeq + 1)))
        {
          needKey = true;
          if (Stopwatch.GetElapsedTime(lastAsk).TotalMilliseconds > 250) { lastAsk = Stopwatch.GetTimestamp(); KeyAsks++; await client.SendAsync(JsonSerializer.SerializeToUtf8Bytes(new { t = "sims.key", id })); }
          await Ack(id, seq);
          continue;
        }
        var avcc = Convert.FromBase64String(string.Concat(pieces));
        byte[]? sps = key && message.TryGetProperty("sps", out var s) ? Convert.FromBase64String(s.GetString()!) : null;
        byte[]? pps = key && message.TryGetProperty("pps", out var pp) ? Convert.FromBase64String(pp.GetString()!) : null;
        // Pictures come out in the order they went in (a decoder may hold one back): each output is the oldest waiting.
        inside.Enqueue(new Shown(message.GetProperty("ct").GetInt64(), 0, avcc.Length, message.TryGetProperty("still", out var st) && st.ValueKind == JsonValueKind.True));
        int pictures;
        var decodeStart = Stopwatch.GetTimestamp();
        try { pictures = decoder.Decode(TestH264Decoder.AnnexB(avcc, sps, pps)); DecodeMs += Stopwatch.GetElapsedTime(decodeStart).TotalMilliseconds; Decodes++; }
        catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException or InvalidDataException) { pictures = -1; }
        if (pictures < 0) { DecodeFailures++; needKey = true; inside.Clear(); }
        else
        {
          lastSeq = seq; needKey = false;
          var now = UnixMs;
          for (var i = 0; i < pictures && inside.Count > 0; i++) { var done = inside.Dequeue() with { ReadyAt = now }; lock (All) All.Add(done); }
        }
        await Ack(id, seq);
      }
    }

    private Task Ack(string id, int seq) => client.SendAsync(JsonSerializer.SerializeToUtf8Bytes(new { t = "sims.ack", id, seq }));

    public void Dispose() { queue.Writer.TryComplete(); worker.Wait(5000); decoder.Dispose(); }
  }

  private async Task VideoRunAsync(string label, LinkServers servers, bool measureOnly = false)
  {
    var engine = WebRtcLinkEngine.TryCreate(out var problem);
    Assert.True(engine is not null, problem);
    var screen = new ScriptedScreen();
    var app = new ScreensApplication(screen);
    var setup = new LinkSetup(engine!, (_, _) => ValueTask.FromResult(servers));
    await using var run = await LinkHarness.StartAsync(setup, (given, events) => new Answerer(engine!.ConnectAnswerer(given, events)), askLink: true, application: app, waitMoved: true);
    app.Screens.Bind((channel, bytes) => app.Publisher is { } publish ? publish(channel, bytes, CancellationToken.None) : ValueTask.CompletedTask, _ => app.Trust.List().Single());
    app.Screens.Video = screen;
    app.Screens.OnLink = channel => run.Connection.LinkRoute(channel) is not null;
    app.Screens.AwaitsLink = channel => run.Connection.AwaitsLink(channel);
    app.Screens.HasLink = channel => run.Connection.HasLink(channel);
    app.Screens.Direct = (channel, bytes, lane) => run.Connection.SendDirect(channel, bytes, lane);
    app.Screens.LinkVideo = channel => run.Connection.LinkVideo(channel);
    run.Connection.LinkMoved += app.Screens.LinkMoved;
    using var viewer = new Viewer(run.Client);
    await run.Client.SendAsync("""{"t":"sims.watch","rid":"w1","id":"mac:1","maxWidth":2560,"quality":60,"fps":60,"patches":true,"video":["h264"]}"""u8.ToArray());
    await Task.Delay(1_500);
    var moveStart = UnixMs;
    var encodesAtStart = screen.Encodes;
    var changes = 0;
    while (UnixMs - moveStart < 4_000)
    {
      changes++;
      screen.Set(changes * 24);
      var wait = moveStart + changes * 33.3 - UnixMs;
      if (wait > 0) await Task.Delay(TimeSpan.FromMilliseconds(wait));
    }
    var moveEnd = UnixMs;
    var encodesInMove = screen.Encodes - encodesAtStart;
    await Task.Delay(3_000);
    List<Viewer.Shown> all;
    lock (viewer.All) all = [.. viewer.All];
    var moving = all.Where(f => f.ChangedAt >= moveStart && f.ChangedAt < moveEnd && !f.Still).ToList();
    var seconds = (moveEnd - moveStart) / 1000.0;
    var glass = moving.Select(f => (double)(f.ReadyAt - f.ChangedAt)).ToList();
    var sharp = all.LastOrDefault(f => f.Still && f.ReadyAt > moveEnd);
    Measure(label, $"route={run.Connection.LinkRoute(run.ChannelHex) ?? "relay"} encoder=\"{screen.Encoder}\" moving.fps={moving.Count / seconds:0.0} " +
      $"glass-median={LinkKit.Median(glass):0.0} glass-p90={LinkKit.P90(glass):0.0} kb-per-s={moving.Sum(f => f.Bytes) / 1000.0 / seconds:0} " +
      $"sharp-again-ms={(sharp is null ? double.NaN : sharp.ReadyAt - moveEnd):0} decode-failures={viewer.DecodeFailures} key-asks={viewer.KeyAsks} frames-link={viewer.OnLink} frames-relay={viewer.OnRelay} " +
      $"host-encoded.fps={encodesInMove / seconds:0.0} per-frame copy={screen.CopyMs / Math.Max(1, screen.Encodes):0.0} convert={screen.ConvertMs / Math.Max(1, screen.Encodes):0.0} encode={screen.EncodeMs / Math.Max(1, screen.Encodes):0.0} ms " +
      $"test-decode={viewer.DecodeMs / Math.Max(1, viewer.Decodes):0.0} ms (software decoder on the same PC)");
    await run.Client.SendAsync("""{"t":"sims.unwatch","id":"mac:1"}"""u8.ToArray());
    await Task.Delay(300);
    Assert.Equal(0, viewer.DecodeFailures);
    // TURN from this PC loses packets: with keyframes on td.rt (contract §6) recovery there is the M5 robustness item, so
    // that run is measured, not required.
    if (measureOnly) return;
    Assert.True(moving.Count > 0, "moving frames were shown");
    Assert.True(viewer.OnLink > 0 && viewer.OnRelay == 0, $"video on the link only: {viewer.OnLink} vs relay {viewer.OnRelay}");
  }

  private sealed class Answerer(WebRtcLink link) : ILinkAnswerer
  {
    public Task<string> AnswerAsync(string offer) => link.AnswerAsync(offer, CancellationToken.None);
    public void AddCandidate(string candidate, string? mid, int index) => link.AddCandidate(candidate, mid, index);
    public bool Send(ReadOnlySpan<byte> message, LinkLane lane) => link.Send(message, lane);
    public void Close() => link.Close();
  }

  [Fact]
  public async Task ThisPcsVideoOnTheSameLink()
  {
    // (No relay rung: direct only, video never crosses the relay.)
    await VideoRunAsync("win-link-video-host", new LinkServers([LinkPaths.CloudflareStun], "all"));
    var turnFile = Environment.GetEnvironmentVariable("TD_PEER_TEST_TURN");
    if (!string.IsNullOrEmpty(turnFile) && File.Exists(turnFile) && LinkIceSource.ParseList(File.ReadAllText(turnFile)) is { Count: > 0 } turn)
      await VideoRunAsync("win-link-video-turn", new LinkServers(turn, "relay"), measureOnly: true);
  }

  [Fact]
  public void AnnexBAndAvccRoundTrip()
  {
    byte[] sps = [0x67, 1, 2], pps = [0x68, 3], idr = [0x65, 9, 9, 9], sei = [0x06, 5];
    byte[] annexB = [0, 0, 0, 1, .. sps, 0, 0, 0, 1, .. pps, 0, 0, 1, .. sei, 0, 0, 0, 1, .. idr];
    var units = AnnexB.Units(annexB);
    Assert.Equal(4, units.Count);
    Assert.Equal(idr, units[3]);
    byte[] lengthPrefixed = [0, 0, 0, 4, .. idr];
    byte[] expected = [0, 0, 0, 1, .. sps, 0, 0, 0, 1, .. pps, 0, 0, 0, 1, .. idr];
    Assert.Equal(expected, TestH264Decoder.AnnexB(lengthPrefixed, sps, pps));
    // Video messages: parts of at most 80 000 characters, none past 64 parts, key fields on keyframes.
    var frame = new ScreenVideoFrame(new byte[150_000], true, sps, pps, 2560, 1600, 123, false);
    var messages = PhoneScreens.VideoMessages("mac:1", 7, frame);
    Assert.Equal(3, messages.Count);
    Assert.All(messages, m => Assert.True(((string)m["data"]!).Length <= 80_000));
    Assert.All(messages, m => Assert.True((bool)m["key"]! && m["sps"] is not null && m["pps"] is not null && (int)m["parts"]! == 3));
    Assert.Empty(PhoneScreens.VideoMessages("mac:1", 8, frame with { Avcc = new byte[80_000 * 65] }));
  }
}
