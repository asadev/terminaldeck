using System.Text;

namespace TerminalDeck.Core.Computers;

public static class ComputerSessionKeys
{
  public static string Encode(IEnumerable<string> keys)
  {
    var result = new System.Text.StringBuilder(); var count = 0;
    foreach (var key in keys)
    {
      if (++count > 64) throw new ArgumentException("Send at most 64 keys at once.");
      result.Append(key.ToLowerInvariant() switch
      {
        "enter" => "\r", "escape" => "\u001b", "tab" => "\t", "shift-tab" => "\u001b[Z", "backspace" => "\u007f", "delete" => "\u001b[3~", "space" => " ",
        "up" => "\u001b[A", "down" => "\u001b[B", "right" => "\u001b[C", "left" => "\u001b[D", "home" => "\u001b[H", "end" => "\u001b[F", "page-up" => "\u001b[5~", "page-down" => "\u001b[6~",
        _ when key.Length == 6 && key.StartsWith("ctrl-", StringComparison.OrdinalIgnoreCase) && char.ToLowerInvariant(key[5]) is >= 'a' and <= 'z' => ((char)(char.ToLowerInvariant(key[5]) - 'a' + 1)).ToString(),
        _ when key.EnumerateRunes().Count() == 1 && !key.Any(char.IsControl) => key,
        _ => throw new ArgumentException("Choose a named terminal key or one printable character.")
      });
    }
    return result.ToString();
  }
}
