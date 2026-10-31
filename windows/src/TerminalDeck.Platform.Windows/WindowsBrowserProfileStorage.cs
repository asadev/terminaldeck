using System.Security.AccessControl;
using System.Security.Principal;
using TerminalDeck.Core.Browser;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows;

public sealed class WindowsBrowserProfileStorage(AppDataRoot root) : IBrowserProfileStorage
{
  private readonly string directory = Path.Combine(root.DirectoryPath, "browser");
  public string PathFor(BrowserSurfaceOptions options) => options.Isolated
    ? Child("private", options.PrivateStoreId ?? throw new ArgumentException("A private browser store is required."), allowDefault: false)
    : Child("profiles", options.ProfileId, allowDefault: true);
  public ValueTask EnsureProfileAsync(string id, CancellationToken ct) { ct.ThrowIfCancellationRequested(); Ensure(Child("profiles", id, true)); return ValueTask.CompletedTask; }
  public ValueTask CreatePrivateAsync(string id, CancellationToken ct) { ct.ThrowIfCancellationRequested(); Ensure(Child("private", id, false)); return ValueTask.CompletedTask; }
  public ValueTask DeletePrivateAsync(string id, CancellationToken ct) { ct.ThrowIfCancellationRequested(); Delete(Child("private", id, false)); return ValueTask.CompletedTask; }
  public ValueTask DeleteProfileAsync(string id, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested(); if (id == BrowserModel.DefaultProfileId) throw new ArgumentException("The default browser profile cannot be deleted.");
    Delete(Child("profiles", id, false)); return ValueTask.CompletedTask;
  }
  private string Child(string kind, string id, bool allowDefault)
  {
    if (!(allowDefault && id == BrowserModel.DefaultProfileId) && !Guid.TryParseExact(id, "N", out _)) throw new ArgumentException("Choose a browser store belonging to this app.");
    return Path.Combine(directory, kind, id);
  }
  private void Ensure(string path)
  {
    RejectLinks(); Directory.CreateDirectory(path);
    if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("The browser store cannot be a redirected folder.");
    using var identity = WindowsIdentity.GetCurrent();
    var sid = identity.User ?? throw new IOException("Windows could not identify the current user.");
    var security = new DirectorySecurity(); security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
    security.AddAccessRule(new(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
    new DirectoryInfo(path).SetAccessControl(security);
  }
  private void RejectLinks()
  {
    for (DirectoryInfo? item = new(root.DirectoryPath); item is not null; item = item.Parent)
      if (item.Exists && (item.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("The browser data root cannot be a redirected folder.");
    foreach (var path in new[] { directory, Path.Combine(directory, "private"), Path.Combine(directory, "profiles") })
      if (Directory.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0) throw new IOException("The browser store cannot be a redirected folder.");
  }
  private void Delete(string path)
  {
    RejectLinks(); if (!Directory.Exists(path)) return;
    // Refuse all reparse points before recursive deletion, including descendants.
    var pending = new Stack<string>(); pending.Push(path);
    while (pending.TryPop(out var current))
    {
      if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new IOException("The browser store contains a redirected folder.");
      foreach (var entry in Directory.EnumerateFileSystemEntries(current))
      {
        var attributes = File.GetAttributes(entry);
        if ((attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("The browser store contains a redirected file.");
        if ((attributes & FileAttributes.Directory) != 0) pending.Push(entry);
      }
    }
    Directory.Delete(path, recursive: true);
  }
}
