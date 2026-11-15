namespace TerminalDeck.Core.Cloud;

// Lane F: reading and writing one file of a Cloud folder (or of this PC's private copy) safely, the Mac's
// CloudFolderDisk (BackendCloudFolderRules.swift) on NTFS: never through a link (symbolic link, junction or any other
// reparse point), never over bytes that changed since they were read. Paths inside the folder are `/`-separated.

public static class CloudFolderDisk
{
  public enum Kind { Absent, File, Blocked }
  public sealed record Found(Kind Kind, byte[]? Bytes = null)
  {
    public static readonly Found Absent = new(Kind.Absent), Blocked = new(Kind.Blocked);
    public bool IsFile => Kind == Kind.File;
  }
  public enum Parents { Ready, Missing, Unsafe }
  public sealed record Stamp(long Bytes, long Modified);

  public static long Ms(DateTime utc) => (long)Math.Floor((utc.ToUniversalTime() - DateTime.UnixEpoch).TotalMilliseconds);
  public static string Full(string root, string relative) => Path.Combine(root, relative.Replace('/', Path.DirectorySeparatorChar));

  private static FileAttributes? Attributes(string path)
  {
    try { return File.GetAttributes(path); }
    catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException) { return null; }
  }
  private static bool Exists(string path) => File.Exists(path) || Directory.Exists(path);
  /// A real folder (never a link or reparse point, never a file).
  public static bool IsPlainFolder(string path)
  {
    try { return Attributes(path) is { } a && (a & FileAttributes.Directory) != 0 && (a & FileAttributes.ReparsePoint) == 0; }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { return false; }
  }

  /// Every folder on the way from `root` down to `relative`'s file, checked one at a time from the root: each must be a
  /// real folder. `make`: a missing folder is made (one at a time) and checked again.
  public static Parents ParentsOf(string root, string relative, bool make)
  {
    if (CloudBootFilesFormat.Parts(relative) is not { Length: > 0 } parts) return Parents.Unsafe;
    try
    {
      if (!IsPlainFolder(root)) return Parents.Unsafe;
      var at = root;
      foreach (var name in parts[..^1])
      {
        if (name.Length == 0 || name is "." or "..") return Parents.Unsafe;
        at = Path.Combine(at, name);
        if (Attributes(at) is not { } a)
        {
          if (File.Exists(at)) return Parents.Unsafe;
          if (!make) return Parents.Missing;
          Directory.CreateDirectory(at);
          a = Attributes(at) ?? FileAttributes.Normal;
        }
        if ((a & FileAttributes.Directory) == 0 || (a & FileAttributes.ReparsePoint) != 0) return Parents.Unsafe;
      }
      return Parents.Ready;
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return Parents.Unsafe; }
  }

  /// The name on disk differs from `relative` only by capitals (`Plan.md` is there, `plan.md` is asked for). NTFS
  /// takes them as one file; the Cloud folder never does.
  public static bool CaseClash(string root, string relative)
  {
    if (CloudBootFilesFormat.Parts(relative) is not { } parts) return false;
    var at = root;
    foreach (var name in parts)
    {
      string[] names;
      try { names = Directory.EnumerateFileSystemEntries(at).Select(Path.GetFileName).Select(n => n!).ToArray(); }
      catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { return false; }
      if (names.Contains(name, StringComparer.Ordinal)) { at = Path.Combine(at, name); continue; }
      return names.Any(n => string.Equals(n, name, StringComparison.OrdinalIgnoreCase));
    }
    return false;
  }

  /// The path is a folder here, or one of its folders is a file here.
  public static bool FileFolderClash(string root, string relative)
  {
    var full = Full(root, relative);
    if (Directory.Exists(full)) return true;
    if (File.Exists(full)) return false;
    if (CloudBootFilesFormat.Parts(relative) is not { } parts) return false;
    var at = root;
    foreach (var name in parts[..^1])
    {
      at = Path.Combine(at, name);
      if (File.Exists(at)) return true;
      if (!Directory.Exists(at)) return false;
    }
    return false;
  }

  /// Size and time of one file, read without following a link. Null when it is not a plain file.
  public static Stamp? StampOf(string root, string relative)
  {
    try
    {
      var info = new FileInfo(Full(root, relative));
      if (!info.Exists || (info.Attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0) return null;
      return new Stamp(info.Length, Ms(info.LastWriteTimeUtc));
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return null; }
  }

  public static Found Read(string root, string relative)
  {
    var full = Full(root, relative);
    try
    {
      if (Attributes(full) is not { } a)
      {
        if (Exists(full)) return Found.Blocked;
        // Absent only when nothing on the way is a link or a file (a linked folder must never read as "write here").
        return ParentsOf(root, relative, make: false) is Parents.Ready or Parents.Missing ? Found.Absent : Found.Blocked;
      }
      if ((a & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0) return Found.Blocked;
      if (ParentsOf(root, relative, make: false) != Parents.Ready) return Found.Blocked;
      using var stream = new FileStream(full, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
      using var buffer = new MemoryStream();
      stream.CopyTo(buffer);
      return new Found(Kind.File, buffer.ToArray());
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return Found.Blocked; }
  }

  public static long? Modified(string root, string relative)
  {
    try { var info = new FileInfo(Full(root, relative)); return info.Exists ? Ms(info.LastWriteTimeUtc) : null; }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { return null; }
  }
  public static void SetModified(string root, string relative, long at)
  {
    try { File.SetLastWriteTimeUtc(Full(root, relative), DateTime.UnixEpoch.AddMilliseconds(at)); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { }
  }

  /// Writes `bytes` at `relative`: a new file only when none is there (`expecting` null), else only over exactly the
  /// bytes with fingerprint `expecting`. Temporary file beside it, then a move that never replaces an unexpected file.
  public static void Write(string root, string relative, byte[] bytes, string? expecting)
  {
    if (ParentsOf(root, relative, make: true) != Parents.Ready) throw new CloudFailure("unsafe_configuration");
    var target = Full(root, relative);
    var temporary = Path.Combine(Path.GetDirectoryName(target)!, ".td-cloud-" + Guid.NewGuid().ToString("D"));
    try
    {
      using (var file = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
      {
        file.Write(bytes);
        file.Flush(flushToDisk: true);
      }
      var held = Read(root, relative);
      switch (held.Kind)
      {
        case Kind.Absent:
          if (expecting is not null) throw new CloudFailure("version_changed");
          try { File.Move(temporary, target, overwrite: false); }
          catch (IOException) { throw new CloudFailure("version_changed"); }
          break;
        case Kind.File:
          if (expecting is null || CloudMemoryFormat.Hash(held.Bytes!) != expecting) throw new CloudFailure("version_changed");
          File.Move(temporary, target, overwrite: true);
          break;
        default:
          throw new CloudFailure("unsafe_configuration");
      }
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { throw new CloudFailure("unavailable"); }
    finally { try { if (File.Exists(temporary)) File.Delete(temporary); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { } }
  }

  /// Removes the file at `relative` only when it still holds exactly the bytes with fingerprint `expecting`. Empty
  /// folders it leaves behind inside `root` go too (never `root` itself).
  public static void Remove(string root, string relative, string expecting)
  {
    if (ParentsOf(root, relative, make: false) != Parents.Ready) throw new CloudFailure("unsafe_configuration");
    var held = Read(root, relative);
    if (!held.IsFile || CloudMemoryFormat.Hash(held.Bytes!) != expecting) throw new CloudFailure("version_changed");
    var target = Full(root, relative);
    try { File.Delete(target); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { throw new CloudFailure("unavailable"); }
    var top = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
    var folder = Path.GetDirectoryName(Path.GetFullPath(target));
    while (folder is not null && folder.StartsWith(top + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
    {
      try
      {
        if (!IsPlainFolder(folder) || Directory.EnumerateFileSystemEntries(folder).Any()) break;
        Directory.Delete(folder, recursive: false);
      }
      catch (Exception e) when (e is IOException or UnauthorizedAccessException) { break; }
      folder = Path.GetDirectoryName(folder);
    }
  }

  /// Free bytes on the disk that holds `near` (or its nearest existing folder above it).
  public static long? FreeBytes(string near)
  {
    try
    {
      var at = Path.GetFullPath(near);
      while (!Directory.Exists(at) && Path.GetDirectoryName(at) is { } up) at = up;
      return new DriveInfo(Path.GetPathRoot(at)!).AvailableFreeSpace;
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { return null; }
  }
}
