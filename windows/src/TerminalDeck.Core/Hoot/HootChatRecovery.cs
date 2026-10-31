using TerminalDeck.Core.Chats;

namespace TerminalDeck.Core.Hoot;

// The general chat owner must leave Hoot's backing chats to HootService. Its
// permission/recovery fence must run before a live worker can drain a queue.
public static class HootChatRecovery
{
  public static IReadOnlyList<ChatRecord> OrdinaryChats(IEnumerable<ChatRecord> chats, HootState? hoot)
  {
    if (hoot is null) return chats.ToArray();
    if (hoot.Turns.IsDefault) throw new IOException("Hoot's saved turns could not be read safely.");
    var owned = hoot.Turns.Where(t => t.ChatId is not null).Select(t => t.ChatId!).ToHashSet(StringComparer.Ordinal);
    if (hoot.ChatId is { } current) owned.Add(current);
    return chats.Where(chat => !owned.Contains(chat.Definition.Id)).ToArray();
  }
}
