using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows;

public sealed class CurrentUserDpapi(AppDataRoot root) : IDataProtector
{
  private readonly byte[] entropy = SHA256.HashData(Encoding.UTF8.GetBytes(root.NamespaceId));
  public byte[] Protect(ReadOnlySpan<byte> plaintext) => Transform(plaintext, protect: true);
  public byte[] Unprotect(ReadOnlySpan<byte> ciphertext) => Transform(ciphertext, protect: false);
  private byte[] Transform(ReadOnlySpan<byte> value, bool protect)
  {
    if (value.Length == 0 || value.Length > 8 * 1024 * 1024 + (protect ? 0 : 4096)) throw new ArgumentException("The protected record is empty or too large.");
    var input = Allocate(value); var extra = Allocate(entropy); var output = new Blob();
    try
    {
      // UI_FORBIDDEN only: never CRYPTPROTECT_LOCAL_MACHINE, which widens access.
      var success = protect ? CryptProtectData(ref input, null, ref extra, IntPtr.Zero, IntPtr.Zero, 1, out output)
        : CryptUnprotectData(ref input, IntPtr.Zero, ref extra, IntPtr.Zero, IntPtr.Zero, 1, out output);
      if (!success || output.Size < 0 || output.Size > 8 * 1024 * 1024 + 4096) throw new CryptographicException("Windows could not open this user's protected record.");
      var result = new byte[output.Size]; Marshal.Copy(output.Data, result, 0, result.Length); return result;
    }
    finally
    {
      Clear(input); Clear(extra); Marshal.FreeHGlobal(input.Data); Marshal.FreeHGlobal(extra.Data);
      if (output.Data != IntPtr.Zero) { Clear(output); LocalFree(output.Data); }
    }
  }
  private static Blob Allocate(ReadOnlySpan<byte> data)
  {
    var bytes = data.ToArray(); var pointer = Marshal.AllocHGlobal(bytes.Length);
    try { Marshal.Copy(bytes, 0, pointer, bytes.Length); return new() { Size = bytes.Length, Data = pointer }; }
    finally { CryptographicOperations.ZeroMemory(bytes); }
  }
  private static void Clear(Blob blob)
  {
    if (blob.Data == IntPtr.Zero || blob.Size <= 0) return;
    var zeros = new byte[Math.Min(blob.Size, 4096)];
    for (var offset = 0; offset < blob.Size; offset += zeros.Length) Marshal.Copy(zeros, 0, IntPtr.Add(blob.Data, offset), Math.Min(zeros.Length, blob.Size - offset));
  }
  [StructLayout(LayoutKind.Sequential)] private struct Blob { public int Size; public IntPtr Data; }
  [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
  private static extern bool CryptProtectData(ref Blob input, string? description, ref Blob entropy, IntPtr reserved, IntPtr prompt, uint flags, out Blob output);
  [DllImport("crypt32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
  private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, ref Blob entropy, IntPtr reserved, IntPtr prompt, uint flags, out Blob output);
  [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr pointer);
}
