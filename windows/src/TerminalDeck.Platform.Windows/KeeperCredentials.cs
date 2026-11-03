using System.Security.Cryptography;
using System.Text;
using TerminalDeck.Core;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows;

public static class KeeperCredentials
{
  // The mutex is held only across synchronous vault calls, never across awaits.
  public static byte[] GetOrCreate(AppDataRoot root)
  {
    using var mutex = new Mutex(false, "Local\\td-credential-" + root.NamespaceId);
    try { if (!mutex.WaitOne(TimeSpan.FromSeconds(15))) throw new IOException("The keeper credential is busy."); }
    catch (AbandonedMutexException) { }
    try
    {
      var store = new WindowsCredentialStore(root); var name = $"{Brand.Name}/{root.NamespaceId}/keeper/auth-v2";
      var existing = store.ReadAsync(name).GetAwaiter().GetResult();
      if (existing is { Length: >= 32 }) return existing;
      var created = Encoding.UTF8.GetBytes(Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(32)));
      store.WriteAsync(name, created).GetAwaiter().GetResult(); return created;
    }
    finally { mutex.ReleaseMutex(); }
  }
}
