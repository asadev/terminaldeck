using System.Text;

namespace TerminalDeck.Core.Chats;

public sealed record ChatMatch(string RowId, int Offset, int Length, string Kind, string Text);

// All text consumers use the recorded conversation, including rows hidden by
// the viewport's initial history limit. Drafts and attachment bytes stay out.
public static class ChatText
{
  public static string FolderTitle(string folder)
  {
    var name = Path.GetFileName(Path.TrimEndingDirectorySeparator(folder)); if (string.IsNullOrWhiteSpace(name)) name = folder;
    var length = Math.Min(120, name.Length); if (length < name.Length && char.IsHighSurrogate(name[length - 1])) length--;
    return name[..length];
  }
  public const int MaximumPromptBytes = 262144;
  public static int PromptBytes(string text) => Encoding.UTF8.GetByteCount(text);
  public static void ValidatePrompt(string text)
  {
    if (text.Contains('\0')) throw new ArgumentException("Remove the null character from this prompt.");
    if (PromptBytes(text) > MaximumPromptBytes)
      throw new ArgumentException("This prompt is over 262144 UTF-8 bytes. Edit the full prompt before sending.");
  }
  public static IReadOnlyList<ChatMatch> Find(ChatRecord chat, string query, string? kind = null)
  {
    if (string.IsNullOrWhiteSpace(query)) return [];
    var result = new List<ChatMatch>();
    foreach (var row in ChatProjection.Rows(chat).Where(r => kind is null || r.Kind == kind))
      for (var offset = 0; offset <= row.Text.Length - query.Length;)
      {
        var found = row.Text.IndexOf(query, offset, StringComparison.OrdinalIgnoreCase);
        if (found < 0) break;
        result.Add(new(row.Kind + ":" + row.Id, found, query.Length, row.Kind, row.Text));
        offset = found + query.Length;
      }
    return result;
  }
  public static IReadOnlyList<string> Prompts(ChatRecord chat) => ChatProjection.Rows(chat)
    .Where(r => r.Kind == "user" && !string.IsNullOrWhiteSpace(r.Text)).Select(r => r.Text).ToArray();
  public static string Export(ChatRecord chat)
  {
    var text = new StringBuilder();
    foreach (var row in ChatProjection.Rows(chat with { Messages = [] }))
    {
      text.AppendLine(row.Kind switch { "user" => "You", "assistant" => "Assistant", "tool" => "Tool: " + row.Text, _ => row.Kind });
      text.AppendLine(row.Kind == "tool" ? row.Details : row.Text);
      if (row.Kind == "approval" && row.Details.Length > 0) text.AppendLine(row.Details);
      text.AppendLine();
    }
    return text.ToString().TrimEnd();
  }
}

public sealed class ChatPromptRecall
{
  private int? position;
  private string preserved = "";
  private string? recalled;
  private string[] history = [];
  public string? Move(bool previous, string current, IReadOnlyList<string> prompts)
  {
    if (position.HasValue && current != recalled) Reset();
    if (!position.HasValue)
    {
      if (!previous || prompts.Count == 0) return null;
      preserved = current; history = prompts.ToArray(); position = history.Length;
    }
    var next = position.Value + (previous ? -1 : 1);
    if (next < 0) return null;
    if (next >= history.Length) { var draft = preserved; Reset(); return draft; }
    position = next; recalled = history[next]; return recalled;
  }
  public bool IsRecalled(string text) => position.HasValue && recalled == text;
  public void Reset() { position = null; recalled = null; history = []; }
}
