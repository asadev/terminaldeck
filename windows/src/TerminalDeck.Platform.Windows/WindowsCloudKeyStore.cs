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

/// Saved passwords on this PC (the Mac keeps them as Keychain items beside the sign-in): the saved-passwords key, its
/// older generations, the newest generation seen and the hand-over book, one DPAPI file each (current user, never the
/// machine scope), in this copy's own data folder `cloud\secrets\<account and device hash>\<name>.protected`. One set
/// per account and device id: a new sign-in gets a new device id and a new set. "Deleting a file cannot reset it" holds
/// only as far as DPAPI holds (the same rule as the trust slots). Never a plain file, never synced, never a tool's.
public sealed class WindowsCloudSecretsSlots : ICloudSecretsSlots
{
  private readonly string folder;
  private readonly CurrentUserDpapi protector;
  public WindowsCloudSecretsSlots(AppDataRoot root, string subject, string deviceId)
  {
    folder = Path.Combine(root.DirectoryPath, "cloud", "secrets", CloudBytes.Sha256Hex(System.Text.Encoding.UTF8.GetBytes(subject + "\n" + deviceId.ToLowerInvariant()))[..32]);
    protector = new CurrentUserDpapi(root);
  }
  private string PathOf(string name) =>
    name.Length is > 0 and <= 40 && name.All(c => char.IsAsciiLetterOrDigit(c) || c == '-') ? Path.Combine(folder, name + ".protected") : throw new CloudFailure("invalid_request");
  public byte[]? Read(string name) => File.Exists(PathOf(name)) ? protector.Unprotect(File.ReadAllBytes(PathOf(name))) : null;
  public void Write(string name, byte[] bytes)
  {
    var path = PathOf(name);
    var sealedBytes = protector.Protect(bytes);
    Directory.CreateDirectory(folder);
    var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
    try
    {
      using (var file = new FileStream(temp, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { file.Write(sealedBytes); file.Flush(flushToDisk: true); }
      File.Move(temp, path, overwrite: true);
    }
    finally { if (File.Exists(temp)) File.Delete(temp); }
  }
  public void Remove(string name) { if (File.Exists(PathOf(name))) File.Delete(PathOf(name)); }
  public void RemoveAll()
  {
    if (!Directory.Exists(folder)) return;
    foreach (var file in Directory.EnumerateFiles(folder, "*.protected")) File.Delete(file);
  }
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
