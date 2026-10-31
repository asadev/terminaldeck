using System.Text.Json;

namespace TerminalDeck.Core.Chats;

// MCP images arrive in small, idempotent chunks because the existing session
// tool has a 4000-character bound. Bytes are transient, never chat.json fields.
public sealed class ChatImageUploads(IChatSessions chats, int maximumChunkCharacters = 2800) : IDisposable
{
  private sealed record Upload(string Chat, string Caller, string Name, string Mime, int Width, int Height, DateTimeOffset Expires,
    MemoryStream Bytes, ChatMedia? Saved = null);
  private readonly Dictionary<string, Upload> uploads = [];
  private readonly SemaphoreSlim gate = new(1);
  public async ValueTask<object> ApplyAsync(string chat, string caller, JsonElement command, CancellationToken ct)
  {
    var id = command.GetProperty("uploadId").GetString() ?? "";
    if (!Guid.TryParse(id, out _)) throw new ArgumentException("Choose an image upload id.");
    await gate.WaitAsync(ct);
    try
    {
      foreach (var expired in uploads.Where(p => p.Value.Expires < DateTimeOffset.UtcNow).Select(p => p.Key).ToArray())
      { uploads[expired].Bytes.Dispose(); uploads.Remove(expired); }
      var action = command.GetProperty("action").GetString();
      if (action == "imageBegin")
      {
        var name = command.GetProperty("name").GetString() ?? "image"; var mime = command.GetProperty("mimeType").GetString() ?? "";
        var width = command.GetProperty("width").GetInt32(); var height = command.GetProperty("height").GetInt32();
        if (mime is not ("image/png" or "image/jpeg") || width is <= 0 or > 2048 || height is <= 0 or > 2048 || name.Length > 120) throw new ArgumentException("Send a PNG or JPEG resized to at most 2048 pixels.");
        if (uploads.TryGetValue(id, out var existing))
        { if (existing.Chat != chat || existing.Caller != caller || existing.Name != name || existing.Mime != mime || existing.Width != width || existing.Height != height) throw new InvalidOperationException("That upload id belongs to another image."); return new { uploadId = id, offset = existing.Bytes.Length }; }
        if (uploads.Count >= 16) throw new InvalidOperationException("Finish an image upload before starting another.");
        uploads[id] = new(chat, caller, name, mime, width, height, DateTimeOffset.UtcNow.AddMinutes(10), new());
        return new { uploadId = id, offset = 0 };
      }
      if (!uploads.TryGetValue(id, out var upload) || upload.Chat != chat || upload.Caller != caller) throw new InvalidOperationException("Start this image upload again.");
      if (action == "imageChunk")
      {
        var offset = command.GetProperty("offset").GetInt32(); var encoded = command.GetProperty("data").GetString() ?? "";
        if (encoded.Length > Math.Clamp(maximumChunkCharacters, 2800, 1_400_000) || offset < 0) throw new ArgumentException("Send smaller image chunks.");
        byte[] bytes; try { bytes = Convert.FromBase64String(encoded); } catch (FormatException) { throw new ArgumentException("Send a valid image chunk."); }
        if (offset < upload.Bytes.Length)
        {
          if (offset + bytes.Length > upload.Bytes.Length || !upload.Bytes.GetBuffer().AsSpan(offset, bytes.Length).SequenceEqual(bytes)) throw new InvalidOperationException("That image chunk differs from its saved copy.");
        }
        else
        {
          if (upload.Saved is not null || offset != upload.Bytes.Length || offset + bytes.Length > 8 * 1024 * 1024) throw new ArgumentException("Check the image upload offset and size.");
          upload.Bytes.Write(bytes);
        }
        return new { uploadId = id, offset = upload.Bytes.Length };
      }
      if (action == "imageFinish")
      {
        var saved = upload.Saved ?? await chats.AddImageAsync(chat, upload.Name, upload.Mime, upload.Bytes.ToArray(), upload.Width, upload.Height, ct);
        uploads[id] = upload with { Saved = saved }; return new { uploadId = id, media = saved };
      }
      throw new ArgumentException("Choose imageBegin, imageChunk or imageFinish.");
    }
    finally { gate.Release(); }
  }
  public async ValueTask<ChatMedia[]> ResolveAsync(string chat, string caller, JsonElement command, CancellationToken ct)
  {
    if (!command.TryGetProperty("uploadIds", out var ids)) return [];
    await gate.WaitAsync(ct);
    try
    {
      return ids.EnumerateArray().Select(id => uploads.TryGetValue(id.GetString() ?? "", out var upload) && upload.Chat == chat && upload.Caller == caller && upload.Saved is { } saved
        ? saved : throw new InvalidOperationException("Finish this chat's image upload first.")).ToArray();
    }
    finally { gate.Release(); }
  }
  public void Dispose() { foreach (var upload in uploads.Values) upload.Bytes.Dispose(); gate.Dispose(); }
}
