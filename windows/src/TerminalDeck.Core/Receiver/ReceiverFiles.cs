using System.Security.Cryptography;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Receiver;

public sealed class ProtectedReceiverState<T>(IStateStore<byte[]> store, IDataProtector protector) : IStateStore<T>
{
  public T? Load()
  {
    var bytes = store.Load(); if (bytes is null) return default;
    var plain = protector.Unprotect(bytes);
    try { return System.Text.Json.JsonSerializer.Deserialize<T>(plain, ReceiverJson.Options); }
    finally { CryptographicOperations.ZeroMemory(plain); }
  }
  public void Save(T state)
  {
    var plain = System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(state, ReceiverJson.Options);
    try
    {
      if (plain.Length > 7 * 1024 * 1024) throw new IOException("The inbox is full. Dismiss or file older items first.");
      store.Save(protector.Protect(plain));
    }
    finally { CryptographicOperations.ZeroMemory(plain); }
  }
}

// Files are copied before a share operation completes, so temporary source
// handles do not become broken inbox attachments. Intake never executes files.
public sealed class ReceiverFiles(AppDataRoot root)
{
  private readonly string directory = Path.Combine(root.DirectoryPath, "receiver", "files");
  private readonly SemaphoreSlim gate = new(1, 1);
  public async ValueTask<ReceiverFile> ImportAsync(Stream input, string name, string mediaType, CancellationToken ct = default)
  {
    if (string.IsNullOrWhiteSpace(name) || name.Length > 240 || name != Path.GetFileName(name) || name.Contains('\\') || name.Any(char.IsControl)) throw new ArgumentException("Give the file a simple name.");
    await gate.WaitAsync(ct);
    var id = Guid.NewGuid().ToString("N"); var path = Path.Combine(directory, id); long count = 0;
    try
    {
      Directory.CreateDirectory(directory); SafeDirectory();
      var used = new DirectoryInfo(directory).EnumerateFiles().Sum(f => f.Length);
      using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, true);
      using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
      var buffer = new byte[81920];
      while (true)
      {
        var read = await input.ReadAsync(buffer, ct); if (read == 0) break;
        count += read;
        if (count > 20 * 1024 * 1024 || used + count > 256 * 1024 * 1024) throw new IOException("This file exceeds the 20 MB file limit or the 256 MB inbox limit.");
        hash.AppendData(buffer, 0, read);
        await output.WriteAsync(buffer.AsMemory(0, read), ct);
      }
      return new(id, name, mediaType.Length <= 128 ? mediaType : "application/octet-stream", count, Convert.ToHexStringLower(hash.GetHashAndReset()));
    }
    catch { if (File.Exists(path)) File.Delete(path); throw; }
    finally { gate.Release(); }
  }
  public Stream Open(ReceiverFile file)
  {
    if (!Guid.TryParseExact(file.Id, "N", out _)) throw new ArgumentException("Choose a saved attachment.");
    SafeDirectory(); var path = Path.Combine(directory, file.Id);
    if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("Linked attachments cannot be opened.");
    return new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
  }
  public void RemoveUnreferenced(IEnumerable<ReceiverItem> items)
  {
    gate.Wait();
    try
    {
      if (!Directory.Exists(directory)) return; SafeDirectory();
      var kept = items.SelectMany(i => i.Files).Select(f => f.Id).ToHashSet();
      foreach (var path in Directory.EnumerateFiles(directory))
        if (Guid.TryParseExact(Path.GetFileName(path), "N", out _) && !kept.Contains(Path.GetFileName(path))) File.Delete(path);
    }
    finally { gate.Release(); }
  }
  private void SafeDirectory()
  {
    for (var current = new DirectoryInfo(directory); current is not null; current = current.Parent)
      if ((current.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("The inbox file folder cannot be a link.");
  }
}
