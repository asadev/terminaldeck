namespace TerminalDeck.Core.Cloud;

public static class CloudCalmWords
{
  public static string Summary(string explanation)
  {
    var words = explanation.Trim();
    if (words.Contains("saved password", StringComparison.OrdinalIgnoreCase) || words.Contains("secret", StringComparison.OrdinalIgnoreCase)) return "Some saved passwords are not in your Cloud yet";
    if (words.Contains("device", StringComparison.OrdinalIgnoreCase) && (words.Contains("trust", StringComparison.OrdinalIgnoreCase) || words.Contains("waiting", StringComparison.OrdinalIgnoreCase))) return "A device needs a look";
    return words.StartsWith("Waiting: ", StringComparison.OrdinalIgnoreCase) ? words[9..] : words;
  }
}
