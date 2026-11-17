using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace TerminalDeck.App.Services;

internal static class UpdatePackagePath
{
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  private static extern uint GetFinalPathNameByHandle(SafeFileHandle file, StringBuilder path, uint length, uint flags);

  // MSIX can redirect the app's LocalAppData writes. The installer runs outside that
  // view, so it needs the physical file opened by the app, including cached downloads.
  internal static string PhysicalFile(string downloaded)
  {
    using var file = File.OpenHandle(downloaded, FileMode.Open, FileAccess.Read, FileShare.Read);
    var path = new StringBuilder(512);
    var size = GetFinalPathNameByHandle(file, path, (uint)path.Capacity, 0);
    if (size == 0) throw new IOException("Windows could not locate the downloaded update.", new Win32Exception(Marshal.GetLastWin32Error()));
    if (size >= path.Capacity)
    {
      path.Capacity = checked((int)size + 1);
      size = GetFinalPathNameByHandle(file, path, (uint)path.Capacity, 0);
      if (size == 0 || size >= path.Capacity) throw new IOException("Windows could not locate the downloaded update.");
    }
    var physical = path.ToString();
    if (physical.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) return @"\\" + physical[8..];
    return physical.StartsWith(@"\\?\", StringComparison.Ordinal) ? physical[4..] : physical;
  }
}
