namespace TerminalDeck.Core.Sessions;

// Every terminal may observe the same broken keeper. One completed reconnect
// satisfies all observers of that generation instead of reconnecting per pane.
public sealed class KeeperReconnectGate
{
  private readonly SemaphoreSlim gate = new(1);
  private long generation;
  public long Generation => Interlocked.Read(ref generation);
  public async Task ReconnectAsync(Func<Task> reconnect, long? observedGeneration = null)
  {
    await gate.WaitAsync();
    try
    {
      if (observedGeneration is { } observed && observed != Generation) return;
      await reconnect();
      Interlocked.Increment(ref generation);
    }
    finally { gate.Release(); }
  }
}
