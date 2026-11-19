using System.ComponentModel;
using System.Runtime.InteropServices;

namespace TerminalDeck.Core.AiSetup;

/// A file or folder to the Recycle Bin, where the person can take it back (the Mac's Trash). Never a permanent delete:
/// a drive with no Recycle Bin refuses before anything moves, and the shell is told to warn rather than destroy. No
/// window, no question in the ordinary case.
internal static class RecycleBin
{
  public static void Send(string path)
  {
    if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("The Recycle Bin is on Windows only.");
    var full = Path.GetFullPath(path);
    var drive = Path.GetPathRoot(full) ?? throw new IOException("The Recycle Bin could not be found for " + Path.GetFileName(full) + ".");
    var info = new SHQUERYRBINFO { cbSize = Marshal.SizeOf<SHQUERYRBINFO>() };
    if (SHQueryRecycleBinW(drive, ref info) != 0) throw new IOException("This drive has no Recycle Bin; " + Path.GetFileName(full) + " was left in place.");
    Exception? failure = null;
    // The shell's file operation is made for a single-threaded apartment; it gets one of its own.
    var thread = new Thread(() =>
    {
      var operation = new SHFILEOPSTRUCTW
      {
        wFunc = FO_DELETE, pFrom = full + "\0",
        fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI | FOF_WANTNUKEWARNING
      };
      var result = SHFileOperationW(ref operation);
      if (result != 0) failure = new Win32Exception(result, "The Recycle Bin did not take " + Path.GetFileName(full) + ".");
      else if (operation.fAnyOperationsAborted) failure = new IOException(Path.GetFileName(full) + " was left in place.");
    });
    thread.SetApartmentState(ApartmentState.STA);
    thread.Start();
    thread.Join();
    if (failure is not null) throw failure;
    if (File.Exists(full) || Directory.Exists(full)) throw new IOException(Path.GetFileName(full) + " is still in place.");
  }

  private const uint FO_DELETE = 3;
  private const ushort FOF_SILENT = 0x0004, FOF_NOCONFIRMATION = 0x0010, FOF_ALLOWUNDO = 0x0040, FOF_NOERRORUI = 0x0400, FOF_WANTNUKEWARNING = 0x4000;

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  private struct SHFILEOPSTRUCTW
  {
    public IntPtr hwnd;
    public uint wFunc;
    public string pFrom;
    public string? pTo;
    public ushort fFlags;
    [MarshalAs(UnmanagedType.Bool)] public bool fAnyOperationsAborted;
    public IntPtr hNameMappings;
    public string? lpszProgressTitle;
  }
  [StructLayout(LayoutKind.Sequential)]
  private struct SHQUERYRBINFO
  {
    public int cbSize;
    public long i64Size;
    public long i64NumItems;
  }

  [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
  private static extern int SHFileOperationW(ref SHFILEOPSTRUCTW operation);
  [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
  private static extern int SHQueryRecycleBinW(string rootPath, ref SHQUERYRBINFO info);
}
