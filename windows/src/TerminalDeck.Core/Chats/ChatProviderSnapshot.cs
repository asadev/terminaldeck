using System.Text.Json;
namespace TerminalDeck.Core.Chats;

public sealed record ChatProviderReading(bool Current, string? Model, JsonElement? Fields, DateTimeOffset At, DateTimeOffset? ModelAt = null);
public static class ChatProviderSnapshot
{
  public static JsonElement Capture(string provider, string creationKey, JsonElement source)
  {
    var fields = new Dictionary<string, JsonElement>();
    foreach (var name in new[] { "model", "permissionMode", "approvalPolicy", "sandbox", "sandboxPolicy", "workspaceTrust", "networkAccess", "cwd", "instructionSources", "slash_commands", "tools" })
      if (source.ValueKind == JsonValueKind.Object && source.TryGetProperty(name, out var value)) fields[name] = value.Clone();
    if (!fields.ContainsKey("networkAccess") && fields.TryGetValue("sandboxPolicy", out var policy) && policy.ValueKind == JsonValueKind.Object && policy.TryGetProperty("networkAccess", out var network)) fields["networkAccess"] = network.Clone();
    foreach (var name in new[] { "mcp_servers", "skills", "plugins" })
      if (source.ValueKind == JsonValueKind.Object && source.TryGetProperty(name, out var values) && values.ValueKind == JsonValueKind.Array)
      {
        var safe = values.EnumerateArray().Select(value =>
        {
          if (value.ValueKind != JsonValueKind.Object) return value.Clone();
          var item = new Dictionary<string, JsonElement>();
          foreach (var key in new[] { "name", "id", "status", "description", "path", "source", "command", "authStatus", "terminalOnly", "supportsChat", "control", "argumentHint" })
            if (value.TryGetProperty(key, out var content)) item[key] = content.Clone();
          return JsonSerializer.SerializeToElement(item);
        }).ToArray(); fields[name] = JsonSerializer.SerializeToElement(safe);
      }
    return JsonSerializer.SerializeToElement(new { provider, creationKey, fields });
  }
  public static ChatProviderReading Read(ChatRecord chat)
  {
    var entry = chat.Events.LastOrDefault(e => e.Kind == "providerInit");
    var data = entry?.Data ?? default;
    var current = ChatLineProtocol.S(data, "creationKey") == chat.CreationKey;
    var fields = current ? ChatLineProtocol.P(data, "fields") : default;
    var reported = chat.Events.LastOrDefault(e => e.Kind is "requestStarted" or "requestUsage" && e.Data is { } request && ChatLineProtocol.S(request, "creationKey") == chat.CreationKey && RealModel(ChatLineProtocol.S(request, "model")));
    var model = reported?.Data is { } reading ? ChatLineProtocol.S(reading, "model") : ChatLineProtocol.S(fields, "model");
    return new(current || reported is not null, model.Length > 0 ? model : null, fields.ValueKind == JsonValueKind.Object ? fields : null, entry?.At ?? default, reported?.At ?? (current ? entry?.At : null));
  }

  // Claude reports "<synthetic>" for its own error messages (e.g. a usage limit); that is not a model.
  private static bool RealModel(string model) => model.Length > 0 && !(model.StartsWith('<') && model.EndsWith('>'));

  public static string Describe(ChatProviderReading reading, string field)
  {
    if (!reading.Current || reading.Fields is not { } fields || !(fields.TryGetProperty(field, out var value) || field == "sandboxPolicy" && fields.TryGetProperty("sandbox", out value)) || value.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined) return "Not reported";
    return value.ValueKind == JsonValueKind.String ? value.GetString()! : JsonSerializer.Serialize(value, new JsonSerializerOptions { WriteIndented = true });
  }
}
