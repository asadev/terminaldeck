using System.Text;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Tests.Sessions;

public sealed class ReplayBufferTests
{
  [Fact] public void AppendAllocationDependsOnNewOutputNotEntireScrollback()
  {
    var buffer = new SessionReplayBuffer(); var chunk = new string('x', 1024);
    buffer.Append(new string('a', SessionKeeper.MaximumReplayBytes));
    var before = GC.GetAllocatedBytesForCurrentThread();
    for (var i = 0; i < 4096; i++) buffer.Append(chunk);
    var allocated = GC.GetAllocatedBytesForCurrentThread() - before;
    Assert.True(allocated < 16 * 1024 * 1024, "Append must not allocate/copy a megabyte for every PTY chunk.");
    Assert.Equal(SessionKeeper.MaximumReplayBytes, buffer.Bytes); Assert.Equal(new string('x', SessionKeeper.MaximumReplayBytes), buffer.Snapshot());
  }
  [Fact] public void ByteLimitPreservesWholeSupplementaryUnicodeAndSnapshotCache()
  {
    var buffer = new SessionReplayBuffer(7); buffer.Append("abcd"); buffer.Append("😀xy");
    Assert.Equal("d😀xy", buffer.Snapshot()); Assert.Equal(7, Encoding.UTF8.GetByteCount(buffer.Snapshot()));
    Assert.Same(buffer.Snapshot(), buffer.Snapshot());
    buffer.Replace("new"); Assert.Equal("new", buffer.Snapshot());
  }
  [Fact] public async Task ASlowViewerCannotQueueHundredsOfMegabytes()
  {
    var buffer = new SessionEventBuffer(); var chunk = new string('x', 32768); var sent = 0;
    while (buffer.TryPublish(new((ulong)++sent, "synthetic", "data", chunk))) { }
    Assert.True(buffer.Closed); Assert.True(sent <= 130);
    var read = 0;
    await Assert.ThrowsAsync<IOException>(async () => { await foreach (var change in buffer.ReadAllAsync()) { Assert.Equal(chunk, change.Text); read++; } });
    Assert.InRange(read, 1, SessionEventBuffer.MaximumQueuedBytes / chunk.Length);
  }
}
