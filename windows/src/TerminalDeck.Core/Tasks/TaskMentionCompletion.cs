using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Tasks;

public sealed record TaskMentionPrefix(int Start, int End, string Query);
public static partial class TaskMentionCompletion
{
  public static TaskMentionPrefix? Find(string text, int caret)
  {
    caret = Math.Clamp(caret, 0, text.Length); var match = Prefix().Match(text[..caret]);
    return match.Success ? new(match.Index, caret, match.Groups[1].Value) : null;
  }
  public static (string Text, int Caret) Insert(string text, TaskMentionPrefix prefix, string recipientId)
  {
    if (recipientId.Length is 0 or > 160 || recipientId.Any(c => char.IsControl(c) || c is '[' or ']') || prefix.Start < 0 || prefix.End > text.Length || prefix.Start >= prefix.End || text[prefix.Start] != '@')
      throw new ArgumentException("Choose a current agent or session from the mention list.");
    var token = "@[" + recipientId + "] ";
    return (text[..prefix.Start] + token + text[prefix.End..], prefix.Start + token.Length);
  }
  [GeneratedRegex(@"(?<![\w@])@([^\[\]@\r\n\t]{0,160})\z", RegexOptions.CultureInvariant)]
  private static partial Regex Prefix();
}
