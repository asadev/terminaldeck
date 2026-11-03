using System.IO.Pipes;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows;

// The server must also use CurrentUserOnly and authenticate the keeper instance.
public sealed class NamedPipeConnector(AppDataRoot root) : IKeeperConnector
{
  public async ValueTask<Stream> ConnectAsync(CancellationToken cancellationToken = default)
  {
    var pipe = new NamedPipeClientStream(".", "terminaldeck-" + root.NamespaceId,
      PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
    try
    {
      await pipe.ConnectAsync(5000, cancellationToken).ConfigureAwait(false);
      return pipe;
    }
    catch
    {
      await pipe.DisposeAsync().ConfigureAwait(false);
      throw;
    }
  }
}
