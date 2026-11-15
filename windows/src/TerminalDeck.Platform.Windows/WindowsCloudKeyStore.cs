using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows;

/// Cloud's protected record on this PC: the sign-in and this PC's private device keys, sealed with DPAPI for the
/// current Windows user (`CurrentUserDpapi`, never the machine scope) and kept in this copy's own data folder
/// (`--user-data-dir`, local, never roaming), as `cloud\account.protected`. Never a plain file, never synced. Nothing
/// is created until the person's own Sign in.
public sealed class WindowsCloudKeyStore(AppDataRoot root) : ICloudSecretStore
{
  private readonly ProtectedCloudSecretStore inner = ProtectedCloudSecretStore.For(root, new CurrentUserDpapi(root));
  public bool Exists => inner.Exists;
  public byte[]? Read() => inner.Read();
  public void Write(ReadOnlySpan<byte> plaintext) => inner.Write(plaintext);
  public void Remove() => inner.Remove();
}

/// The person's default browser, for the website sign-in step only.
public sealed class WindowsCloudBrowser : ICloudBrowser
{
  public Task OpenAsync(Uri url, CancellationToken ct)
  {
    if (url.Scheme != "https") throw new CloudFailure("unsafe_configuration");
    using var _ = System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url.AbsoluteUri) { UseShellExecute = true });
    return Task.CompletedTask;
  }
}
