using System.Security.Cryptography;
using System.Text;
using TerminalDeck.Core;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows;

/// This PC's trusted-device list for one account (`CloudTrustStore`'s slot): a file in this copy's own local data folder,
/// `cloud\trust-<account hash>.protected`, sealed with DPAPI for the current Windows user and carrying an HMAC-SHA256
/// whose 32-byte key lives in Windows Credential Manager (its own entry, made on the first save, which follows the
/// person's own sign-in or press). The file alone cannot be swapped for another one: a list copied from another copy,
/// account or user fails the HMAC or DPAPI and reads as "unreadable", so every other device's changes wait. Nothing
/// deletes it (it is kept at sign-out). Never a plain file, never synced, never reachable from a tool.
public sealed class WindowsCloudTrustStore : ICloudTrustSlot
{
  private const string Magic = "TD-CLOUD-TRUST-1";
  private readonly string path;
  private readonly string accountHash;
  private readonly string keyName;
  private readonly CurrentUserDpapi protector;
  private readonly WindowsCredentialStore credentials;

  public WindowsCloudTrustStore(AppDataRoot root, string issuer, string subject)
  {
    accountHash = CloudBytes.Sha256Hex(Encoding.UTF8.GetBytes(issuer + "\n" + subject))[..32];
    path = Path.Combine(root.DirectoryPath, "cloud", "trust-" + accountHash + ".protected");
    keyName = $"{Brand.Name}/{root.NamespaceId}/cloud-trust/{accountHash}";
    protector = new CurrentUserDpapi(root);
    credentials = new WindowsCredentialStore(root);
  }

  public byte[]? Read()
  {
    if (!File.Exists(path)) return null;
    var file = File.ReadAllBytes(path);
    // A list without its key cannot be checked: unreadable, never "empty".
    var key = credentials.ReadAsync(keyName).AsTask().GetAwaiter().GetResult() ?? throw new CryptographicException("The trusted-device list's check key is missing.");
    try
    {
      if (file.Length <= 32 || key.Length != 32) throw new CryptographicException("The trusted-device list is damaged.");
      var sealedBytes = file.AsSpan(32).ToArray();
      if (!CryptographicOperations.FixedTimeEquals(file.AsSpan(0, 32), Mac(key, sealedBytes))) throw new CryptographicException("The trusted-device list was changed outside this app.");
      return protector.Unprotect(sealedBytes);
    }
    finally { CryptographicOperations.ZeroMemory(key); }
  }

  public void Write(byte[] bytes)
  {
    var key = credentials.ReadAsync(keyName).AsTask().GetAwaiter().GetResult();
    if (key is null)
    {
      // A key is made only when there is no list yet; a list whose key went missing stays unreadable.
      if (File.Exists(path)) throw new CryptographicException("The trusted-device list's check key is missing.");
      key = RandomNumberGenerator.GetBytes(32);
      credentials.WriteAsync(keyName, key).AsTask().GetAwaiter().GetResult();
    }
    try
    {
      var sealedBytes = protector.Protect(bytes);
      byte[] file = [.. Mac(key, sealedBytes), .. sealedBytes];
      Directory.CreateDirectory(Path.GetDirectoryName(path)!);
      var temp = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
      try { File.WriteAllBytes(temp, file); File.Move(temp, path, overwrite: true); }
      finally { if (File.Exists(temp)) File.Delete(temp); }
    }
    finally { CryptographicOperations.ZeroMemory(key); }
  }

  /// Bound to this account's file name, so one account's list cannot stand in for another's.
  private byte[] Mac(byte[] key, byte[] sealedBytes) => HMACSHA256.HashData(key, (byte[])[.. Encoding.UTF8.GetBytes(Magic + "\n" + accountHash + "\n"), .. sealedBytes]);
}
