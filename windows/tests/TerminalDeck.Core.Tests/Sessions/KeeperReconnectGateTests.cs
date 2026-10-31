using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Tests.Sessions;

public sealed class KeeperReconnectGateTests
{
  [Fact] public async Task SimultaneousPanesShareOneReconnectAndLaterGenerationCanReconnect()
  {
    var gate = new KeeperReconnectGate(); var calls = 0;
    var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
    async Task Connect() { Interlocked.Increment(ref calls); started.TrySetResult(); await release.Task; }
    var original = gate.Generation;
    var first = gate.ReconnectAsync(Connect, original); await started.Task;
    var others = Enumerable.Range(0, 12).Select(_ => gate.ReconnectAsync(Connect, original)).ToArray();
    release.SetResult(); await Task.WhenAll(others.Append(first));
    Assert.Equal(1, calls); Assert.Equal(original + 1, gate.Generation);
    await gate.ReconnectAsync(Connect, gate.Generation); Assert.Equal(2, calls);
  }
  [Fact] public async Task FailedReconnectLeavesGenerationRetryable()
  {
    var gate = new KeeperReconnectGate(); var observed = gate.Generation;
    await Assert.ThrowsAsync<IOException>(() => gate.ReconnectAsync(() => throw new IOException("offline"), observed));
    Assert.Equal(observed, gate.Generation);
    var calls = 0; await gate.ReconnectAsync(() => { calls++; return Task.CompletedTask; }, observed);
    Assert.Equal(1, calls); Assert.Equal(observed + 1, gate.Generation);
  }
  [Fact] public async Task ExplicitRetryAlwaysRuns()
  {
    var gate = new KeeperReconnectGate(); var calls = 0;
    Task Connect() { calls++; return Task.CompletedTask; }
    await gate.ReconnectAsync(Connect); await gate.ReconnectAsync(Connect);
    Assert.Equal(2, calls);
  }
}
