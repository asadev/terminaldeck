using TerminalDeck.Core.Platform;

namespace TerminalDeck.Platform.Windows.Servers;

// The session owner must not persist this launch environment for later reuse.
// A reconnect creates a fresh lease and pipe through the same server identity.
public sealed class OpenSshTerminalLease(ProcessLaunch launch, Task handshake, CancellationTokenSource? lifetime = null) : IAsyncDisposable
{
  private int disposed;
  public ProcessLaunch Launch { get; } = launch;
  public Task Handshake { get; } = handshake;
  public async ValueTask DisposeAsync()
  {
    if (lifetime is null || Interlocked.Exchange(ref disposed, 1) != 0) return;
    lifetime.Cancel();
    try { await Handshake; } catch (Exception ex) when (ex is OperationCanceledException or IOException) { }
    lifetime.Dispose();
  }
}
