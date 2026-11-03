using System.IO.Pipes;
using System.Security.Cryptography;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows;
using TerminalDeck.Platform.Windows.Hoot;

namespace TerminalDeck.App.Services;

// Read the keeper before publishing phone state. The window's Hoot client may
// still hold its last snapshot while its watch reconnects. This read starts no
// worker, AI turn or sign-in, and cannot replay an uncertain message.
public sealed class PhoneRecoveryHost(AppDataRoot root, Func<CancellationToken, ValueTask> refreshSessions)
{
  public async ValueTask<HootState> ReadAsync(CancellationToken ct)
  {
    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
    deadline.CancelAfter(TimeSpan.FromSeconds(5));
    var credential = KeeperCredentials.GetOrCreate(root);
    try
    {
      await refreshSessions(deadline.Token);
      await using var pipe = new NamedPipeClientStream(".", HootPipeServer.Name(root), PipeDirection.InOut, PipeOptions.Asynchronous);
      await pipe.ConnectAsync(5000, deadline.Token);
      await KeeperWire.WriteAsync(pipe, new HootPipeRequest(Convert.ToBase64String(credential), "read"), cancellationToken: deadline.Token);
      var reply = await KeeperWire.ReadAsync<HootPipeReply>(pipe, true, deadline.Token);
      return reply.State ?? throw new IOException("This computer is reconnecting.");
    }
    catch (TimeoutException) { throw new IOException("This computer is reconnecting."); }
    catch (UnauthorizedAccessException) { throw new IOException("This computer is reconnecting."); }
    catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new IOException("This computer is reconnecting."); }
    finally { CryptographicOperations.ZeroMemory(credential); }
  }
}
