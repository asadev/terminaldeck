using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Computers;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.App.Integration;

public static class OtherComputersServiceTools
{
  public static void Register(McpDoor door, OtherComputersService computers)
  {
    door.Register("computers.services", async (context, args, ct) =>
    {
      context.Require("settings", "devices");
      var id = args.GetProperty("computerId").GetString()!; context.Require("computers", id);
      await context.EnsureCurrentAsync(ct);
      var action = args.GetProperty("action").GetString()!;
      var fields = args.TryGetProperty("fields", out var f) ? JsonNode.Parse(f.GetRawText()) as JsonObject ?? throw new McpRefusal("fields must be an object.") : new JsonObject();
      if (ComputerOperations.All.ContainsKey(action)) return await computers.OperateAsync(id, action, fields, ct);
      string Text(string key) => fields[key]?.GetValue<string>() is { Length: > 0 } text ? text : throw new McpRefusal("Supply " + key + ".");
      int Number(string key, int fallback) => fields[key]?.GetValue<int>() ?? fallback;
      switch (action)
      {
        case "clipboard-read": return JsonSerializer.SerializeToElement(new { text = await computers.ReadClipboardAsync(id, ct) });
        case "clipboard-write": await computers.WriteClipboardAsync(id, Text("text"), ct); break;
        case "look": return JsonSerializer.SerializeToElement(computers.Services(id));
        case "attach": await computers.AttachAsync(id, Text("id"), Number("cols", 120), Number("rows", 30), ct); break;
        case "detach": await computers.DetachAsync(id, Text("id")); break;
        case "input":
          var data = Text("data"); if (Encoding.UTF8.GetByteCount(data) > 65536) throw new McpRefusal("Send at most 64 KB at once.");
          await computers.SendAsync(id, new { t = "input", id = Text("id"), data }, ct); break;
        case "keys":
          if (fields["keys"] is not JsonArray keys) throw new McpRefusal("Supply the keys array.");
          await computers.SendAsync(id, new { t = "input", id = Text("id"), data = ComputerSessionKeys.Encode(keys.Select(k => k?.GetValue<string>() ?? "")) }, ct); break;
        case "resize": await computers.SendAsync(id, new { t = "resize", id = Text("id"), cols = Math.Clamp(Number("cols", 120), 20, 500), rows = Math.Clamp(Number("rows", 30), 5, 200) }, ct); break;
        case "create": return await computers.CreateSessionAsync(id, fields, ct);
        case "close": computers.RequireCapability(id, "close"); await computers.SendAsync(id, new { t = "close", id = Text("id") }, ct); break;
        case "rename": computers.RequireCapability(id, "rename"); await computers.SendAsync(id, new { t = "rename", id = Text("id"), title = Text("title") }, ct); break;
        case "hoot-read": await computers.HootAsync(id, "hoot.attach", ct: ct); break;
        case "hoot-start": await computers.HootAsync(id, "hoot.start", ct: ct); break;
        case "hoot-say": await computers.HootAsync(id, "hoot.say", Text("text"), ct); break;
        case "hoot-detach": await computers.HootAsync(id, "hoot.detach", ct: ct); break;
        case "ports": computers.RequireCapability(id, "localhost"); await computers.SendAsync(id, new { t = "ports" }, ct); break;
        case "open-here": return JsonSerializer.SerializeToElement(new { url = await computers.OpenPortAsync(id, Number("port", 0), ct) });
        case "close-here": await computers.ClosePortAsync(id, Number("port", 0)); break;
        case "open-there":
          computers.RequireCapability(id, "web"); var url = Text("url");
          if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https")) throw new McpRefusal("Supply an http or https URL.");
          await computers.SendAsync(id, new { t = "web.open", url }, ct); break;
        case "upload":
          var path = Path.GetFullPath(Text("path")); context.Require("folders", Path.GetDirectoryName(path)!);
          return await computers.UploadAsync(id, path, fields["dir"]?.GetValue<string>(), ct);
        case "cancel-upload": computers.CancelUpload(id); break;
        default: throw new McpRefusal("Choose a listed computer service action.");
      }
      return JsonSerializer.SerializeToElement(new { sent = true, note = "The remote computer enforces current grants. Await its event or reading to confirm the outcome." });
    });
  }
}
