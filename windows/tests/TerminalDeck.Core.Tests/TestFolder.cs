namespace TerminalDeck.Tests;

// Removing a test's temporary folder after the test started a child process in it (a fake coding AI, a console, the
// keeper or a worker, git). On Windows an ended process lets go of the folder a moment later, so the delete waits for
// that, 2 s at most; a folder that stays locked still fails the test. Linked into the Windows test projects.
internal static class TestFolder
{
  public static void Delete(string path)
  {
    for (var attempt = 0; ; attempt++)
    {
      try { if (Directory.Exists(path)) Directory.Delete(path, recursive: true); return; }
      catch (Exception error) when (attempt < 20 && error is IOException or UnauthorizedAccessException) { Thread.Sleep(100); }
    }
  }
}
