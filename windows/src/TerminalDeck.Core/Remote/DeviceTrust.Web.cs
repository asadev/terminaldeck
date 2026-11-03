using System.Security.Cryptography;

namespace TerminalDeck.Core.Remote;

public sealed partial class DeviceTrust
{
  // Only WebLaunchApplication calls this, after consuming the desktop's one-use grant
  // and completing Noise IK. Persist the actual browser key, exactly like a phone.
  internal (PairingReceipt Receipt, bool IsNew) EnrollApprovedWeb(string name, ReadOnlySpan<byte> publicKey)
  {
    lock (gate)
    {
      if (publicKey.Length != 32) throw Refused();
      var clean = Clean(name, 60);
      if (clean.Length == 0) throw new ProtocolException("Choose a browser name.");
      var key = publicKey.ToArray();
      var previous = devices.FirstOrDefault(d => !d.Revoked && CryptographicOperations.FixedTimeEquals(d.PublicKey, key));
      if (previous is null && devices.Count(d => !d.Revoked) >= 64) throw new ProtocolException("This computer has too many paired devices.");
      var secret = RandomNumberGenerator.GetBytes(32);
      var salt = RandomNumberGenerator.GetBytes(16);
      try
      {
        var id = previous?.Id ?? Encode(RandomNumberGenerator.GetBytes(16));
        var row = new StoredDevice { Id = id, Name = clean, Platform = "web", PublicKey = key,
          Salt = salt, CredentialHash = Hash(secret, salt), Approved = true, Access = previous?.Access ?? PhoneAccess.Full,
          PairedAt = previous?.PairedAt ?? clock.GetUtcNow(), LastSeen = previous?.LastSeen };
        var next = Clone(devices.Where(d => !d.Revoked && d.Id != id).ToArray()); next.Add(row); Commit(next);
        return (new PairingReceipt(id, clean, id + "." + Encode(secret)), previous is null);
      }
      finally { CryptographicOperations.ZeroMemory(secret); }
    }
  }
}
