using System.Text.Json;
using System.Text.Json.Nodes;
using System.Security.Cryptography;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Accounts;

namespace TerminalDeck.Core.Chats;

// Media remains beside chat.json. Only opaque relative names cross the UI/MCP door.
public sealed class ChatHistory(AppDataRoot root) : IChatHistory
{
  public AppDataRoot DataRoot => root;
  internal IConversationFiles AccountConversations => new ConversationFiles(root);
  internal IStateStore<AccountSwitchJournal> AccountSwitchJournal => new JsonStateStore<AccountSwitchJournal>(root, "chat-account-switches");
  private string DirectoryFor(string id) => Path.Combine(root.DirectoryPath, "chats", Guid.Parse(id).ToString("N"));
  private static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };
  public IReadOnlyList<ChatRecord> List()
  {
    var directory = Path.Combine(root.DirectoryPath, "chats");
    return !Directory.Exists(directory) ? [] : Directory.EnumerateDirectories(directory)
      .Where(p => Guid.TryParseExact(Path.GetFileName(p), "N", out _))
      .Select(p => Load(Path.GetFileName(p))).OfType<ChatRecord>().ToArray();
  }
  public ChatRecord? Load(string id)
  {
    var path = Path.Combine(DirectoryFor(id), "chat.json");
    if (!File.Exists(path)) return null;
    if (new FileInfo(path).Length > 128L * 1024 * 1024) throw new IOException("This chat history is too large to open safely.");
    var chat = JsonSerializer.Deserialize<ChatRecord>(File.ReadAllBytes(path), Json) ?? throw new IOException("This chat history could not be read.");
    chat.Definition.Validate(allowSavedUnsupportedChoices: true);
    if (chat.Version != 1 || Guid.Parse(chat.Definition.Id) != Guid.Parse(id)) throw new IOException("This chat history belongs to another chat.");
    return chat;
  }
  public void CopyBranch(string sourceId, ChatRecord child) => CopyCombinedBranch([sourceId], child);
  internal void CopyCombinedBranch(IEnumerable<string> sourceIds, ChatRecord child)
  {
    var target = DirectoryFor(child.Definition.Id);
    if (Directory.Exists(target)) throw new IOException("The destination chat already exists.");
    var stage = target + ".copy-" + Guid.NewGuid().ToString("N");
    try
    {
      Directory.CreateDirectory(stage);
      foreach (var sourceId in sourceIds.Distinct())
      {
        var media = Path.Combine(DirectoryFor(sourceId), "media");
        if (Directory.Exists(media))
        {
          if (File.GetAttributes(media).HasFlag(FileAttributes.ReparsePoint)) throw new IOException("Chat media cannot be a linked directory.");
          Directory.CreateDirectory(Path.Combine(stage, "media"));
          foreach (var file in Directory.EnumerateFiles(media))
          {
            if (File.GetAttributes(file).HasFlag(FileAttributes.ReparsePoint)) throw new IOException("Chat media cannot be a linked file.");
            var copy = Path.Combine(stage, "media", Path.GetFileName(file));
            if (File.Exists(copy))
            { if (!File.ReadAllBytes(copy).AsSpan().SequenceEqual(File.ReadAllBytes(file))) throw new IOException("Two chats contain different media with the same identity."); }
            else File.Copy(file, copy);
          }
        }
      }
      using (var stream = new FileStream(Path.Combine(stage, "chat.json"), FileMode.CreateNew, FileAccess.Write))
      { JsonSerializer.Serialize(stream, child, Json); stream.Flush(true); }
      Directory.Move(stage, target);
    }
    finally { if (Directory.Exists(stage)) Directory.Delete(stage, true); }
  }
  public void Save(ChatRecord chat)
  {
    chat.Definition.Validate(allowSavedUnsupportedChoices: true); var directory = DirectoryFor(chat.Definition.Id); Directory.CreateDirectory(directory);
    var path = Path.Combine(directory, "chat.json"); var temporary = path + "." + Guid.NewGuid().ToString("N");
    try
    {
      using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
      { JsonSerializer.Serialize(stream, chat, Json); stream.Flush(true); }
      File.Move(temporary, path, true);
    }
    finally { if (File.Exists(temporary)) File.Delete(temporary); }
  }
  public async ValueTask<ChatMedia> AddImageAsync(string id, string name, string mimeType, ReadOnlyMemory<byte> bytes, int width, int height, CancellationToken cancellationToken)
  {
    var chat = Load(id) ?? throw new KeyNotFoundException("Choose an existing chat.");
    var document = mimeType == "application/pdf";
    if (document && (chat.Definition.Provider != "claude" || bytes.Length is < 5 or > 500000 || !bytes.Span[..5].SequenceEqual("%PDF-"u8))) throw new ArgumentException("This connection accepts readable PDF documents up to 500 KB only in Claude chats.");
    if (!document && (mimeType is not ("image/png" or "image/jpeg") || bytes.Length is <= 0 or > 8 * 1024 * 1024 || width is <= 0 or > 2048 || height is <= 0 or > 2048))
      throw new ArgumentException("Choose a PNG or JPEG image, up to 2048 pixels and 8 MB.");
    var imageId = Guid.NewGuid().ToString("N"); var relative = "media/" + imageId + (document ? ".pdf" : mimeType == "image/png" ? ".png" : ".jpg");
    var directory = DirectoryFor(id); Directory.CreateDirectory(Path.Combine(directory, "media"));
    var path = Path.Combine(directory, relative);
    await using (var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
    { await stream.WriteAsync(bytes, cancellationToken); await stream.FlushAsync(cancellationToken); stream.Flush(true); }
    var safeName = Path.GetFileName(name); if (safeName.Length > 120) safeName = safeName[..120];
    return new(imageId, safeName, mimeType, relative, width, height, bytes.Length);
  }
  public byte[] ReadMedia(string id, ChatMedia media)
  {
    if (!Guid.TryParseExact(media.Id, "N", out _) || media.RelativePath != "media/" + media.Id + (media.MimeType == "application/pdf" ? ".pdf" : media.MimeType == "image/png" ? ".png" : ".jpg"))
      throw new ArgumentException("Choose an image belonging to this chat.");
    var path = Path.Combine(DirectoryFor(id), media.RelativePath);
    if (!File.Exists(path) || new FileInfo(path).Length > 8 * 1024 * 1024 || (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
      throw new IOException("This chat image is unavailable.");
    var bytes = File.ReadAllBytes(path);
    if (media.MimeType == "application/pdf" && (bytes.Length is < 5 or > 500000 || !bytes.AsSpan(0, 5).SequenceEqual("%PDF-"u8))) throw new IOException("This PDF attachment changed or is no longer readable.");
    return bytes;
  }
  public JsonElement ExternalizeData(string id, JsonElement data)
  {
    if (data.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null) return data;
    var node = JsonNode.Parse(data.GetRawText());
    static string? Text(JsonNode? value) => value is JsonValue scalar && scalar.TryGetValue<string>(out var text) ? text : null;
    void Visit(JsonNode? current, int depth)
    {
      if (depth > 32) throw new IOException("The coding AI returned media nested too deeply to save safely.");
      if (current is JsonArray array) { foreach (var child in array) Visit(child, depth + 1); return; }
      if (current is not JsonObject obj) return;
      foreach (var field in obj.ToArray())
      {
        // Some MCP/provider envelopes put structured tool arguments or results
        // inside a JSON string. Sanitize that representation before saving it too.
        if (field.Key is "input" or "arguments" or "content" && Text(field.Value) is { } nested &&
          (nested.TrimStart().StartsWith('{') || nested.TrimStart().StartsWith('[')))
        {
          try { var parsed = JsonNode.Parse(nested); Visit(parsed, depth + 1); obj[field.Key] = parsed?.ToJsonString(); continue; }
          catch (JsonException) { }
        }
        if (field.Value is JsonValue value && value.TryGetValue<string>(out var text) )
        {
          var encoded = text; var mime = Text(obj["mimeType"]) ?? Text(obj["mime_type"]) ?? Text(obj["media_type"]) ?? "application/octet-stream";
          var isMedia = field.Key is "blob" or "base64" || field.Key == "data" && (Text(obj["type"]) is "base64" or "image" or "audio" || mime != "application/octet-stream");
          if (text.StartsWith("data:", StringComparison.Ordinal) && text.IndexOf(";base64,", StringComparison.Ordinal) is var separator && separator > 5)
          { mime = text[5..separator]; encoded = text[(separator + 8)..]; isMedia = true; }
          if (isMedia)
          {
            byte[] bytes; try { bytes = Convert.FromBase64String(encoded); } catch (FormatException) { obj[field.Key] = "[unreadable media omitted]"; continue; }
            if (bytes.Length > 8 * 1024 * 1024) throw new IOException("The coding AI returned media larger than 8 MB.");
            var name = "provider-" + Convert.ToHexStringLower(SHA256.HashData(bytes)) + ".bin";
            var directory = Path.Combine(DirectoryFor(id), "media"); Directory.CreateDirectory(directory); var path = Path.Combine(directory, name);
            if (!File.Exists(path)) File.WriteAllBytes(path, bytes);
            obj[field.Key] = JsonSerializer.SerializeToNode(new { mediaFile = "media/" + name, mimeType = mime, bytes = bytes.Length }); continue;
          }
        }
        Visit(field.Value, depth + 1);
      }
    }
    if (Text(node) is { } scalar && scalar.StartsWith("data:", StringComparison.Ordinal))
    {
      var wrapper = new JsonObject { ["data"] = scalar }; Visit(wrapper, 0);
      return JsonSerializer.SerializeToElement(wrapper["data"]);
    }
    Visit(node, 0); return JsonSerializer.SerializeToElement(node);
  }

}
