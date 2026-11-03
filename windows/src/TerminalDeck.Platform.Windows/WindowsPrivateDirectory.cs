using System.Security.AccessControl;
using System.Security.Principal;

namespace TerminalDeck.Platform.Windows;

public static class WindowsPrivateDirectory
{
  public static void Ensure(string path)
  {
    for (DirectoryInfo? item = new(path); item is not null; item = item.Parent)
      if (item.Exists && (item.Attributes & FileAttributes.ReparsePoint) != 0)
        throw new IOException("Choose a data folder that is not redirected.");
    Directory.CreateDirectory(path);
    using var identity = WindowsIdentity.GetCurrent();
    var sid = identity.User ?? throw new IOException("Windows could not identify the current user.");
    var security = new DirectorySecurity(); 
    security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
    security.AddAccessRule(new(sid, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
    new DirectoryInfo(path).SetAccessControl(security);
  }
}
