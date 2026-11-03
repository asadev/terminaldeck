using System.Text.Json;
using System.Text.Json.Nodes;

namespace TerminalDeck.Core.Remote;

// Optional negotiated extension. Only explicit reads/writes; no clipboard
// watcher or background synchronization exposes unrelated copied content.
public sealed class PhoneClipboardFeatures(Func<CancellationToken, Task<string>> read, Func<string, CancellationToken, Task> write) : IPhoneHostWorkspace
{
  public IReadOnlyList<string> Capabilities => ["clipboard"];
  public bool Handles(string type) => type is "clipboard.read" or "clipboard.write";
  public bool Permits(PhoneAccess access, string type) => access == PhoneAccess.Full;
  public async ValueTask<IReadOnlyList<JsonObject>> HandleAsync(string channel, ApprovedDevice device, string type, JsonElement message, string? rid, CancellationToken ct)
  {
    if (!Permits(device.Access, type)) throw new PhoneRefusal("unauthorized", "Clipboard access needs Full control.");
    if (string.IsNullOrWhiteSpace(rid)) throw new PhoneRefusal("bad-message", "Clipboard requests need a request id.");
    if (type == "clipboard.read")
    {
      var text = await read(ct);
      if (text.Length > 16000) throw new PhoneRefusal("unavailable", "Copy up to 16,000 characters at once.");
      return [new() { ["t"] = "clipboard.reading", ["rid"] = rid, ["text"] = text }];
    }
    if (type != "clipboard.write" || !message.TryGetProperty("text", out var value) || value.ValueKind != JsonValueKind.String || value.GetString() is not { } content || content.Length > 16000) throw new PhoneRefusal("bad-message", "Send up to 16,000 characters of clipboard text.");
    ct.ThrowIfCancellationRequested(); await write(content, ct);
    return [new() { ["t"] = "clipboard.written", ["rid"] = rid, ["ok"] = true }];
  }
  public ValueTask DisconnectedAsync(string channel) => ValueTask.CompletedTask;
}
