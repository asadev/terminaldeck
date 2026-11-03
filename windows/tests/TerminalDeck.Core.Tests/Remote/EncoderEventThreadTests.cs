using System.Runtime.InteropServices;
using TerminalDeck.Platform.Windows.Phone;

namespace TerminalDeck.Core.Tests.Remote;

// M4 (review 25): the GPU encoder's lifetime against its event thread, without a GPU (EncoderEventThread is linked from
// Platform.Windows). The fake encoder's event wait can be held "inside the driver" the way a stalled GPU driver holds
// GetEvent past Dispose's 1 s join; using it after it was let go throws what a separated RCW throws.
public sealed class EncoderEventThreadTests
{
  private const uint HaveOutput = 602;

  private sealed class FakeEncoder(bool park, bool failOnDrain = false)
  {
    public readonly SemaphoreSlim Deliver = new(0);
    public volatile bool Released;
    public int Entered, Drains, UsedAfterRelease, Releases;

    public uint? Wait(EncoderEventThread loop)
    {
      if (Released) Interlocked.Increment(ref UsedAfterRelease);
      Interlocked.Increment(ref Entered);
      if (park) Deliver.Wait(); // inside the driver
      return HaveOutput;
    }

    public void Drain(uint type)
    {
      if (Released) { Interlocked.Increment(ref UsedAfterRelease); throw new InvalidComObjectException("COM object that has been separated from its underlying RCW cannot be used."); }
      if (failOnDrain) throw new InvalidComObjectException("the driver failed");
      Interlocked.Increment(ref Drains);
    }

    public void Release() { Released = true; Interlocked.Increment(ref Releases); }
  }

  private static void Until(Func<bool> condition, string what) => Assert.True(SpinWait.SpinUntil(condition, 5000), what);

  [Fact]
  public async Task ALateEventAfterATimedOutDisposeNeverTouchesTheEncoderAndIsLetGoOnce()
  {
    var fake = new FakeEncoder(park: true);
    var loop = new EncoderEventThread("test-events", fake.Wait, fake.Drain, fake.Release);
    loop.Start();
    fake.Deliver.Release(); // one ordinary event first
    Until(() => Volatile.Read(ref fake.Drains) == 1 && Volatile.Read(ref fake.Entered) == 2, "parked in the driver again after one event");

    // Dispose on another thread while the event thread is parked: the join times out, nothing is let go.
    var releasedNow = await Task.Run(() => { loop.Close(); return loop.Leave(TimeSpan.FromMilliseconds(100)); });
    Assert.False(releasedNow);
    Assert.Equal(0, fake.Releases);
    Assert.False(loop.Ended);

    // The driver delivers one more "have output" late: the thread sees Closed, never drains, and lets go on its way out.
    fake.Deliver.Release();
    Until(() => loop.Ended, "the event thread left");
    Assert.Equal(1, fake.Drains);
    Assert.Equal(0, fake.UsedAfterRelease);
    Assert.Equal(1, fake.Releases);
    Assert.False(loop.Failed);
    Assert.False(loop.Leave(TimeSpan.Zero)); // a second Dispose
    Assert.Equal(1, fake.Releases);
  }

  [Fact]
  public void AFailureInsideTheLoopEndsItQuietlyAndTheOwnerLetsGoOnce()
  {
    var fake = new FakeEncoder(park: true, failOnDrain: true);
    var loop = new EncoderEventThread("test-events", fake.Wait, fake.Drain, fake.Release);
    loop.Start();
    fake.Deliver.Release();
    Until(() => loop.Ended, "the failure ended the event thread");
    Assert.True(loop.Failed); // the encoder counts as stalled: the software one takes over
    Assert.Equal(0, fake.Releases); // the owner still holds it
    Assert.True(loop.Leave(TimeSpan.FromSeconds(1)));
    Assert.Equal(1, fake.Releases);
    Assert.Equal(0, fake.UsedAfterRelease);
  }

  [Fact]
  public async Task DisposingWhileEventsPourInLetsGoExactlyOnceAndNeverBeforeTheLastUse()
  {
    for (var run = 0; run < 200; run++)
    {
      var fake = new FakeEncoder(park: false);
      var loop = new EncoderEventThread("test-events", fake.Wait, fake.Drain, fake.Release);
      loop.Start();
      Thread.SpinWait(run * 50);
      // Two Disposes racing each other and the event thread (the stall fallback's background one and a later one).
      var first = Task.Run(() => loop.Leave(TimeSpan.FromSeconds(1)));
      var second = Task.Run(() => loop.Leave(TimeSpan.FromSeconds(1)));
      await Task.WhenAll(first, second);
      Until(() => loop.Ended, "the event thread left");
      Until(() => fake.Releases == 1, "let go");
      Assert.Equal(0, fake.UsedAfterRelease);
      Assert.Equal(1, fake.Releases);
    }
  }

  [Fact]
  public void TheSoftwareEncoderHasNoEventThreadAndIsLetGoOnce()
  {
    var releases = 0;
    var loop = new EncoderEventThread("unused", null, null, () => releases++);
    loop.Start();
    Assert.True(loop.Ended);
    Assert.True(loop.Leave(TimeSpan.FromSeconds(1)));
    Assert.False(loop.Leave(TimeSpan.FromSeconds(1)));
    Assert.Equal(1, releases);
    Assert.False(loop.Failed);
  }
}
