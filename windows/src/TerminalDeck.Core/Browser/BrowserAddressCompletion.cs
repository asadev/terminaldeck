namespace TerminalDeck.Core.Browser;

public sealed record BrowserAddressSuggestion(string Url, int SelectionStart, int SelectionLength);
public static class BrowserAddressCompletion
{
  public static BrowserAddressSuggestion? Complete(string input, bool deleting, IEnumerable<string> visits)
  {
    if (deleting || string.IsNullOrWhiteSpace(input) || input.Any(char.IsWhiteSpace)) return null;
    foreach (var visit in visits)
    {
      if (!Uri.TryCreate(visit, UriKind.Absolute, out var url) || url.Scheme is not ("http" or "https") || url.UserInfo.Length > 0) continue;
      var prefix = visit.StartsWith(input, StringComparison.OrdinalIgnoreCase) ? 0 :
        visit[(visit.IndexOf("://", StringComparison.Ordinal) + 3)..].StartsWith(input, StringComparison.OrdinalIgnoreCase) ? visit.IndexOf("://", StringComparison.Ordinal) + 3 : -1;
      if (prefix < 0 || prefix + input.Length >= visit.Length) continue;
      return new(visit, prefix + input.Length, visit.Length - prefix - input.Length);
    }
    return null;
  }
}
