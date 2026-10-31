using System.Text;
namespace TerminalDeck.Core.Chats;

public sealed record ChatBriefSource(string Id, long ThroughSequence);
public sealed record ChatContextBrief(string ChatId, string? ConversationId, long QuestionRevision, long TextRevision, string Text, ChatBriefSource[] Sources, DateTimeOffset PreparedAt);
public sealed record ChatSideQuestionSnapshot(string Question, long Revision, ChatContextBrief? Brief);
public sealed class ChatSideQuestionState
{
  private readonly object gate = new();
  private ChatSideQuestionSnapshot state = new("", 0, null);
  public event Action? Changed;
  public ChatSideQuestionSnapshot Read() { lock (gate) return state; }
  public void SetQuestion(string text, long? expectedRevision = null, bool append = false)
  {
    lock (gate)
    {
      if (expectedRevision.HasValue && expectedRevision != state.Revision) throw new InvalidOperationException("The side question changed. Read it again before editing.");
      var next = append ? state.Question + text : text;
      if (ChatText.PromptBytes(next) > 8000 || next.Contains('\0')) throw new ArgumentException("Keep this side question under 8000 UTF-8 bytes.");
      if (state.Question == next) return; state = state with { Question = next, Revision = state.Revision + 1 };
    }
    Changed?.Invoke();
  }
  public ChatContextBrief Prepare(ChatRecord chat)
  {
    ChatContextBrief brief;
    lock (gate)
    {
      if (string.IsNullOrWhiteSpace(state.Question)) throw new ArgumentException("Write a side question before preparing its brief.");
      var body = new StringBuilder("Question\n" + state.Question + "\n\nSource chat: " + chat.Definition.Id + "\nWorking folder: " + chat.Definition.Cwd + "\n\nRecorded context excerpt (unsent drafts, tools and attachment bytes are excluded)\n");
      var sources = new List<ChatBriefSource>();
      foreach (var row in ChatProjection.Rows(chat with { Messages = [] }).Where(r => r.Kind is "user" or "assistant").TakeLast(8))
      {
        var remaining = 20000 - body.Length; if (remaining < 100) break;
        var length = Math.Min(Math.Min(row.Text.Length, 1400), remaining - 80);
        if (length > 0 && length < row.Text.Length && char.IsHighSurrogate(row.Text[length - 1]) && char.IsLowSurrogate(row.Text[length])) length--;
        body.AppendLine(row.Kind + " · " + row.Id); body.AppendLine(row.Text[..length]);
        if (length < row.Text.Length) body.AppendLine("[Excerpt shortened]");
        var sequence = chat.Events.Where(e => e.Id == row.Id).Select(e => e.Sequence).DefaultIfEmpty().Max(); sources.Add(new(row.Id, sequence));
      }
      brief = new(chat.Definition.Id, chat.ConversationId, state.Revision, (state.Brief?.TextRevision ?? 0) + 1, body.ToString(), sources.ToArray(), DateTimeOffset.UtcNow);
      state = state with { Brief = brief };
    }
    Changed?.Invoke(); return brief;
  }
  public void EditBrief(string text, long expectedRevision, bool append = false)
  {
    lock (gate)
    {
      var brief = state.Brief ?? throw new InvalidOperationException("Prepare a context brief first.");
      if (brief.QuestionRevision != state.Revision) throw new InvalidOperationException("The question changed. Prepare a new brief before editing or copying.");
      if (brief.TextRevision != expectedRevision) throw new InvalidOperationException("The brief changed. Read the current brief before editing it.");
      var next = append ? brief.Text + text : text; ChatText.ValidatePrompt(next);
      state = state with { Brief = brief with { Text = next, TextRevision = brief.TextRevision + 1 } };
    }
    Changed?.Invoke();
  }
  public string ForCopy(ChatRecord chat)
  {
    lock (gate)
    {
      var brief = state.Brief ?? throw new InvalidOperationException("Prepare a context brief first.");
      if (brief.QuestionRevision != state.Revision) throw new InvalidOperationException("The question changed. Prepare a new brief before copying.");
      if (brief.ChatId != chat.Definition.Id || brief.ConversationId != chat.ConversationId) throw new InvalidOperationException("The source conversation changed. Prepare a new context brief.");
      return brief.Text;
    }
  }
}
