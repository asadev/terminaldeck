namespace TerminalDeck.Core.Sessions;
public static class TerminalPaste
{
  public static string Paths(IEnumerable<string> paths, bool powerShell)
  {
    var values = paths.ToArray();
    if (values.Length == 0 || values.Any(p => string.IsNullOrWhiteSpace(p) || p.Any(char.IsControl) || p.Contains('"')))
      throw new ArgumentException("Choose files with a valid full path.");
    return string.Join(' ', values.Select(p => powerShell ? "'" + p.Replace("'", "''", StringComparison.Ordinal) + "'" : "\"" + p + "\""));
  }
}
