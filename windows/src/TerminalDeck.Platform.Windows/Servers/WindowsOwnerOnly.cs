using System.Security.AccessControl;
using System.Security.Principal;

namespace TerminalDeck.Platform.Windows.Servers;

// Owner-only folder (the Mac's 0700): inherited rules dropped, full control for this Windows user only, inherited by
// every file written inside. Used for the travelled server-key copies (keys travel), never for his own SSH folder.
[System.Runtime.Versioning.SupportedOSPlatform("windows")]
public static class WindowsOwnerOnly
{
  public static void Protect(string folder)
  {
    var user = WindowsIdentity.GetCurrent().User ?? throw new IOException("Windows could not identify this user.");
    var security = new DirectorySecurity();
    security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
    security.SetOwner(user);
    security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl,
      InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
    new DirectoryInfo(folder).SetAccessControl(security);
  }
}
