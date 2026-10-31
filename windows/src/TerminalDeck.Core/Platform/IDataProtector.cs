namespace TerminalDeck.Core.Platform;

public interface IDataProtector
{
  byte[] Protect(ReadOnlySpan<byte> plaintext);
  byte[] Unprotect(ReadOnlySpan<byte> ciphertext);
}
