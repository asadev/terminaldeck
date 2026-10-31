using System.Text;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Integration;

// Share activation must find the owner's already selected preview root. A share
// never invents a second root or falls back to an installed app's data.
public static class PreviewShareRoot
{
  private static string Pointer()
  {
    var sid = System.Security.Principal.WindowsIdentity.GetCurrent().User?.Value ?? throw new IOException("Windows could not identify this user.");
    var directory = Path.Combine(@"C:\TD", "share-target", sid); WindowsPrivateDirectory.Ensure(directory);
    return Path.Combine(directory, "root.txt");
  }
  public static void Remember(AppDataRoot root)
  {
    if (!root.DirectoryPath.StartsWith(@"C:\TD\", StringComparison.OrdinalIgnoreCase)) return;
    File.WriteAllText(Pointer(), root.DirectoryPath, new UTF8Encoding(false));
  }
  public static AppDataRoot Resolve()
  {
    var path = Pointer();
    if (!File.Exists(path)) throw new IOException("Open the preview with its scratch folder before sharing.");
    var root = AppDataRoot.Explicit(File.ReadAllText(path));
    if (!root.DirectoryPath.StartsWith(@"C:\TD\", StringComparison.OrdinalIgnoreCase)) throw new IOException("The preview share folder is unavailable.");
    return root;
  }
}
