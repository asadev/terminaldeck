using System.Formats.Tar;
using System.IO.Compression;

namespace TerminalDeck.Platform.Windows;

public static class SafeStoreArchive
{
  public static async Task ExtractAsync(byte[] bytes, string stage, CancellationToken ct)
  {
    long expanded = 0; var files = 0;
    string Target(string name, long size)
    {
      expanded += size; if (++files > 20000 || expanded > 256 * 1024 * 1024 || size < 0) throw new IOException("The archive exceeds its file or expansion limit.");
      if (name.Length > 512 || name.Contains('\\') || name.Contains(':') || name.Split('/').Any(p => p is "." or "..")) throw new IOException("The archive contains unsafe paths.");
      var path = Path.GetFullPath(Path.Combine(stage, name)); if (!path.StartsWith(stage + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new IOException("The archive contains an outside path.");
      return path;
    }
    if (bytes.Length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b)
    {
      using var gzip = new GZipStream(new MemoryStream(bytes), CompressionMode.Decompress); using var tar = new TarReader(gzip);
      while (await tar.GetNextEntryAsync(false, ct) is { } entry)
      {
        if (entry.EntryType is not (TarEntryType.RegularFile or TarEntryType.V7RegularFile or TarEntryType.Directory)) throw new IOException("Archive links and special files are not allowed.");
        var path = Target(entry.Name, entry.Length); if (entry.EntryType == TarEntryType.Directory) { Directory.CreateDirectory(path); continue; }
        Directory.CreateDirectory(Path.GetDirectoryName(path)!); await using var output = new FileStream(path, FileMode.CreateNew); if (entry.DataStream is { } data) await data.CopyToAsync(output, ct);
      }
      return;
    }
    using var zip = new ZipArchive(new MemoryStream(bytes), ZipArchiveMode.Read);
    foreach (var entry in zip.Entries)
    {
      ct.ThrowIfCancellationRequested(); if (((entry.ExternalAttributes >> 16) & 0xF000) == 0xA000) throw new IOException("Archive links are not allowed.");
      var path = Target(entry.FullName, entry.Length); if (entry.FullName.EndsWith('/')) { Directory.CreateDirectory(path); continue; }
      Directory.CreateDirectory(Path.GetDirectoryName(path)!); await using var output = new FileStream(path, FileMode.CreateNew); await using var data = entry.Open(); await data.CopyToAsync(output, ct);
    }
  }
}
