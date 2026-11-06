namespace TerminalDeck.Core.Chats;

public sealed partial class ChatSessions
{
  internal async ValueTask<ChatRecord> ImportBranchAsync(ChatDefinition definition, string[] sourceIds, ChatEvent[] events, ChatMessage[] messages, CancellationToken ct)
  {
    await gate.WaitAsync(ct);
    try
    {
      definition.Validate();
      if (history is not ChatHistory files) throw new InvalidOperationException("This chat's history store cannot copy a conversation safely.");
      foreach (var sourceId in sourceIds) _ = Get(sourceId);
      var child = new ChatRecord(1, definition, Guid.NewGuid().ToString("N"), events, messages, HasCustomTitle: true, ReplayHistory: true);
      files.CopyCombinedBranch(sourceIds, child); Save(child); return child;
    }
    finally { gate.Release(); }
  }
  // History replay is provider independent, including saved chats without a
  // provider fork API. Originals are never truncated to make a fork.
  public async ValueTask<ChatRecord> BranchAsync(string id, string? messageId, bool rewind, CancellationToken ct = default, string? title = null)
  {
    await gate.WaitAsync(ct);
    try
    {
      var source = Get(id);
      if (source.Busy || source.Stopping || source.Messages.Any(m => m.State is ChatMessageState.Queued or ChatMessageState.Dispatching || Unconfirmed(source, m)))
        throw new InvalidOperationException("Finish this answer and queued messages before rewinding or forking.");
      if (history is not ChatHistory files) throw new InvalidOperationException("This chat's history store cannot copy a conversation safely.");
      var selected = messageId is null ? null : source.Events.LastOrDefault(e => e.Id == messageId && e.Kind is "user" or "message" or "textDelta")
        ?? throw new ArgumentException("Choose a recorded message.");
      var cutoff = selected is null ? long.MaxValue : selected.Sequence - (rewind && selected.Kind == "user" ? 1 : 0);
      ChatRecord Prefix(ChatRecord record)
      {
        var events = record.Events.Where(e => e.Sequence <= cutoff).ToArray();
        var clients = events.Where(e => e.Kind == "user").Select(e => e.ClientId).ToHashSet();
        return record with { Events = events, Messages = record.Messages.Where(m => clients.Contains(m.ClientId)).ToArray(),
          ConversationId = null, CreationKey = Guid.NewGuid().ToString("N"), WorkerSequence = 0, Busy = false, ActiveClientId = null,
          Problem = null, WaitingSince = null, Paused = false, Stopping = false, Ended = false, ReplayHistory = true,
          Definition = record.Definition with { ForkSession = false } };
      }
      var childId = Guid.NewGuid().ToString();
      var childTitle = !rewind && !string.IsNullOrWhiteSpace(title) ? title.Trim() : (rewind ? "Before rewind · " : "Fork · ") + source.Definition.Title;
      if (childTitle.Any(char.IsControl)) throw new ArgumentException("Use a session name on one line.");
      if (childTitle.Length > 120) childTitle = childTitle[..(char.IsHighSurrogate(childTitle[119]) ? 119 : 120)];
      var child = (rewind ? source with { Ended = true } : Prefix(source)) with
      { Definition = source.Definition with { Id = childId, Title = childTitle, ForkSession = false }, CreationKey = Guid.NewGuid().ToString("N"), HasCustomTitle = true };
      // Copy every media file (including tool-result media) before publishing
      // any record. A failed copy leaves the source and its worker untouched.
      files.CopyBranch(source.Definition.Id, child);
      Save(child);
      if (!rewind) return child;
      var restored = Prefix(source);
      await RetireWorkerAsync(source, ct);
      Save(restored);
      return restored;
    }
    finally { gate.Release(); }
  }
}
