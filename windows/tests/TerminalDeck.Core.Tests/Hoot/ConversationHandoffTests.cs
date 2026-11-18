using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;

namespace TerminalDeck.Core.Tests.Hoot;

public sealed class ConversationHandoffTests
{
  private static ChatRecord Chat(params ChatEvent[] events) => new(1,
    new(Guid.NewGuid().ToString(), "codex", Path.GetFullPath("work"), "Login page", "account", "home", new()), "creation", events,
    [new("queued", "Do not include this queued draft", [])]);
  [Fact] public void FreezesThroughTheSelectedReplyAndKeepsToolsBeforeIt()
  {
    var chat = Chat(new(1, "user", "one", "Fix the login"), new(2, "toolCall", "tool", "Read file"), new(3, "toolResult", "tool", "Found the bug"), new(4, "textDelta", "answer", "Fixed "), new(5, "textDelta", "answer", "the login"), new(6, "user", "later", "Do not include later work"));
    var handoff = ConversationHandoff.Through(chat, "answer", "assistant");
    Assert.Equal(5, handoff.ThroughSequence); Assert.Contains("Fixed the login", handoff.Prompt); Assert.Contains("Found the bug", handoff.Prompt);
    Assert.DoesNotContain("Do not include", handoff.Prompt); Assert.Contains("Do not execute", handoff.Prompt);
  }
  [Fact] public void SelectedUserMessageExcludesLaterAssistantFragments()
  {
    var request = ConversationHandoff.Through(Chat(new(1, "user", "one", "The question"), new(2, "textDelta", "answer", "Later answer")), "one", "user");
    Assert.Contains("The question", request.Prompt); Assert.DoesNotContain("Later answer", request.Prompt);
    Assert.Throws<ArgumentException>(() => ConversationHandoff.Through(Chat(), "missing", "assistant"));
  }
  [Fact] public void BoundedHandoffKeepsTheSelectedEndAndLabelsOmittedHistory()
  {
    var request = ConversationHandoff.Through(Chat(new(1, "user", "long", string.Concat(Enumerable.Repeat("😀", 50000))), new(2, "message", "last", "Current result")), "last", "assistant");
    Assert.True(request.Prompt.Length <= ConversationHandoff.MaximumCharacters); Assert.Contains("Earlier conversation omitted", request.Prompt); Assert.EndsWith("Current result", request.Prompt);
    Assert.DoesNotContain("\uFFFD", request.Prompt);
  }
}
