using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace TerminalDeck.Core.Receiver;

public static class ReceiverPayloadMapper
{
  public static ReceiverMappedPayload[] Map(ReceiverWebhook input, ReceiverPayloadMapping mapping)
  {
    if (input.Body.Length > 80 * 1024) throw new ArgumentException("Receiver payloads can be at most 80 KB.");
    JsonDocument document;
    try { document = JsonDocument.Parse(input.Body, new JsonDocumentOptions { MaxDepth = 32 }); }
    catch (JsonException)
    {
      var contentType = input.Headers.FirstOrDefault(p => p.Key.Equals("content-type", StringComparison.OrdinalIgnoreCase)).Value ?? "";
      var text = new System.Text.UTF8Encoding(false, true).GetString(input.Body);
      if (contentType.Contains("json", StringComparison.OrdinalIgnoreCase) || text.TrimStart().StartsWith('{') || text.TrimStart().StartsWith('[')) throw;
      document = JsonDocument.Parse(JsonSerializer.SerializeToUtf8Bytes(new { text, message = text, body = text }));
    }
    using var owned = document; var root = document.RootElement;
    var split = string.IsNullOrWhiteSpace(mapping.Split) ? default : At(root, mapping.Split);
    var items = split.ValueKind == JsonValueKind.Array ? split.EnumerateArray().Take(101).ToArray() : new[] { root };
    if (items.Length > 100) throw new ArgumentException("One webhook can contain at most 100 events.");
    return items.Select(item =>
    {
      var context = root.ValueKind == JsonValueKind.Object ? JsonNode.Parse(root.GetRawText())!.AsObject() : new JsonObject { ["body"] = JsonNode.Parse(root.GetRawText()) };
      context["item"] = JsonNode.Parse(item.GetRawText()); context["header"] = JsonSerializer.SerializeToNode(input.Headers.ToDictionary(p => p.Key.ToLowerInvariant(), p => p.Value)); context["meta"] = new JsonObject { ["clientIp"] = input.ClientIp };
      string Render(string slot, string template) => Template(mapping.Overrides?.GetValueOrDefault(slot) ?? template, JsonSerializer.SerializeToElement(context));
      var kind = Render("kind", mapping.Kind); context["kind"] = kind;
      var fields = (mapping.Fields ?? []).ToDictionary(p => p.Key, p => Render("fields." + p.Key, p.Value)); context["fields"] = JsonSerializer.SerializeToNode(fields);
      var payload = JsonSerializer.SerializeToElement(context);
      var ignored = (mapping.Ignore ?? []).Any(condition => ReceiverConditions.Matches(new(input.SourceId, "", "") { Payload = payload }, [condition]));
      var severity = Render("severity", mapping.Severity); var title = Render("title", mapping.Title); var text = Render("text", mapping.Text); var time = Render("time", mapping.Time); var upstream = Render("upstreamId", mapping.UpstreamId);
      var kept = new JsonObject { ["kind"] = kind, ["severity"] = severity, ["title"] = title, ["text"] = text, ["time"] = time, ["fields"] = JsonSerializer.SerializeToNode(fields), ["payload"] = JsonNode.Parse(root.GetRawText()), ["header"] = context["header"]?.DeepClone(), ["meta"] = context["meta"]?.DeepClone(), ["receiverNormalized"] = true };
      if (split.ValueKind == JsonValueKind.Array) kept["item"] = JsonNode.Parse(item.GetRawText());
      return new ReceiverMappedPayload(kind, severity, title, text, time, upstream, fields, JsonSerializer.SerializeToElement(kept), ignored);
    }).ToArray();
  }
  public static string Template(string template, JsonElement context, bool jsonEscape = false)
  {
    if (template.Length > 8000) throw new ArgumentException("Keep Receiver templates below 8 KB.");
    return Regex.Replace(template, @"\{\{([^{}]{1,1000})\}\}", match =>
    {
      string text = "";
      foreach (var choice in Alternatives(match.Groups[1].Value))
      {
        if (choice.Length >= 2 && choice[0] == '"' && choice[^1] == '"') { text = JsonSerializer.Deserialize<string>(choice) ?? ""; break; }
        var value = At(context, choice); if (value.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null) continue;
        text = value.ValueKind == JsonValueKind.String ? value.GetString()! : value.GetRawText(); if (text.Length > 0) break;
      }
      return jsonEscape ? JsonSerializer.Serialize(text)[1..^1] : text;
    }, RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(100));
  }
  private static IEnumerable<string> Alternatives(string expression)
  {
    var start = 0; var quoted = false; var escaped = false;
    for (var i = 0; i < expression.Length; i++)
    {
      var c = expression[i]; if (escaped) { escaped = false; continue; } if (c == '\\' && quoted) { escaped = true; continue; } if (c == '\"') quoted = !quoted;
      if (c == '|' && !quoted) { yield return expression[start..i].Trim(); start = i + 1; }
    }
    yield return expression[start..].Trim();
  }
  public static JsonElement At(JsonElement value, string path)
  {
    foreach (var part in path.Trim().TrimStart('$', '.').Replace("[", ".", StringComparison.Ordinal).Replace("]", "", StringComparison.Ordinal).Split('.', StringSplitOptions.RemoveEmptyEntries))
      if (value.ValueKind == JsonValueKind.Object && value.TryGetProperty(part, out var property)) value = property;
      else if (value.ValueKind == JsonValueKind.Array && int.TryParse(part, out var index) && index >= 0 && index < value.GetArrayLength()) value = value[index]; else return default;
    return value;
  }
}
