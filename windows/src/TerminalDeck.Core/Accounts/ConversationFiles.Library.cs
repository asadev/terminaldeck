using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Sessions;

namespace TerminalDeck.Core.Accounts;

public sealed record SavedProviderConversation(string Id, string Provider, string Folder, string Path, DateTimeOffset ModifiedAt);
public sealed partial class ConversationFiles
{
  public IReadOnlyList<SavedProviderConversation> ListLibrary(SessionDefinition scope, int limit = 100)
  {
    var result = new List<SavedProviderConversation>(); var paths = Candidates(scope).ToArray();
    if (paths.Length > 4096) throw new IOException("This account has too many transcripts. Choose its exact conversation ID instead.");
    foreach (var path in paths)
    {
      try
      {
        var metadata = Identity(path, scope.Provider);
        // A file with no trustworthy folder identity never appears as though it
        // belongs to the current project. It can still be selected by exact id.
        if (metadata.Id is null || metadata.Folder is null || !Path.GetFullPath(metadata.Folder).Equals(Path.GetFullPath(scope.Cwd), OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal)) continue;
        result.Add(new(metadata.Id, scope.Provider, metadata.Folder, path, File.GetLastWriteTimeUtc(path)));
      }
      catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException) { }
    }
    return result.OrderByDescending(r => r.ModifiedAt).Take(Math.Clamp(limit, 1, 200)).ToArray();
  }
  public string ResolveLibraryIdentity(SessionDefinition scope, string locator)
  {
    locator = locator.Trim();
    if (Path.IsPathFullyQualified(locator))
    {
      var path = Path.GetFullPath(locator); var candidates = Candidates(scope).Take(4097).ToArray();
      if (candidates.Length > 4096 || !candidates.Any(c => Path.GetFullPath(c).Equals(path, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal))) throw new IOException("Choose a transcript inside the selected coding AI account's history.");
      NoLinks(path); locator = Identity(path, scope.Provider).Id ?? throw new IOException("That transcript has no usable conversation identity.");
    }
    _ = Locate(scope with { ConversationId = locator }); return locator;
  }
  public string PreviewLibrary(SessionDefinition scope, string conversationId)
  {
    var path = Locate(scope with { ConversationId = conversationId });
    NoLinks(path);
    var output = new StringBuilder();
    using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite); using var reader = new StreamReader(stream);
    var lines = 0;
    while (!reader.EndOfStream && lines++ < 1000 && output.Length < 24000)
    {
      var line = reader.ReadLine(); if (line is null) break;
      if (line.Length > 1024 * 1024) continue;
      try
      {
        using var document = JsonDocument.Parse(line); var value = document.RootElement;
        if (value.TryGetProperty("message", out var message) && message.ValueKind == JsonValueKind.Object) value = message;
        if (value.TryGetProperty("payload", out var payload) && payload.ValueKind == JsonValueKind.Object) value = payload;
        var role = value.TryGetProperty("role", out var speaker) && speaker.ValueKind == JsonValueKind.String ? speaker.GetString() : null;
        if (role is not ("user" or "assistant")) continue;
        var text = "";
        if (value.TryGetProperty("content", out var content))
        {
          if (content.ValueKind == JsonValueKind.String) text = content.GetString() ?? "";
          else if (content.ValueKind == JsonValueKind.Array) text = string.Join('\n', content.EnumerateArray().Where(c => c.ValueKind == JsonValueKind.Object && c.TryGetProperty("text", out var t) && t.ValueKind == JsonValueKind.String).Select(c => c.GetProperty("text").GetString()));
        }
        if (text.Length == 0) continue;
        var count = Math.Min(text.Length, 24000 - output.Length); if (count > 0 && count < text.Length && char.IsHighSurrogate(text[count - 1])) count--;
        output.AppendLine(role == "user" ? "You" : "Assistant").AppendLine(text[..count]).AppendLine();
      }
      catch (JsonException) { }
    }
    return output.Length == 0 ? "This transcript contains no supported user or assistant text in its first 1,000 records." : "Read-only transcript excerpt\n\n" + output + "\n[Preview is limited to the first 1,000 records and 24,000 characters.]";
  }
}
