using System.Globalization;
namespace TerminalDeck.App.Shell;

public static class WorkspaceText
{
  public static string AccountIdentity(string? provider, bool signedIn, string? email, string? name) =>
    string.Equals(provider, "shell", StringComparison.OrdinalIgnoreCase) ? "" :
    !string.IsNullOrWhiteSpace(name) ? ShortAccount(name) : !string.IsNullOrWhiteSpace(email) ? ShortAccount(email) : signedIn ? "AI account" : "Not signed in";

  public static string ShortAccount(string value) => value.Contains('@') ? value.Split('@')[0] : value;

  public static string HomePath(string path, string home) => path.Equals(home, StringComparison.OrdinalIgnoreCase) ? "~" :
    path.StartsWith(home.TrimEnd('\\', '/') + "\\", StringComparison.OrdinalIgnoreCase) || path.StartsWith(home.TrimEnd('\\', '/') + "/", StringComparison.OrdinalIgnoreCase)
      ? "~" + path[home.TrimEnd('\\', '/').Length..] : path;

  public static string MiddlePath(string value, double width, Func<string, double> measure)
  {
    if (width <= 0) return "";
    if (measure(value) <= width) return value;
    if (measure("…") > width) return "";
    var offsets = StringInfo.ParseCombiningCharacters(value);
    string Compact(int keep)
    {
      var head = keep / 3; var tail = keep - head;
      return (head == 0 ? "" : value[..offsets[head]]) + "…" + (tail == 0 ? "" : value[offsets[offsets.Length - tail]..]);
    }
    var low = 0; var high = Math.Max(0, offsets.Length - 1);
    while (low < high)
    {
      var middle = (low + high + 1) / 2;
      if (measure(Compact(middle)) <= width) low = middle; else high = middle - 1;
    }
    return Compact(low);
  }
}
