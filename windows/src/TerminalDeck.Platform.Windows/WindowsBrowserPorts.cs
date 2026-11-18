using System.ComponentModel;
using System.Diagnostics;
using System.Net;
using System.Runtime.InteropServices;
using TerminalDeck.Core.Browser;

namespace TerminalDeck.Platform.Windows;

// Read just listener ownership and executable names. Never collect command
// arguments, account files or process environments for this picker.
public static class WindowsBrowserPorts
{
  public static BrowserLocalPort[] Read()
  {
    var listeners = new List<BrowserLocalPort>(); var names = new Dictionary<int, string>();
    foreach (var family in new[] { 2u, 23u })
    {
      var size = 0; var result = GetExtendedTcpTable(0, ref size, false, family, 3, 0);
      if (result is not (0 or 122) || size is < 4 or > 4 * 1024 * 1024) throw new IOException("Local servers could not be checked.");
      var table = Marshal.AllocHGlobal(size);
      try
      {
        if (GetExtendedTcpTable(table, ref size, false, family, 3, 0) != 0) throw new IOException("Local servers could not be checked.");
        var count = Marshal.ReadInt32(table); var rowSize = family == 2 ? 24 : 56;
        if (count < 0 || count > (size - 4) / rowSize) throw new IOException("The listener table changed. Scan again.");
        for (var index = 0; index < count; index++)
        {
          var row = table + 4 + index * rowSize;
          var port = (ushort)IPAddress.NetworkToHostOrder(unchecked((short)Marshal.ReadInt32(row, family == 2 ? 8 : 20)));
          IPAddress address;
          if (family == 2) address = new IPAddress(unchecked((uint)Marshal.ReadInt32(row, 4)));
          else { var bytes = new byte[16]; Marshal.Copy(row, bytes, 0, 16); address = new IPAddress(bytes); }
          if (!(IPAddress.IsLoopback(address) || address.Equals(IPAddress.Any) || address.Equals(IPAddress.IPv6Any))) continue;
          var pid = Marshal.ReadInt32(row, family == 2 ? 20 : 52);
          if (!names.TryGetValue(pid, out var name))
          {
            try { using var process = Process.GetProcessById(pid); name = process.ProcessName; }
            catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or Win32Exception) { name = "unknown"; }
            names[pid] = name;
          }
          listeners.Add(new(port, pid, name, pid == Environment.ProcessId || name.StartsWith("TerminalDeck", StringComparison.OrdinalIgnoreCase) || name.StartsWith("Terminal Deck", StringComparison.OrdinalIgnoreCase)));
        }
      }
      finally { Marshal.FreeHGlobal(table); }
    }
    return BrowserLocalPorts.Select(listeners);
  }
  [DllImport("iphlpapi.dll")] private static extern uint GetExtendedTcpTable(nint table, ref int size, [MarshalAs(UnmanagedType.Bool)] bool order, uint family, uint tableClass, uint reserved);
}
