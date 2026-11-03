using System.Security.Cryptography;

namespace TerminalDeck.Core.Remote;

public sealed partial class DeviceTrust
{
  // The random bridge binding is private to the direct listener. It is not a
  // browser public key and is never offered as a Noise peer.
  internal PairingReceipt EnrollLocalWeb(string name)
  {
    lock (gate)
    {
      var clean = Clean(name, 60);
      if (clean.Length == 0 || devices.Count(d => !d.Revoked) >= 64) throw Refused();
      var secret = RandomNumberGenerator.GetBytes(32); var salt = RandomNumberGenerator.GetBytes(16);
      try
      {
        var id = Encode(RandomNumberGenerator.GetBytes(16));
        var row = new StoredDevice { Id = id, Name = clean, Platform = "web", PublicKey = RandomNumberGenerator.GetBytes(32), LocalWeb = true,
          Salt = salt, CredentialHash = Hash(secret, salt), Approved = true, Access = PhoneAccess.Full, PairedAt = clock.GetUtcNow() };
        var next = Clone(devices.Where(d => !d.Revoked).ToArray()); next.Add(row); Commit(next);
        return new(id, clean, id + "." + Encode(secret));
      }
      finally { CryptographicOperations.ZeroMemory(secret); }
    }
  }

  internal byte[] LocalWebBinding(string credential)
  {
    lock (gate)
    {
      var id = credential.Split('.')[0];
      var row = devices.FirstOrDefault(d => d.Id == id && d.LocalWeb && !d.Revoked && d.Approved) ?? throw Refused();
      // Authentication includes the salted credential hash, current approval and expiry strikes.
      _ = Authenticate(credential, row.PublicKey);
      return row.PublicKey.ToArray();
    }
  }
}
