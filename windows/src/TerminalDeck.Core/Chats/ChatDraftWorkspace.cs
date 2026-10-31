using System.Collections.Concurrent;
namespace TerminalDeck.Core.Chats;

public sealed record ChatDraftSnapshot(string Text, long Revision);

// Drafts belong to the app process, not the provider's recorded conversation.
// Both the visible editor and app tools use the same compare-and-apply guard.
public sealed class ChatDraftBuffer
{
  private readonly object gate = new();
  private string text = "";
  private long revision;
  public ChatSideQuestionState SideQuestion { get; } = new();
  public ChatEditorCopy? EditorCopy { get; private set; }
  public void SetEditorCopy(ChatEditorCopy? copy) { lock (gate) EditorCopy = copy; Changed?.Invoke(); }
  public event Action? Changed;
  public event Action<string>? ControlRequested;
  public void OpenControl(string control)
  {
    var handler = ControlRequested ?? throw new InvalidOperationException("Open this chat’s composer before opening its controls.");
    handler(control);
  }
  public ChatDraftSnapshot Read() { lock (gate) return new(text, revision); }
  public void Edit(string value)
  {
    lock (gate) { if (text == value) return; text = value; revision++; }
    Changed?.Invoke();
  }
  public ChatDraftSnapshot Apply(string value, long expectedRevision, bool append = false)
  {
    ChatDraftSnapshot updated;
    lock (gate)
    {
      if (revision != expectedRevision) throw new InvalidOperationException("The draft changed. Read the current draft before applying this edit.");
      var next = append ? text + value : value; ChatText.ValidatePrompt(next);
      text = next; revision++; updated = new(text, revision);
    }
    Changed?.Invoke(); return updated;
  }
}
public static class ChatDraftWorkspace
{
  private static readonly ConcurrentDictionary<string, ChatDraftBuffer> Buffers = new();
  public static ChatDraftBuffer Open(string id) => Buffers.GetOrAdd(id, _ => new());
  public static ChatDraftBuffer Require(string id) => Buffers.GetValueOrDefault(id) ?? throw new InvalidOperationException("Open this chat’s composer before editing its draft.");
  public static ChatSideQuestionSnapshot? ReadSideQuestion(string id) => Buffers.GetValueOrDefault(id)?.SideQuestion.Read();
  public static ChatDraftSnapshot? Read(string id) => Buffers.GetValueOrDefault(id)?.Read();
}
