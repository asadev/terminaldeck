using System.Globalization;
namespace TerminalDeck.App.Shell;

public static class WorkspaceText
{
  public static string AccountIdentity(string? provider, bool signedIn, string? email, string? name) =>
    string.Equals(provider, "shell", StringComparison.OrdinalIgnoreCase) ? "" :
    signedIn ? email ?? name ?? "Not signed in" : "Not signed in";

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
