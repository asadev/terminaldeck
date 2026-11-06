using System.Collections.Immutable;
using System.Text.Json;
using TerminalDeck.Core.Chats;

namespace TerminalDeck.Core.Hoot;

public sealed partial class HootService
{
  public async ValueTask BranchAsync(string lineId, bool rewind, CancellationToken ct = default)
  {
    await gate.WaitAsync(ct);
    try
    {
      if (state.Busy || state.Waiting > 0 || state.Lines.Any(l => l.Kind == "approval" && l.Waiting)) throw new InvalidOperationException("Finish Hoot's current and queued turns before copying this conversation.");
      var selected = state.Lines.FirstOrDefault(l => l.Id == lineId && l.Kind is "user" or "assistant") ?? throw new ArgumentException("Choose a recorded Hoot message.");
      var settings = state.Settings ?? throw new InvalidOperationException("Choose Hoot's account first.");
      if (chats is not ChatSessions owner) throw new InvalidOperationException("Hoot's history owner is not connected.");
      var cutoff = selected.Sequence - (rewind && selected.Kind == "user" ? 1 : 0);
      var lines = state.Lines.Where(l => l.Sequence <= cutoff).ToImmutableArray();
      var ids = lines.Select(l => l.TurnId).ToHashSet();
      var turns = state.Turns.Where(t => ids.Contains(t.Id)).ToImmutableArray();
      var sourceIds = turns.Select(t => t.ChatId).OfType<string>().Distinct().ToArray();
      var messages = new List<ChatMessage>(); var events = new List<ChatEvent>();
      foreach (var line in lines)
      {
        var turn = turns.FirstOrDefault(t => t.Id == line.TurnId);
        var source = turn?.ChatId is { } chatId ? chats.Get(chatId) : null;
        var prefix = source is null ? "" : source.Definition.Id + ":" + line.TurnId + ":";
        var nativeId = prefix.Length > 0 && line.Id.StartsWith(prefix, StringComparison.Ordinal) ? line.Id[prefix.Length..] : line.Id;
        var original = source?.Events.LastOrDefault(e => e.Id == nativeId);
        var kind = line.Kind switch { "assistant" => "message", "tool" => "toolResult", _ => line.Kind };
        JsonElement? data = original?.Data;
        if (kind == "toolResult" && data is null) data = JsonSerializer.SerializeToElement(new { text = line.Details });
        events.Add(new(events.Count + 1, kind, line.Id, line.Kind == "tool" ? line.Details : line.Text, line.TurnId, data, line.At));
        if (line.Kind == "user" && line.TurnId is { } client)
        {
          var media = source?.Messages.FirstOrDefault(m => m.ClientId == client)?.Media ?? [];
          messages.Add(new(client, line.Text, media, ChatMessageState.Sent));
        }
      }
      var account = accounts.Get(settings.AccountId);
      var instructions = HootDesk.Instructions + "\n\n<deck-memory>\n" + HootDesk.Snapshot(state, Now).Text + "\n</deck-memory>";
      var definition = new ChatDefinition(Guid.NewGuid().ToString(), settings.Provider, settings.Folder, "Hoot", account.Id, account.HomeId, settings.Options, instructions, settings.PermissionMode);
      var copied = await owner.ImportBranchAsync(definition, sourceIds, events.ToArray(), messages.ToArray(), ct);
      var archived = new HootConversation(state.ConversationId, state.Lines, state.Turns, Now);
      // Publish only after the entire visible history and every source media
      // directory have been copied. A failure never edits the source chat.
      Save(state with { ConversationId = Guid.NewGuid().ToString(), ChatId = copied.Definition.Id, Lines = lines, Turns = turns,
        History = state.History.Add(archived), Problem = null, Paused = false });
      Follow(copied.Definition.Id);
    }
    finally { gate.Release(); }
  }
}
