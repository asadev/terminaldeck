using System.Text;

namespace TerminalDeck.Core.Platform;

// Windows CRT argv quoting at the CreateProcess boundary. No cmd.exe or shell.
public static class WindowsCommandLine
{
  public static string Compose(string executable, IReadOnlyList<string> arguments)
  {
    var result = string.Join(' ', new[] { executable }.Concat(arguments).Select(Quote));
    if (result.Length >= 32767) throw new ArgumentException("The process command is too long.");
    return result;
  }
  public static string Quote(string argument)
  {
    if (argument.Contains('\0')) throw new ArgumentException("A process argument contains an unusable character.");
    var text = new StringBuilder("\""); var slashes = 0;
    foreach (var c in argument)
    {
      if (c == '\\') { slashes++; continue; }
      if (c == '"') text.Append('\\', slashes * 2 + 1).Append('"');
      else text.Append('\\', slashes).Append(c);
      slashes = 0;
    }
    return text.Append('\\', slashes * 2).Append('"').ToString();
  }
  public static string EnvironmentBlock(IReadOnlyDictionary<string, string> values)
  {
    if (values.Keys.Distinct(StringComparer.OrdinalIgnoreCase).Count() != values.Count || values.Any(p => string.IsNullOrWhiteSpace(p.Key) || p.Key.Contains('=') || p.Key.Contains('\0') || p.Value.Contains('\0')))
      throw new ArgumentException("The process environment is unusable.");
    return string.Join('\0', values.OrderBy(p => p.Key, StringComparer.OrdinalIgnoreCase).Select(p => p.Key + "=" + p.Value)) + "\0\0";
  }
}
