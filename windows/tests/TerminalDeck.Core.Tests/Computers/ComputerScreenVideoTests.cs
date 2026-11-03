using System.Text.Json;
using TerminalDeck.Core.Computers;

namespace TerminalDeck.Core.Tests.Computers;

// "Other computers" watches a screen as the phones do (contract §6, §11.7).
public sealed class ComputerScreenVideoTests
{
  private static JsonElement Video(int seq, bool key, string data = "AAAAAWU=", int part = 0, int parts = 1, string id = "mac:1") =>
    JsonSerializer.SerializeToElement(new { t = "sims.video", id, seq, w = 16, h = 16, data, key, part, parts, sps = key ? "Zw==" : null, pps = key ? "aA==" : null });

  [Fact]
  public void PartsJoinKeyframeFirstAndOnlyHandedFramesMoveTheLast()
  {
    var video = new ComputerScreenVideo("mac:1");
    // A delta before any keyframe: dropped, acked, a keyframe asked for.
    var early = video.Accept(Video(1, key: false), 0);
    Assert.Null(early.Decode); Assert.Equal(1, early.Ack); Assert.True(early.AskKey);
    // A keyframe in two parts: nothing until both, then one picture for the decoder (with its parameter sets).
    Assert.Null(video.Accept(Video(2, key: true, data: "AAAA", part: 0, parts: 2), 10).Decode);
    var key = video.Accept(Video(2, key: true, data: "AWU=", part: 1, parts: 2), 20);
    Assert.NotNull(key.Decode); Assert.True(key.Decode!.Key); Assert.Equal([0x67], key.Decode.Sps); Assert.Equal(2, key.Ack);
    Assert.Equal([0, 0, 0, 1, 0x65], key.Decode.Avcc);
    // The next delta follows on.
    Assert.NotNull(video.Accept(Video(3, key: false), 30).Decode);
    // A stale frame: acked, dropped.
    var stale = video.Accept(Video(3, key: false), 40);
    Assert.Null(stale.Decode); Assert.Equal(3, stale.Ack);
    // A gap: the delta is dropped, a keyframe asked for at once; while still waiting at most once a second.
    var gap = video.Accept(Video(5, key: false), 300);
    Assert.Null(gap.Decode); Assert.True(gap.AskKey);
    Assert.False(video.Accept(Video(6, key: false), 600).AskKey);
    Assert.True(video.Accept(Video(7, key: false), 1_400).AskKey);
    // A late keyframe (its seq below the dropped deltas) is not stale: the dropped deltas never moved the last.
    Assert.NotNull(video.Accept(Video(4, key: true), 1_500).Decode);
    // Another display's frames are not this viewer's.
    Assert.Null(video.Accept(Video(9, key: true, id: "mac:2"), 1_600).Ack);
  }

  // Security S2 (#27): a host that only ever sends first parts cannot grow this PC's memory.
  [Fact]
  public void AtMostFourUnfinishedPicturesAndStalePartsGo()
  {
    var video = new ComputerScreenVideo("mac:1");
    for (var seq = 10; seq < 30; seq++) video.Accept(Video(seq, key: true, data: "AAAA", part: 0, parts: 2), seq);
    Assert.Equal(ComputerScreenVideo.MostUnfinished, video.Unfinished);
    // The newest still completes; older unfinished ones go with it.
    Assert.NotNull(video.Accept(Video(29, key: true, data: "AWU=", part: 1, parts: 2), 40).Decode);
    Assert.Equal(0, video.Unfinished);
    // A part of a picture at or below the last one handed on is stale: acked, never kept.
    Assert.Equal(20, video.Accept(Video(20, key: false, part: 0, parts: 2), 50).Ack);
    Assert.Equal(0, video.Unfinished);
    // More than 64 parts is refused outright.
    Assert.Throws<TerminalDeck.Core.Remote.ProtocolException>(() => video.Accept(Video(31, key: true, part: 0, parts: 65), 60));
  }
}
