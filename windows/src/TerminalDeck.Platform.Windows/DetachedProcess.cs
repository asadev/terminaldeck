using System.Runtime.InteropServices;
using System.Text;
using System.Diagnostics;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.Platform.Windows;

public static class DetachedProcess
{
  public static void Start(string executable, IReadOnlyList<string> arguments, string directory)
  {
    var startup = new StartupInfo { Size = Marshal.SizeOf<StartupInfo>() };
    // Break away from a launcher/SSH job. Never inherit its kill-on-close lifetime.
    // Refuse launch if that job forbids breakaway; silently falling back loses terminals.
    if (!CreateProcess(executable, new StringBuilder(WindowsCommandLine.Compose(executable, arguments)),
      IntPtr.Zero, IntPtr.Zero, false, 0x01000000 | 0x00000008, IntPtr.Zero, directory, ref startup, out var process))
    {
      if (Marshal.GetLastWin32Error() != 5 || !IsProcessInJob(GetCurrentProcess(), IntPtr.Zero, out var inJob) || !inJob)
        throw new IOException("Windows could not start an independent session worker.", new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()));
      StartFromDesktop(executable, arguments, directory); return;
    }
    CloseHandle(process.Process); CloseHandle(process.Thread);
  }
  // Test runners and managed launchers can forbid job breakaway. Use the
  // current user's desktop as the explicit lifetime parent in that case. No
  // code runs inside Explorer and no handle or credential is passed to it.
  private static void StartFromDesktop(string executable, IReadOnlyList<string> arguments, string directory)
  {
    using var current = Process.GetCurrentProcess();
    using var identity = WindowsIdentity.GetCurrent();
    foreach (var desktop in Process.GetProcessesByName("explorer"))
    {
      using (desktop)
      {
        if (desktop.SessionId != current.SessionId) continue;
        using var parent = OpenProcess(0x0080 | 0x1000, false, desktop.Id);
        if (parent.IsInvalid || !OpenProcessToken(parent, 0x0008, out var token)) continue;
        using (token) using (var owner = new WindowsIdentity(token.DangerousGetHandle()))
          if (owner.User != identity.User) continue;
        nuint bytes = 0; _ = InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref bytes);
        var list = Marshal.AllocHGlobal(checked((int)bytes)); var value = Marshal.AllocHGlobal(IntPtr.Size); var initialized = false;
        try
        {
          if (!InitializeProcThreadAttributeList(list, 1, 0, ref bytes)) throw new IOException("The desktop launch could not be prepared.");
          initialized = true; Marshal.WriteIntPtr(value, parent.DangerousGetHandle());
          if (!UpdateProcThreadAttribute(list, 0, (IntPtr)0x00020000, value, (nuint)IntPtr.Size, IntPtr.Zero, IntPtr.Zero)) throw new IOException("The desktop launch could not be prepared.");
          var startup = new StartupInfoEx { Startup = new() { Size = Marshal.SizeOf<StartupInfoEx>() }, Attributes = list };
          if (!CreateProcessExtended(executable, new StringBuilder(WindowsCommandLine.Compose(executable, arguments)), IntPtr.Zero, IntPtr.Zero,
            false, 0x00080000 | 0x00000008, IntPtr.Zero, directory, ref startup, out var process))
            throw new IOException("Windows could not start the independent worker.", new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()));
          CloseHandle(process.Process); CloseHandle(process.Thread); return;
        }
        finally { if (initialized) DeleteProcThreadAttributeList(list); Marshal.FreeHGlobal(list); Marshal.FreeHGlobal(value); }
      }
    }
    throw new IOException("An independent worker needs the signed-in Windows desktop.");
  }
  [StructLayout(LayoutKind.Sequential)] private struct StartupInfoEx { public StartupInfo Startup; public IntPtr Attributes; }
  [DllImport("kernel32.dll", SetLastError = true)] private static extern SafeProcessHandle OpenProcess(uint access, bool inherit, int pid);
  [DllImport("advapi32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool OpenProcessToken(SafeProcessHandle process, uint access, out SafeAccessTokenHandle token);
  [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool inJob);
  [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, uint flags, ref nuint size);
  [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attribute, IntPtr value, nuint size, IntPtr previous, IntPtr returned);
  [DllImport("kernel32.dll")] private static extern void DeleteProcThreadAttributeList(IntPtr list);
  [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CreateProcessExtended(string executable, StringBuilder command, IntPtr processSecurity, IntPtr threadSecurity,
    [MarshalAs(UnmanagedType.Bool)] bool inherit, uint flags, IntPtr environment, string directory, ref StartupInfoEx startup, out ProcessInfo information);
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  private struct StartupInfo
  {
    public int Size; public IntPtr Reserved; public IntPtr Desktop; public IntPtr Title;
    public uint X; public uint Y; public uint XSize; public uint YSize; public uint XCount; public uint YCount; public uint Fill; public uint Flags;
    public short ShowWindow; public short ReservedSize; public IntPtr ReservedBytes; public IntPtr Input; public IntPtr Output; public IntPtr Error;
  }
  [StructLayout(LayoutKind.Sequential)] private struct ProcessInfo { public IntPtr Process; public IntPtr Thread; public uint ProcessId; public uint ThreadId; }
  [DllImport("kernel32.dll", EntryPoint = "CreateProcessW", CharSet = CharSet.Unicode, SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CreateProcess(string executable, StringBuilder command, IntPtr processSecurity, IntPtr threadSecurity,
    [MarshalAs(UnmanagedType.Bool)] bool inherit, uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInfo information);
  [DllImport("kernel32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
}
