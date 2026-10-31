using System.Text.Json;

namespace TerminalDeck.Core.Mcp;

public sealed class McpRefusal(string message) : InvalidOperationException(message);

public static class McpSchema
{
  public static void Validate(JsonElement schema, JsonElement value, int depth = 0)
  {
    if (depth > 32 || schema.ValueKind != JsonValueKind.Object) throw new McpRefusal("The tool arguments are too deeply nested.");
    if (schema.TryGetProperty("type", out var type))
    {
      bool Matches(JsonElement candidate) => candidate.GetString() switch
      {
        "null" => value.ValueKind == JsonValueKind.Null,
        "object" => value.ValueKind == JsonValueKind.Object,
        "array" => value.ValueKind == JsonValueKind.Array,
        "string" => value.ValueKind == JsonValueKind.String,
        "boolean" => value.ValueKind is JsonValueKind.True or JsonValueKind.False,
        "integer" => value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out _),
        "number" => value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var n) && double.IsFinite(n),
        _ => false
      };
      var valid = type.ValueKind == JsonValueKind.Array ? type.EnumerateArray().Any(Matches) : Matches(type);
      if (!valid) throw new McpRefusal("The tool arguments have the wrong type.");
    }
    if (schema.TryGetProperty("enum", out var choices) && !choices.EnumerateArray().Any(c => JsonElement.DeepEquals(c, value)))
      throw new McpRefusal("Choose one of the tool's listed actions or values.");
    if (value.ValueKind == JsonValueKind.Object)
    {
      if (value.EnumerateObject().Select(p => p.Name).Distinct().Count() != value.EnumerateObject().Count()) throw new McpRefusal("A tool argument was repeated.");
      if (schema.TryGetProperty("required", out var required))
        foreach (var field in required.EnumerateArray()) if (!value.TryGetProperty(field.GetString()!, out _)) throw new McpRefusal("A required tool argument is missing.");
      var properties = schema.TryGetProperty("properties", out var p) ? p : default;
      foreach (var field in value.EnumerateObject())
      {
        if (properties.ValueKind == JsonValueKind.Object && properties.TryGetProperty(field.Name, out var child)) Validate(child, field.Value, depth + 1);
        else if (schema.TryGetProperty("additionalProperties", out var extra) && extra.ValueKind == JsonValueKind.False) throw new McpRefusal("An unexpected tool argument was supplied.");
      }
    }
    if (value.ValueKind == JsonValueKind.Array && schema.TryGetProperty("items", out var item)) foreach (var element in value.EnumerateArray()) Validate(item, element, depth + 1);
    if (value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number) &&
      (schema.TryGetProperty("minimum", out var minimum) && number < minimum.GetDouble() ||
       schema.TryGetProperty("maximum", out var maximum) && number > maximum.GetDouble()))
      throw new McpRefusal("Choose a tool argument within its allowed range.");
    if (value.ValueKind == JsonValueKind.String && schema.TryGetProperty("maxLength", out var max) && value.GetString()!.Length > max.GetInt32()) throw new McpRefusal("A tool argument is too long.");
  }
}
