namespace TerminalDeck.Core.Quality;

internal static class QualityFolder
{
  public static string Require(string folder)
  {
    var directory = new DirectoryInfo(Path.GetFullPath(folder)); if (!directory.Exists) throw new ArgumentException("Choose an existing project folder.");
    if ((directory.Attributes & FileAttributes.ReparsePoint) != 0) throw new IOException("Choose the real project folder rather than a linked folder.");
    return directory.FullName;
  }
}
