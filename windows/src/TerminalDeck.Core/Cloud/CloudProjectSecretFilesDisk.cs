using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace TerminalDeck.Core.Cloud;

// Every read, write and removal project secret files make in a folder of his, with the Mac's rules (the Mac's
// BackendProjectSecretFilesStore.write / unlinkExactly / walk and CloudFolderDisk) in Windows terms:
// - The project's registered folder is resolved ONCE to its real folder; BELOW it no link, junction or other reparse point
//   is ever followed, on a walk, a read, a write or a removal.
// - A write goes through a temporary file named `.env.td-cloud-<uuid>.local` beside the target (the Code page holds such a
//   name back), made create-new, flushed to disk, then moved in where nothing is (a new file) or over exactly the bytes
//   expected (a replace). A new file is owner-only (the Mac's 0600); a replaced file keeps his own permissions.
// - A removal removes exactly the expected bytes: the file is opened without following a link, compared, checked to be
//   that very file at that very place, and marked for deletion through the same handle.

public static class CloudProjectSecretFilesDisk
{
  public sealed record Found(byte[]? Bytes, string? Blocked)
  {
    public static Found Absent { get; } = new(null, null);
    public bool IsAbsent => Bytes is null && Blocked is null;
  }
  public sealed class Refused(string code) : Exception("The secret file was not written.") { public string Code { get; } = code; }
  public enum Unlinked { Removed, Absent, Kept }
  public sealed record Walked(string Path, byte[] Data, long At, int Size, bool Stays);

  private static string Fold(string name) => name.Normalize(NormalizationForm.FormC).ToUpperInvariant();
  private static bool IsLink(FileSystemInfo info) => (info.Attributes & FileAttributes.ReparsePoint) != 0 || info.LinkTarget is not null;

