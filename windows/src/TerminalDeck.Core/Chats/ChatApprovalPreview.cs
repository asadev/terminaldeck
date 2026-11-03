using System.Text.Json;

namespace TerminalDeck.Core.Chats;

public sealed record ChatApprovalPreview(string? Path, string? Before, string? After, string? Patch, bool Truncated)
{
  public bool HasPreview => Before is not null || After is not null || Patch is not null;
  public static ChatApprovalPreview Read(string arguments)
  {
    try
    {
      using var document = JsonDocument.Parse(arguments); var input = document.RootElement;
      for (var depth = 0; depth < 3 && input.ValueKind == JsonValueKind.Object && input.TryGetProperty("input", out var nested) && nested.ValueKind == JsonValueKind.Object; depth++) input = nested;
      string? Field(params string[] names)
      {
        foreach (var name in names)
          if (input.ValueKind == JsonValueKind.Object && input.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String) return value.GetString();
        return null;
      }
      var path = Field("file_path", "filePath", "path"); var before = Field("old_string", "oldText"); var after = Field("new_string", "newText", "content"); var patch = Field("diff", "patch");
      var truncated = new[] { before, after, patch }.Any(t => t?.Length > 20000);
      string? Bound(string? text) => text is { Length: > 20000 } ? text[..20000] : text;
      return new(path, Bound(before), Bound(after), Bound(patch), truncated);
    }
    catch (JsonException) { return new(null, null, null, null, false); }
  }
}
