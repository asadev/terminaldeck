using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Runtime.InteropServices;
using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows.Chats;

namespace TerminalDeck.Platform.Windows.Phone;

// No process is started, stopped or inspected for private command arguments.
// TCP ownership is read fresh; ancestry uses a short shared process census and
// verifies creation times on the actual chain before authorizing a port.
public sealed class WindowsPhonePorts(AppDataRoot root, Func<ApprovedDevice, IReadOnlyList<SessionRecord>> sessions, Func<ApprovedDevice, IReadOnlyList<ChatRecord>>? chats = null)
{
  private readonly ConcurrentDictionary<string, PhonePortRoot> identities = new();
  private readonly object gate = new();
  private Dictionary<int, int> parents = [];
  private long snapshotAt;
  private long capturedUtcTicks;
  public bool Allows(ApprovedDevice device, int port)
  {
    if (device.Access == PhoneAccess.Full) return true;
    if (device.Access != PhoneAccess.Work || port is < 1 or > 65535) return false;
    try
    {
      var roots = new List<PhonePortRoot>();
      foreach (var session in sessions(device).Where(s => s.State == SessionState.Running && s.LeaseIdentity is not null))
      {
        if (!identities.TryGetValue(session.CreationKey, out var identity))
        {
          var value = JsonSerializer.Deserialize<WorkerIdentity>(File.ReadAllBytes(WorkerPaths.PathFor(root, session.CreationKey, ".identity.json")));
          if (value is null || value.CreationKey != session.CreationKey || value.SessionId != session.Definition.Id) continue;
          identities[session.CreationKey] = identity = new(value.Pid, value.StartedUtcTicks, value.SessionId);
        }
        roots.Add(identity);
      }
      foreach (var chat in chats?.Invoke(device).Where(c => !c.Ended) ?? [])
      {
        if (!identities.TryGetValue(chat.CreationKey, out var identity))
        {
          var value = JsonSerializer.Deserialize<ChatWorkerIdentity>(File.ReadAllBytes(ChatWorkerPaths.FileFor(root, chat.CreationKey, ".identity.json")));
          if (value is null || value.Key != chat.CreationKey || value.ChatId != chat.Definition.Id) continue;
          identities[chat.CreationKey] = identity = new(value.Pid, value.StartedUtcTicks, value.ChatId);
        }
        roots.Add(identity);
      }
      Dictionary<int, int> ancestry; long captured;
      lock (gate)
      {
        if (snapshotAt == 0 || Environment.TickCount64 - snapshotAt > 2000) { capturedUtcTicks = DateTime.UtcNow.Ticks; parents = Parents(); snapshotAt = Environment.TickCount64; }
        ancestry = parents; captured = capturedUtcTicks;
      }
      PhonePortProcess? ProcessFor(int pid)
      {
        if (!ancestry.TryGetValue(pid, out var parent)) return null;
        try
        {
          using var process = Process.GetProcessById(pid); var started = process.StartTime.ToUniversalTime().Ticks;
          if (process.HasExited || started > captured) return null;
          return new(pid, parent, started);
        }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { return null; }
      }
      return PhonePortOwnership.Allows(device.Access, Owners(port), roots, ProcessFor);
    }
    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or JsonException or System.ComponentModel.Win32Exception) { return false; }
  }
  private static IReadOnlyList<int> Owners(int wanted)
  {
    var owners = new List<int>();
    foreach (var family in new[] { 2u, 23u })
    {
      var size = 0; var result = GetExtendedTcpTable(IntPtr.Zero, ref size, false, family, 3, 0);
      if (result is not (0 or 122) || size is < 4 or > 4 * 1024 * 1024) return [];
      var table = Marshal.AllocHGlobal(size);
      try
      {
        if (GetExtendedTcpTable(table, ref size, false, family, 3, 0) != 0) return [];
        var count = Marshal.ReadInt32(table); var rowSize = family == 2 ? 24 : 56;
        if (count < 0 || count > (size - 4) / rowSize) return [];
        for (var index = 0; index < count; index++)
        {
          var row = table + 4 + index * rowSize; var rawPort = Marshal.ReadInt32(row, family == 2 ? 8 : 20);
          var port = (ushort)IPAddress.NetworkToHostOrder(unchecked((short)rawPort)); if (port != wanted) continue;
          IPAddress address;
          if (family == 2) address = new IPAddress(unchecked((uint)Marshal.ReadInt32(row, 4)));
          else { var bytes = new byte[16]; Marshal.Copy(row, bytes, 0, 16); address = new IPAddress(bytes); }
          if (!(IPAddress.IsLoopback(address) || address.Equals(IPAddress.Any) || address.Equals(IPAddress.IPv6Any))) continue;
          owners.Add(Marshal.ReadInt32(row, family == 2 ? 20 : 52));
        }
      }
      finally { Marshal.FreeHGlobal(table); }
    }
    return owners;
  }
  private static Dictionary<int, int> Parents()
  {
    var rows = new Dictionary<int, int>(); var snapshot = CreateToolhelp32Snapshot(2, 0);
    if (snapshot == IntPtr.Zero || snapshot == new IntPtr(-1)) return rows;
    try
    {
      var entry = new ProcessEntry { Size = (uint)Marshal.SizeOf<ProcessEntry>() };
      if (!Process32FirstW(snapshot, ref entry)) return rows;
      do { rows[(int)entry.ProcessId] = (int)entry.ParentProcessId; entry.Size = (uint)Marshal.SizeOf<ProcessEntry>(); } while (Process32NextW(snapshot, ref entry));
    }
    finally { CloseHandle(snapshot); }
    return rows;
  }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct ProcessEntry
  {
    public uint Size, Usage, ProcessId; public UIntPtr DefaultHeap; public uint ModuleId, Threads, ParentProcessId; public int Priority; public uint Flags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string? Name;
  }
  [DllImport("iphlpapi.dll")] private static extern uint GetExtendedTcpTable(IntPtr table, ref int size, [MarshalAs(UnmanagedType.Bool)] bool order, uint family, uint tableClass, uint reserved);
  [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint processId);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Process32FirstW(IntPtr snapshot, ref ProcessEntry entry);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Process32NextW(IntPtr snapshot, ref ProcessEntry entry);
  [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
}
