using System.Runtime.InteropServices;
using System.Security.Cryptography;
using TerminalDeck.Core;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows;

// Windows-only adapter. Core tests use ISecretStore fakes; no Mac keychain access.
public sealed class WindowsCredentialStore(AppDataRoot root) : ISecretStore
{
  private readonly string prefix = $"{Brand.Name}/{root.NamespaceId}/";
  public ValueTask<byte[]?> ReadAsync(string name, CancellationToken cancellationToken = default)
  {
    Validate(name); cancellationToken.ThrowIfCancellationRequested();
    if (!CredRead(name, 1, 0, out var pointer))
    {
      if (Marshal.GetLastWin32Error() == 1168) return ValueTask.FromResult<byte[]?>(null);
      throw Failure();
    }
    try
    {
      var credential = Marshal.PtrToStructure<Credential>(pointer);
      if (credential.BlobSize > 2560) throw Failure();
      var bytes = new byte[credential.BlobSize];
      Marshal.Copy(credential.Blob, bytes, 0, bytes.Length);
      return ValueTask.FromResult<byte[]?>(bytes);
    }
    finally { CredFree(pointer); }
  }
  public ValueTask WriteAsync(string name, ReadOnlyMemory<byte> value, CancellationToken cancellationToken = default)
  {
    Validate(name); cancellationToken.ThrowIfCancellationRequested();
    if (value.Length is 0 or > 2560) throw new ArgumentException("The credential is empty or too large for this store.");
    var bytes = value.ToArray(); var pointer = Marshal.AllocCoTaskMem(bytes.Length);
    try
    {
      Marshal.Copy(bytes, 0, pointer, bytes.Length);
      var credential = new Credential { Type = 1, Target = name, BlobSize = (uint)bytes.Length, Blob = pointer, Persist = 2 };
      if (!CredWrite(ref credential, 0)) throw Failure();
    }
    finally
    {
      CryptographicOperations.ZeroMemory(bytes); Marshal.Copy(bytes, 0, pointer, bytes.Length); Marshal.FreeCoTaskMem(pointer);
    }
    return ValueTask.CompletedTask;
  }
  public ValueTask DeleteAsync(string name, CancellationToken cancellationToken = default)
  {
    Validate(name); cancellationToken.ThrowIfCancellationRequested();
    if (!CredDelete(name, 1, 0) && Marshal.GetLastWin32Error() != 1168) throw Failure();
    return ValueTask.CompletedTask;
  }
  private void Validate(string name)
  {
    if (!name.StartsWith(prefix, StringComparison.Ordinal) || name.Length > 512 || name.Any(char.IsControl))
      throw new ArgumentException("Choose a credential in this app's data folder.");
  }
  private static IOException Failure() => new("Windows could not open the protected credential store.", new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()));

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  private struct Credential
  {
    public uint Flags;
    public uint Type;
    [MarshalAs(UnmanagedType.LPWStr)] public string? Target;
    [MarshalAs(UnmanagedType.LPWStr)] public string? Comment;
    public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
    public uint BlobSize;
    public IntPtr Blob;
    public uint Persist;
    public uint AttributeCount;
    public IntPtr Attributes;
    [MarshalAs(UnmanagedType.LPWStr)] public string? TargetAlias;
    [MarshalAs(UnmanagedType.LPWStr)] public string? UserName;
  }
  [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);
  [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CredWrite(ref Credential credential, uint flags);
  [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CredDelete(string target, uint type, uint flags);
  [DllImport("advapi32.dll")] private static extern void CredFree(IntPtr credential);
}
