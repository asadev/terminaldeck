using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Chats;

public sealed record ChatMarkdownBlock(string Kind, string Text, string Language = "", int Level = 0);
public sealed record ChatMarkdownSpan(string Text, string Kind = "text", string? Target = null);

public static partial class ChatMarkdown
{
  [GeneratedRegex(@"^(#{1,6})\s+(.+)$")] private static partial Regex Heading();
  [GeneratedRegex(@"^\s*(?:[-+*]|\d+[.)])\s+(.+)$")] private static partial Regex ListItem();
  [GeneratedRegex(@"\[([^\]\n]+)\]\(([^\s)]+)\)|`([^`\n]+)`|\*\*([^*\n]+)\*\*|__([^_\n]+)__|\*([^*\n]+)\*")]
  private static partial Regex Inline();
  public static IReadOnlyList<ChatMarkdownBlock> Blocks(string text)
  {
    var result = new List<ChatMarkdownBlock>(); var paragraph = new List<string>(); var code = new List<string>(); string? fence = null; var language = "";
    void Flush() { if (paragraph.Count > 0) { result.Add(new("paragraph", string.Join('\n', paragraph))); paragraph.Clear(); } }
    foreach (var line in text.Replace("\r\n", "\n").Split('\n'))
    {
      var trimmed = line.TrimStart();
      if (fence is not null)
      {
        if (trimmed.StartsWith(fence, StringComparison.Ordinal) && trimmed.All(c => c == fence[0] || char.IsWhiteSpace(c)))
        { result.Add(new("code", string.Join('\n', code), language)); code.Clear(); fence = null; }
        else code.Add(line);
        continue;
      }
      if (trimmed.StartsWith("```", StringComparison.Ordinal) || trimmed.StartsWith("~~~", StringComparison.Ordinal))
      {
        Flush(); var marker = trimmed[0]; var length = trimmed.TakeWhile(c => c == marker).Count(); fence = new string(marker, length); language = trimmed[length..].Trim(); continue;
      }
      if (string.IsNullOrWhiteSpace(line)) { Flush(); continue; }
      var heading = Heading().Match(line);
      if (heading.Success) { Flush(); result.Add(new("heading", heading.Groups[2].Value, Level: heading.Groups[1].Length)); continue; }
      var list = ListItem().Match(line);
      if (list.Success) { Flush(); var marker = line[..(line.Length - list.Groups[1].Length)].Trim(); result.Add(new("list", list.Groups[1].Value, marker)); continue; }
      if (trimmed.StartsWith(">", StringComparison.Ordinal)) { Flush(); result.Add(new("quote", trimmed[1..].TrimStart())); continue; }
      paragraph.Add(line);
    }
    if (fence is not null) result.Add(new("code", string.Join('\n', code), language));
    Flush(); return result;
  }
  public static IReadOnlyList<ChatMarkdownSpan> Spans(string text)
  {
    var result = new List<ChatMarkdownSpan>(); var position = 0;
    foreach (Match match in Inline().Matches(text))
    {
      if (match.Index > position) result.Add(new(text[position..match.Index]));
      if (match.Groups[1].Success) result.Add(new(match.Groups[1].Value, "link", match.Groups[2].Value));
      else if (match.Groups[3].Success) result.Add(new(match.Groups[3].Value, "code"));
      else if (match.Groups[4].Success || match.Groups[5].Success) result.Add(new(match.Groups[4].Success ? match.Groups[4].Value : match.Groups[5].Value, "strong"));
      else result.Add(new(match.Groups[6].Value, "emphasis"));
      position = match.Index + match.Length;
    }
    if (position < text.Length) result.Add(new(text[position..])); return result;
  }
  public static bool CanOpenLink(string target) => Uri.TryCreate(target, UriKind.Absolute, out var uri) && uri.Scheme is "https" or "http" or "mailto";
}
