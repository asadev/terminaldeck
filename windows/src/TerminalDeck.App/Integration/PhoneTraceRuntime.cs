using System.Diagnostics;
namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private readonly object phoneTraceGate = new();
  private TextWriterTraceListener? phoneTrace;
  private void EnsurePhoneTrace()
  {
    lock (phoneTraceGate)
    {
      if (phoneTrace is not null) return;
      try
      {
        var logs = Path.Combine(Root.DirectoryPath, "logs"); TerminalDeck.Platform.Windows.WindowsPrivateDirectory.Ensure(logs);
        var file = Path.Combine(logs, "phone.log"); if (File.Exists(file) && new FileInfo(file).Length > 1024 * 1024) File.Move(file, file + ".previous", true);
        var writer = new StreamWriter(new FileStream(file, FileMode.Append, FileAccess.Write, FileShare.ReadWrite)) { AutoFlush = true };
        phoneTrace = new TextWriterTraceListener(writer, "phone:" + Root.NamespaceId); Trace.Listeners.Add(phoneTrace);
      }
      catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
  }
  private void DisposePhoneTrace()
  {
    lock (phoneTraceGate)
    { if (phoneTrace is null) return; Trace.Listeners.Remove(phoneTrace); phoneTrace.Dispose(); phoneTrace = null; }
  }
}
