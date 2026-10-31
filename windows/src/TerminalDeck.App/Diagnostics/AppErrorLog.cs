namespace TerminalDeck.App.Diagnostics;

internal sealed class AppErrorLog(string directory)
{
  private readonly object gate = new();
  internal string PathName => Path.Combine(directory, "logs", "errors.log");
  internal void Write(string source, Exception error)
  {
    // Error reporting must never turn a recoverable UI error into another crash.
    try
    {
      lock (gate)
      {
        Directory.CreateDirectory(Path.GetDirectoryName(PathName)!);
        File.AppendAllText(PathName, $"{DateTimeOffset.UtcNow:O} [{source}] HRESULT=0x{error.HResult:X8}\n{error}\n\n");
      }
    }
    catch (Exception failure) when (failure is IOException or UnauthorizedAccessException or System.Security.SecurityException) { }
  }
}
