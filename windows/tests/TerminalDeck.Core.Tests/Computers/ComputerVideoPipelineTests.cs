using System.Collections.Concurrent;
using System.Text.Json;
using TerminalDeck.Core.Computers;

namespace TerminalDeck.Core.Tests.Computers;

// Review #27 item 5: the "Other computers" viewer's decode queue is bounded at 16; a decoder that falls behind drops
// what waits, starts afresh and asks for exactly one keyframe; the watch asks 15 fps.
public sealed class ComputerVideoPipelineTests
{
  private sealed class SlowDecoder(SemaphoreSlim gate, ConcurrentQueue<int> decoded) : IComputerVideoDecoder
  {
    public IReadOnlyList<ComputerVideoPicture> Decode(ComputerVideoFrame frame)
    {
      gate.Wait(TimeSpan.FromSeconds(10));
      decoded.Enqueue(frame.Sequence);
      return [new ComputerVideoPicture(new byte[16 * 16 * 4], 16, 16)];
    }
    public void Dispose() { }
  }

  private static JsonElement Video(int seq, bool key) =>
    JsonSerializer.SerializeToElement(new { t = "sims.video", id = "mac:1", seq, w = 16, h = 16, data = "AAAAAWU=", key, sps = key ? "Zw==" : null, pps = key ? "aA==" : null });

  [Fact]
  public async Task AQueueFilledPast16DropsEverythingRestartsTheDecoderAndAsksForOneKeyframe()
  {
    var gate = new SemaphoreSlim(0);
    var decoded = new ConcurrentQueue<int>();
    var sent = new ConcurrentQueue<JsonElement>();
    var shown = 0;
    var pipeline = new ComputerVideoPipeline("mac:1", () => new SlowDecoder(gate, decoded),
      message => { sent.Enqueue(JsonSerializer.SerializeToElement(message)); return Task.CompletedTask; }, (_, _) => Interlocked.Increment(ref shown), () => 1);
    var running = Task.Run(pipeline.RunAsync);
    // The first keyframe goes into the decoder, which is slow (held by the gate).
    Assert.True(pipeline.Offer(Video(1, key: true), 1));
    for (var i = 0; i < 100 && pipeline.DecoderStarts == 0; i++) await Task.Delay(10);
    await Task.Delay(50);
    // 16 more fit in the queue; the 17th does not: the decoder fell behind.
    for (var seq = 2; seq <= 17; seq++) Assert.True(pipeline.Offer(Video(seq, key: false), 1), "frame " + seq + " queued");
    Assert.False(pipeline.Offer(Video(18, key: false), 1));
    // The decoder finishes the first picture: the loop drops the 16 waiting, starts a new decoder, asks one keyframe.
    gate.Release(100);
    for (var i = 0; i < 200 && !sent.Any(m => m.GetProperty("t").GetString() == "sims.key"); i++) await Task.Delay(10);
    await Task.Delay(200);
    Assert.Equal([1], decoded);
    Assert.Equal(2, pipeline.DecoderStarts);
    Assert.Single(sent, m => m.GetProperty("t").GetString() == "sims.key");
    Assert.Equal(1, shown);
    // It catches up: the next keyframe decodes on the fresh decoder.
    Assert.True(pipeline.Offer(Video(19, key: true), 1));
    for (var i = 0; i < 200 && decoded.Count < 2; i++) await Task.Delay(10);
    Assert.Equal([1, 19], decoded);
    pipeline.Complete();
    await running.WaitAsync(TimeSpan.FromSeconds(5));
  }

  // Reviewer S-C2 nit (4 Nov): a decoder that cannot be made at the catch-up (Windows N without the Media Feature Pack)
  // no longer ends the loop; the next keyframe tries again.
  [Fact]
  public async Task ADecoderThatCannotBeMadeAtTheCatchUpKeepsTheLoopRunning()
  {
    var gate = new SemaphoreSlim(0);
    var decoded = new ConcurrentQueue<int>();
    var sent = new ConcurrentQueue<JsonElement>();
    var made = 0;
    var pipeline = new ComputerVideoPipeline("mac:1",
      () => Interlocked.Increment(ref made) == 2 ? throw new InvalidOperationException("no H.264 decoder") : new SlowDecoder(gate, decoded),
      message => { sent.Enqueue(JsonSerializer.SerializeToElement(message)); return Task.CompletedTask; }, (_, _) => { }, () => 1);
    var running = Task.Run(pipeline.RunAsync);
    Assert.True(pipeline.Offer(Video(1, key: true), 1));
    for (var i = 0; i < 100 && pipeline.DecoderStarts == 0; i++) await Task.Delay(10);
    await Task.Delay(50);
    for (var seq = 2; seq <= 17; seq++) Assert.True(pipeline.Offer(Video(seq, key: false), 1), "frame " + seq + " queued");
    Assert.False(pipeline.Offer(Video(18, key: false), 1));
    gate.Release(100);
    for (var i = 0; i < 200 && !sent.Any(m => m.GetProperty("t").GetString() == "sims.key"); i++) await Task.Delay(10);
    await Task.Delay(200);
    Assert.False(running.IsCompleted, "the loop ended when the decoder could not be made");
    Assert.True(pipeline.Offer(Video(19, key: true), 1));
    for (var i = 0; i < 200 && decoded.Count < 2; i++) await Task.Delay(10);
    Assert.Equal([1, 19], decoded);
    Assert.Equal(3, made);
    pipeline.Complete();
    await running.WaitAsync(TimeSpan.FromSeconds(5));
  }

  [Fact]
  public void TheWatchAsksH264At15Fps()
  {
    var watch = JsonSerializer.SerializeToElement(ComputerVideoPipeline.Watch("mac:1", "w1", cursor: true));
    Assert.Equal("sims.watch", watch.GetProperty("t").GetString());
    Assert.Equal(15, watch.GetProperty("fps").GetInt32());
    Assert.Equal("h264", watch.GetProperty("video")[0].GetString());
  }
}
