using System.Text.Json;

namespace TerminalDeck.Core.Storage;

public interface IStateStore<T>
{
  T? Load();
  void Save(T state);
}

// Callers supply an explicit root. No default path, hooks or credentials are opened.
public sealed class JsonStateStore<T>(AppDataRoot root, string name) : IStateStore<T>
{
  private readonly string path = Path.Combine(root.DirectoryPath, "state", SafeName(name) + ".json");
  public async ValueTask<IDisposable> AcquireWriteAsync(CancellationToken ct)
  {
    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    while (true)
    {
      ct.ThrowIfCancellationRequested();
      try { return new FileStream(path + ".lock", FileMode.OpenOrCreate, FileAccess.Write, FileShare.None); }
      catch (IOException) { await Task.Delay(50, ct); }
    }
  }
  public T? Load()
  {
    if (!File.Exists(path)) return default;
    if (new FileInfo(path).Length > 128 * 1024 * 1024) throw new IOException("The saved state is too large to read safely.");
    using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
    return JsonSerializer.Deserialize<T>(input) ?? throw new IOException("The saved state could not be read.");
  }

  public void Save(T state)
  {
    Directory.CreateDirectory(Path.GetDirectoryName(path)!);
    var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
    try
    {
      using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
      {
        JsonSerializer.Serialize(file, state);
        file.Flush(flushToDisk: true);
      }
      File.Move(temporary, path, overwrite: true);
    }
    finally { if (File.Exists(temporary)) File.Delete(temporary); }
  }

  private static string SafeName(string value) => value.Length is > 0 and <= 80 && value.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_')
    ? value : throw new ArgumentException("Choose a simple state file name.");
}
