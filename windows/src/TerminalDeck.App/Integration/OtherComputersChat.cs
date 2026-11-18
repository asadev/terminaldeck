using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TerminalDeck.App.Integration;

public sealed partial class OtherComputersService
{
  private readonly ConcurrentDictionary<(string, string), SemaphoreSlim> chatRequests = new();
  private readonly ConcurrentDictionary<(string Computer, string Session), byte> watchedChats = new();
  public async Task<JsonElement> ChatOptionsAsync(string computer, string session, JsonObject? patch = null, CancellationToken ct = default)
  {
    RequireCapability(computer, "chats");
    var gate = chatRequests.GetOrAdd((computer, session), _ => new(1)); await gate.WaitAsync(ct);
    try
    {
      // Older hosts identify options replies by chat id, not by request id.
      var fields = patch ?? new JsonObject();
      return await RequestAsync(computer, "chats", patch is null ? "chats.options" : "chats.set", fields, ["chats.options"], ct, correlation: "id", requestId: session);
    }
    finally { gate.Release(); }
  }
  public async Task ChatActionAsync(string computer, string session, string action, string? text = null, string? request = null, bool approved = false, string? clientId = null, CancellationToken ct = default)
  {
    RequireCapability(computer, "chats");
    var tag = action switch { "watch" => "chats.watch", "unwatch" => "chats.unwatch", "send" => "chats.say", "interrupt" => "chats.interrupt", "answer" => "chats.answer", _ => throw new ArgumentException("Choose a chat action.") };
    var fields = new JsonObject { ["t"] = tag, ["id"] = session };
    if (action == "send")
    {
      if (string.IsNullOrWhiteSpace(text) || System.Text.Encoding.UTF8.GetByteCount(text) > 16000) throw new ArgumentException("Send a message of at most 16 KB.");
      fields["text"] = text; fields["clientMessageId"] = clientId ?? Guid.NewGuid().ToString();
    }
    if (action == "answer") { fields["request"] = request ?? throw new ArgumentException("Choose an approval request."); fields["approved"] = approved; }
    if (action == "unwatch") watchedChats.TryRemove((computer, session), out _);
    await SendAsync(computer, fields, ct);
    if (action == "watch") watchedChats[(computer, session)] = 0;
  }
}
