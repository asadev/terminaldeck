using System.Security.Cryptography;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Accounts;

public sealed class AccountCredentials(ISecretStore secrets, AppDataRoot root)
{
  public async ValueTask<string> StoreAsync(ReadOnlyMemory<byte> value, CancellationToken cancellationToken = default)
  {
    if (value.Length is 0 or > 2560) throw new ArgumentException("The credential is empty or too large for this store.");
    var reference = Guid.NewGuid().ToString("N");
    await secrets.WriteAsync(Name(reference), value, cancellationToken);
    return reference;
  }
  public ValueTask<byte[]?> ReadAsync(string reference, CancellationToken cancellationToken = default) => secrets.ReadAsync(Name(reference), cancellationToken);
  public ValueTask DeleteAsync(string reference, CancellationToken cancellationToken = default) => secrets.DeleteAsync(Name(reference), cancellationToken);
  private string Name(string reference) => Guid.TryParseExact(reference, "N", out _) ? $"{Brand.Name}/{root.NamespaceId}/accounts/{reference}" : throw new ArgumentException("Choose a stored credential.");
}
