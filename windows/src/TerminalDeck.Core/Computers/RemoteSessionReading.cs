using System.Text.Json;

namespace TerminalDeck.Core.Computers;

public sealed record RemoteControlChoice(string Id, string Name);
public static class RemoteSessionReading
{
  public static JsonElement Field(JsonElement value, string name) => value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var result) ? result : default;
  public static string Text(JsonElement value, string name, string fallback = "") => Field(value, name) is { ValueKind: JsonValueKind.String } result ? result.GetString() ?? fallback : fallback;
  public static IReadOnlyList<JsonElement> Rows(JsonElement value, string name) => Field(value, name) is { ValueKind: JsonValueKind.Array } rows ? rows.EnumerateArray().Select(r => r.Clone()).ToArray() : [];
  public static string ControlLabel(JsonElement response, string name)
  {
    var options = Field(response, "options"); var reading = Field(response, "reading"); var control = Field(reading, name);
    var value = Text(options, name, Text(control, "label", Text(control, "value")));
    return string.IsNullOrWhiteSpace(value) || value.Equals("unknown", StringComparison.OrdinalIgnoreCase) ? char.ToUpperInvariant(name[0]) + name[1..] : value;
  }
  public static IReadOnlyList<RemoteControlChoice> Choices(JsonElement response, string name)
  {
    var options = Field(response, "options"); var control = Field(Field(response, "reading"), name);
    var choices = Rows(options, name == "model" ? "models" : "efforts");
    if (choices.Count == 0) choices = Rows(control, "choices");
    if (choices.Count == 0) choices = Rows(control, "options");
    return choices.Take(100).Select(choice => choice.ValueKind == JsonValueKind.String ? new RemoteControlChoice(choice.GetString()!, choice.GetString()!) : new RemoteControlChoice(Text(choice, "id", Text(choice, "value")), Text(choice, "name", Text(choice, "label", Text(choice, "id", Text(choice, "value")))))).Where(c => c.Id.Length > 0).ToArray();
  }
  public static string AccountName(JsonElement account)
  {
    var value = Text(account, "name", Text(account, "email", "AI account")); var at = value.IndexOf('@'); return at > 0 ? value[..at] : value;
  }
}
