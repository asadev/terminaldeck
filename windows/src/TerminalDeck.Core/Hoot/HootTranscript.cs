namespace TerminalDeck.Core.Hoot;

public sealed record HootChatSlice(string ConversationId, string Status, bool Busy, HootLine[] Lines, long NextCursor);
public static class HootTranscript
{
  // Sequence is the stable position in the visible chat. Revision is a change
  // cursor, so a streamed answer can be updated without moving its bubble.
  public static HootChatSlice Read(HootState state, long cursor = 0, int limit = 200)
  {
    if (cursor < 0 || limit is < 1 or > 500) throw new ArgumentException("Choose a chat cursor and up to 500 messages.");
    var lines = state.Lines.Where(l => l.Revision > cursor).OrderBy(l => l.Revision).Take(limit).ToArray();
    return new(state.ConversationId, state.Status, state.Busy, lines, lines.LastOrDefault()?.Revision ?? cursor);
  }
}
