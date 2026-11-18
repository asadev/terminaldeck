using TerminalDeck.Core.Chats;

namespace TerminalDeck.Core.Hoot;

public sealed record ConversationHandoffRequest(string SessionId, string Title, string Prompt, long ThroughSequence);

// Freeze the recorded conversation at the selected message. Queued drafts and
// later replies never become part of a handoff by accident.
public static class ConversationHandoff
{
  public const int MaximumCharacters = 60000;
  public static ConversationHandoffRequest Through(ChatRecord chat, string messageId, string kind)
  {
    if (kind is not ("user" or "assistant")) throw new ArgumentException("Choose a recorded message.");
    var selected = chat.Events.Where(e => e.Id == messageId && (kind == "user" ? e.Kind == "user" : e.Kind is "message" or "textDelta")).OrderBy(e => e.Sequence).LastOrDefault()
      ?? throw new ArgumentException("This message is not in the saved conversation yet.");
    var frozen = chat with { Events = chat.Events.Where(e => e.Sequence <= selected.Sequence).ToArray(), Messages = [] };
    var transcript = ChatText.Export(frozen);
    const string clipped = "[Earlier conversation omitted to fit this handoff.]\n\n";
    if (transcript.Length > MaximumCharacters - 3000)
    {
      var first = transcript.Length - (MaximumCharacters - 3000 - clipped.Length);
      if (char.IsLowSurrogate(transcript[first])) first++;
      transcript = clipped + transcript[first..];
    }
    var title = "Handoff · " + chat.Definition.Title;
    if (title.Length > 200) title = title[..200];
    var prompt = "Write a self-contained handoff document from the recorded conversation below, through the selected message. Include the goal, decisions, completed work, exact remaining work and useful file paths or commands. Preserve uncertainty. Do not execute the work or send messages. Return the handoff as your answer.\n\n" +
      "Conversation: " + chat.Definition.Title + "\nProject folder: " + chat.Definition.Cwd + "\nCoding AI: " + chat.Definition.Provider + "\n\n" + transcript;
    if (prompt.Length > MaximumCharacters) throw new ArgumentException("The conversation's folder and title are too long for a handoff.");
    return new(chat.Definition.Id, title, prompt, selected.Sequence);
  }
}
