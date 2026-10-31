using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace TerminalDeck.Platform.Windows;

// A chat has redirected pipes rather than ConPTY, so attach the worker itself
// before it can spawn a CLI. Descendants inherit the job even when they detach
// their console. The sole job handle lives until this exact worker exits.
internal static class ChatWorkerContainment
{
  private static SafeFileHandle? owned;
  public static void AttachCurrentWorker()
  {
    if (owned is not null) return;
    var job = CreateJobObject(IntPtr.Zero, null);
    try
    {
      var limits = new ExtendedLimits { Basic = new() { Flags = 0x00002000 } };
      using var worker = Process.GetCurrentProcess();
      if (job.IsInvalid || !SetInformationJobObject(job, 9, ref limits, Marshal.SizeOf<ExtendedLimits>()) || !AssignProcessToJobObject(job, worker.Handle))
        throw new IOException("Windows could not contain this chat worker safely.");
      // Do not dispose a self-containing job during normal cleanup: closing
      // its last handle terminates the owner too. Windows closes it at exit.
      owned = job;
    }
    catch { job.Dispose(); throw; }
  }
  [StructLayout(LayoutKind.Sequential)] private struct BasicLimits
  { public long ProcessTime; public long JobTime; public uint Flags; public nuint Minimum; public nuint Maximum; public uint Active; public nuint Affinity; public uint Priority; public uint Scheduling; }
  [StructLayout(LayoutKind.Sequential)] private struct IoCounters
  { public ulong ReadOperations; public ulong WriteOperations; public ulong OtherOperations; public ulong ReadBytes; public ulong WriteBytes; public ulong OtherBytes; }
  [StructLayout(LayoutKind.Sequential)] private struct ExtendedLimits
  { public BasicLimits Basic; public IoCounters Io; public nuint ProcessMemory; public nuint JobMemory; public nuint PeakProcess; public nuint PeakJob; }
  [DllImport("kernel32.dll", EntryPoint = "CreateJobObjectW", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateJobObject(IntPtr attributes, string? name);
  [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetInformationJobObject(SafeFileHandle job, int kind, ref ExtendedLimits limits, int size);
  [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
}
