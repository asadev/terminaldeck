using System.Security.Cryptography;
using System.Text;

namespace TerminalDeck.Core.Remote;

// Deliberately not a record: logs must not accidentally format a displayed code.
public sealed class PairingOffer(string code, DateTimeOffset expiresAt)
{
  public string Code { get; } = code;
  public DateTimeOffset ExpiresAt { get; } = expiresAt;
  public override string ToString() => "<pairing offer>";
}

public sealed class PairingWindow(TimeProvider clock)
{
  private readonly object gate = new();
  private byte[]? codeHash;
  private DateTimeOffset expiresAt;
  private int misses;
  public bool IsOpen { get { lock (gate) return codeHash is not null && clock.GetUtcNow() < expiresAt; } }

  public PairingOffer Create()
  {
    lock (gate)
    {
      var code = RandomNumberGenerator.GetInt32(1_000_000).ToString("D6", System.Globalization.CultureInfo.InvariantCulture);
      codeHash = SHA256.HashData(Encoding.ASCII.GetBytes(code));
      expiresAt = clock.GetUtcNow().AddSeconds(60);
      misses = 0;
      return new PairingOffer(code, expiresAt);
    }
  }

  public bool Consume(string code)
  {
    lock (gate)
    {
      if (!IsOpen || code.Length > 200) return false;
      var digest = SHA256.HashData(Encoding.UTF8.GetBytes(code));
      if (!CryptographicOperations.FixedTimeEquals(digest, codeHash!))
      {
        if (++misses >= 5) Cancel();
        return false;
      }
      Cancel(); // Consume before any asynchronous work or storage.
      return true;
    }
  }

  public bool IsCurrent(string code)
  {
    lock (gate) return IsOpen && code.Length <= 200 && CryptographicOperations.FixedTimeEquals(SHA256.HashData(Encoding.UTF8.GetBytes(code)), codeHash!);
  }

  // A dismissed sheet must not cancel a newer offer created through another door.
  public bool Cancel(string code)
  {
    lock (gate)
    {
      if (codeHash is null || code.Length > 200 || !CryptographicOperations.FixedTimeEquals(SHA256.HashData(Encoding.UTF8.GetBytes(code)), codeHash)) return false;
      Cancel(); return true;
    }
  }

  public void Cancel() { lock (gate) { if (codeHash is not null) CryptographicOperations.ZeroMemory(codeHash); codeHash = null; } }
}
