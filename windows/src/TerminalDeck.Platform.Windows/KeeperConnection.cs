using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows;

public static class KeeperConnection
{
  // App composition uses this same client as tools. Detach never stops sessions.
  public static async ValueTask<KeeperClient> AttachAsync(AppDataRoot root, string keeperExecutable, CancellationToken ct = default)
  {
    WindowsPrivateDirectory.Ensure(Path.Combine(root.DirectoryPath, "keeper"));
    var client = new KeeperClient(new NamedPipeConnector(root), KeeperCredentials.GetOrCreate(root));
    try { await client.HelloAsync(ct); return client; }
    catch (Exception ex) when (ex is IOException or TimeoutException) { }
    await using var startup = new FileStream(Path.Combine(root.DirectoryPath, "keeper", "startup.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
    try { await client.HelloAsync(ct); return client; }
    catch (Exception ex) when (ex is IOException or TimeoutException) { }
    // Never terminate a mismatched/unresponsive supervisor or its workers.
    DetachedProcess.Start(keeperExecutable, ["--user-data-dir", root.DirectoryPath], Path.GetDirectoryName(keeperExecutable)!);
    for (var attempt = 0; attempt < 12; attempt++)
    {
      try { await client.HelloAsync(ct); return client; }
      catch (Exception ex) when (ex is IOException or TimeoutException) { await Task.Delay(100, ct); }
    }
    throw new IOException("The keeper is not ready. Existing terminals were left running.");
  }
}