  /// The real folder behind `path` (links and junctions on the way resolved), or null when it is not a folder.
  public static string? FinalFolder(string path)
  {
    try
    {
      if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path)) return null;
      if (OperatingSystem.IsWindows())
      {
        using var handle = CreateFileW(Path.GetFullPath(path), 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (handle.IsInvalid) return null;
        return FinalPath(handle);
      }
      var full = Path.GetFullPath(path);
      var resolved = new DirectoryInfo(full).ResolveLinkTarget(returnFinalTarget: true)?.FullName ?? full;
      return Directory.Exists(resolved) ? resolved.TrimEnd('/') is { Length: > 0 } t ? t : "/" : null;
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { return null; }
  }
  private static string? FinalPath(SafeFileHandle handle)
  {
    var buffer = new StringBuilder(1024);
    var length = GetFinalPathNameByHandleW(handle, buffer, (uint)buffer.Capacity, 0);
    if (length == 0 || length >= buffer.Capacity) return null;
    var text = buffer.ToString();
    if (text.StartsWith(@"\\?\UNC\", StringComparison.Ordinal)) return @"\\" + text[8..];
    return text.StartsWith(@"\\?\", StringComparison.Ordinal) ? text[4..] : text;
  }

  /// A folder with nothing in it (Explorer's and Finder's own files aside), or one that cannot be read.
  public static bool EmptyFolder(string folder)
  {
    try { return !new DirectoryInfo(folder).EnumerateFileSystemInfos().Any(i => !CloudProjectSecretFilesRules.SystemFiles.Contains(i.Name)); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException or ArgumentException) { return true; }
  }

  private enum Lookup { Exact, Twin, Absent }
  private static Lookup? Find(string folder, string name, out FileSystemInfo? found)
  {
    found = null;
    FileSystemInfo[] listed;
    try { listed = new DirectoryInfo(folder).EnumerateFileSystemInfos().ToArray(); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException) { return null; }
    var wanted = Fold(name);
    var twin = false;
    foreach (var info in listed)
    {
      if (string.Equals(info.Name, name, StringComparison.Ordinal)) { found = info; return Lookup.Exact; }
      if (Fold(info.Name) == wanted) twin = true;
    }
    return twin ? Lookup.Twin : Lookup.Absent;
  }
  /// The folders on the way, opened one by one, never through a link. Null when one is missing and `create` is false.
  private static string? Descend(string root, IEnumerable<string> parts, bool create)
  {
    if (!Directory.Exists(root)) throw new Refused("unreachable");
    var current = root;
    foreach (var name in parts)
    {
      FileSystemInfo? info;
      switch (Find(current, name, out info))
      {
        case null: throw new Refused("unreadable");
        case Lookup.Twin: throw new Refused("twin");
        case Lookup.Absent:
          if (!create) return null;
          try { Directory.CreateDirectory(Path.Combine(current, name)); }
          catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { throw new Refused("unwritable"); }
          if (Find(current, name, out info) != Lookup.Exact || info is not DirectoryInfo) throw new Refused("unwritable");
          break;
      }
      if (IsLink(info!)) throw new Refused("link");
      if (info is not DirectoryInfo) throw new Refused("in-the-way");
      current = info.FullName;
    }
    return current;
  }
  /// The full path is still directly inside `folder` (itself inside the project): checked before anything is written or removed.
  private static string Inside(string folder, string name)
  {
    var target = Path.GetFullPath(Path.Combine(folder, name));
    if (!string.Equals(Path.GetDirectoryName(target), Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder)), StringComparison.OrdinalIgnoreCase)
      || !string.Equals(Path.GetFileName(target), name, StringComparison.Ordinal)) throw new Refused("name");
    return target;
  }
  private static (string[] Folders, string Name) Split(string relative)
  {
    // Fault A: a name Windows cannot hold or that could leave the folder (`d:x`, `CON`, `x.`) is never used at all.
    if (CloudProjectSecretFilesRules.WindowsCannotHold(relative) || CloudBootFilesFormat.Parts(relative) is not { Length: > 0 } parts || parts[^1].Length == 0) throw new Refused("name");
    return (parts[..^1], parts[^1]);
  }

  /// What stands at a path: nothing, a file's bytes, or why it was not read (link, twin, in-the-way, too-large, ...).
  public static Found Read(string root, string relative, int cap = CloudBootFilesFormat.MaximumFileBytes)
  {
    try
    {
      var (folders, name) = Split(relative);
      var folder = Descend(root, folders, create: false);
      if (folder is null) return Found.Absent;
      FileSystemInfo? info;
      switch (Find(folder, name, out info))
      {
        case null: return new(null, "unreadable");
        case Lookup.Absent: return Found.Absent;
        case Lookup.Twin: return new(null, "twin");
      }
      if (IsLink(info!)) return new(null, "link");
      if (info is not FileInfo file) return new(null, "in-the-way");
      if (file.Length > cap) return new(null, "too-large");
      var bytes = File.ReadAllBytes(file.FullName);
      return bytes.Length <= cap ? new(bytes, null) : new(null, "too-large");
    }
    catch (Refused stop) { return new(null, stop.Code); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return new(null, "unreadable"); }
  }
  public static bool Exists(string root, string relative)
  {
    var found = Read(root, relative);
    return found.Bytes is not null || found.Blocked is "too-large";
  }

  /// Writes one secret file (the Mac's `write`). `expecting` null: only where nothing is. Else: only over exactly those
  /// bytes. Throws Refused("changed") when what is there is not what was expected.
  public static void Write(string root, string relative, byte[] bytes, byte[]? expecting, long at)
  {
    var (folders, name) = Split(relative);
    var folder = Descend(root, folders, create: true)!;
    var target = Inside(folder, name);
    if (!target.StartsWith(Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new Refused("name");
    var temporary = Path.Combine(folder, CloudProjectSecretFilesRules.TemporaryName());
    try
    {
      try
      {
        using var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        stream.Write(bytes);
        stream.Flush(flushToDisk: true);
      }
      catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { throw new Refused("unwritable"); }
      FileSystemInfo? info;
      switch (Find(folder, name, out info))
      {
        case null: throw new Refused("unreadable");
        case Lookup.Twin: throw new Refused("twin");
        case Lookup.Absent: if (expecting is not null) throw new Refused("changed"); break;
        case Lookup.Exact:
          if (expecting is null || IsLink(info!) || info is not FileInfo) throw new Refused("changed");
          byte[] held;
          try { held = File.ReadAllBytes(target); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { throw new Refused("changed"); }
          if (!held.AsSpan().SequenceEqual(expecting)) throw new Refused("changed");
          break;
      }
      // F1: the sender's permission is never believed. New: owner-only. Replaced: his own permissions stay.
      if (expecting is null) OwnerOnly(temporary); else KeepPermissions(target, temporary);
      try { File.SetLastWriteTimeUtc(temporary, DateTimeOffset.FromUnixTimeMilliseconds(Math.Max(0, at)).UtcDateTime); }
      catch (Exception e) when (e is IOException or UnauthorizedAccessException or ArgumentException) { }
      try { File.Move(temporary, target, overwrite: expecting is not null); }
      catch (Exception e) when (e is IOException or UnauthorizedAccessException) { throw new Refused(expecting is null ? "changed" : "unwritable"); }
    }
    finally
    {
      try { if (File.Exists(temporary)) File.Delete(temporary); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
  }
  private static void OwnerOnly(string file)
  {
    if (OperatingSystem.IsWindows())
    {
      using var identity = WindowsIdentity.GetCurrent();
      var sid = identity.User ?? throw new Refused("unwritable");
      var security = new FileSecurity();
      security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
      security.AddAccessRule(new FileSystemAccessRule(sid, FileSystemRights.FullControl, AccessControlType.Allow));
      new FileInfo(file).SetAccessControl(security);
    }
    else File.SetUnixFileMode(file, UnixFileMode.UserRead | UnixFileMode.UserWrite);
  }
  private static void KeepPermissions(string from, string to)
  {
    try
    {
      if (OperatingSystem.IsWindows()) new FileInfo(to).SetAccessControl(new FileInfo(from).GetAccessControl(AccessControlSections.Access));
      else File.SetUnixFileMode(to, File.GetUnixFileMode(from));
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidOperationException) { OwnerOnly(to); }
  }

  /// Removes exactly `expected` at `relative` (decision 12): no link followed on the way, the file opened without
  /// following a link, its bytes compared, its real place checked, and deleted through the very handle that was read.
  public static Unlinked UnlinkExactly(string root, string relative, byte[] expected)
  {
    string target;
    try
    {
      var (folders, name) = Split(relative);
      if (name is "." or "..") return Unlinked.Kept;
      var folder = Descend(root, folders, create: false);
      if (folder is null) return Unlinked.Absent;
      FileSystemInfo? info;
      switch (Find(folder, name, out info))
      {
        case Lookup.Absent: return Unlinked.Absent;
        case Lookup.Exact: break;
        default: return Unlinked.Kept;
      }
      if (IsLink(info!) || info is not FileInfo) return Unlinked.Kept;
      target = info.FullName;
      if (!string.Equals(target, Inside(folder, name), StringComparison.OrdinalIgnoreCase)) return Unlinked.Kept;
    }
    catch (Refused) { return Unlinked.Kept; }
    if (!OperatingSystem.IsWindows())
    {
      try
      {
        if (File.ReadAllBytes(target) is not { } held || !held.AsSpan().SequenceEqual(expected)) return Unlinked.Kept;
        File.Delete(target); return Unlinked.Removed;
      }
      catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return Unlinked.Kept; }
    }
    // GENERIC_READ | DELETE, shared for reading only (nobody may change, rename or remove it meanwhile), the name itself
    // opened (FILE_FLAG_OPEN_REPARSE_POINT): a link put in its place is never followed.
    using var handle = CreateFileW(target, 0x80000000 | 0x00010000, 1, IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
    if (handle.IsInvalid) return Marshal.GetLastWin32Error() is 2 or 3 ? Unlinked.Absent : Unlinked.Kept;
    try
    {
      var attributes = File.GetAttributes(handle);
      if ((attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0) return Unlinked.Kept;
      var length = RandomAccess.GetLength(handle);
      if (length != expected.Length || length > CloudProjectSecretFilesRules.FileBytes) return Unlinked.Kept;
      var held = new byte[length];
      var read = 0;
      while (read < held.Length) { var n = RandomAccess.Read(handle, held.AsSpan(read), read); if (n <= 0) return Unlinked.Kept; read += n; }
      if (!held.AsSpan().SequenceEqual(expected)) return Unlinked.Kept;
      // The handle's real place must be the place checked (no folder on the way was swapped for a junction meanwhile).
      if (FinalPath(handle) is not { } real || !string.Equals(real, target, StringComparison.OrdinalIgnoreCase)) return Unlinked.Kept;
      byte delete = 1;
      if (!SetFileInformationByHandle(handle, 4, ref delete, 1)) throw new Win32Exception(Marshal.GetLastWin32Error());
      return Unlinked.Removed;
    }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return Unlinked.Kept; }
  }

  /// The secret files of one (real) project folder: no link followed, hidden and package folders skipped, as deep as a
  /// path may travel and 20,000 entries at most. Bytes are read only for files whose NAME is a candidate, and only up to
  /// the cap + 1. A temporary file a crash left behind (made over two minutes ago) is removed on the way.
  public static IReadOnlyList<Walked> Walk(string root, long now)
  {
    var found = new List<Walked>();
    if (!Directory.Exists(root)) return found;
    var seen = 0;
    var stack = new Stack<(string Folder, string Prefix, int Level)>();
    stack.Push((root, "", 0));
    while (stack.Count > 0)
    {
      var (folder, prefix, level) = stack.Pop();
      FileSystemInfo[] entries;
      try { entries = new DirectoryInfo(folder).EnumerateFileSystemInfos().OrderBy(i => i.Name, StringComparer.Ordinal).ToArray(); }
      catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Security.SecurityException) { continue; }
      foreach (var entry in entries)
      {
        if (++seen > CloudProjectSecretFilesRules.WalkEntries) return found.OrderBy(f => f.Path, StringComparer.Ordinal).ToArray();
        var relative = prefix + entry.Name;
        if (IsLink(entry)) continue;
        if (entry is DirectoryInfo)
        {
          // A file at most Depth + 1 names deep travels, so folders are opened down to Depth levels.
          if (entry.Name.StartsWith('.') || CloudProjectSecretFilesRules.RebuildableFolders.Contains(entry.Name.ToLowerInvariant()) || level + 1 > CloudProjectSecretFilesRules.Depth) continue;
          stack.Push((entry.FullName, relative + "/", level + 1));
          continue;
        }
        if (entry is not FileInfo file) continue;
        if (CloudProjectSecretFilesRules.IsTemporary(entry.Name))
        {
          // R4: our write sets the sender's date as the last-write date, so a leftover's age is when it was MADE.
          var made = new DateTimeOffset(file.CreationTimeUtc).ToUnixTimeMilliseconds();
          if (now - made > CloudProjectSecretFilesRules.StaleTemporaryMs) try { file.Delete(); } catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
          continue;
        }
        var byName = CloudProjectSecretFilesRules.Judge(relative, null);
        if (byName == CloudProjectSecretFilesRules.Verdict.Never) continue;
        var at = new DateTimeOffset(file.LastWriteTimeUtc).ToUnixTimeMilliseconds();
        var size = (int)Math.Min(int.MaxValue, file.Length);
        if (byName == CloudProjectSecretFilesRules.Verdict.StaysHere) { found.Add(new(relative, [], at, size, true)); continue; }
        byte[] bytes;
        try
        {
          using var stream = new FileStream(file.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
          var buffer = new byte[CloudProjectSecretFilesRules.FileBytes + 1];
          var read = 0;
          while (read < buffer.Length) { var n = stream.Read(buffer, read, buffer.Length - read); if (n <= 0) break; read += n; }
          bytes = buffer[..read];
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { continue; }
        // An empty file: nothing to carry.
        if (bytes.Length == 0) continue;
        switch (CloudProjectSecretFilesRules.Judge(relative, bytes))
        {
          case CloudProjectSecretFilesRules.Verdict.StaysHere: found.Add(new(relative, [], at, size, true)); break;
          case CloudProjectSecretFilesRules.Verdict.Travels: found.Add(new(relative, bytes, at, Math.Max(size, bytes.Length), false)); break;
        }
      }
    }
    return found.OrderBy(f => f.Path, StringComparer.Ordinal).ToArray();
  }

  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern uint GetFinalPathNameByHandleW(SafeFileHandle handle, StringBuilder path, uint length, uint flags);
  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int infoClass, ref byte info, uint size);
}
