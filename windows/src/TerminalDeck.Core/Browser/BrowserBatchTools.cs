using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Browser;

public static class BrowserParityContracts
{
  private static JsonElement Object(JsonObject properties, string[] required) => JsonSerializer.SerializeToElement(new JsonObject { ["type"] = "object", ["properties"] = properties, ["required"] = new JsonArray(required.Select(s => (JsonNode)JsonValue.Create(s)!).ToArray()), ["additionalProperties"] = false });
  private static JsonObject String() => new() { ["type"] = "string" };
  private static JsonObject Integer(int min, int max) => new() { ["type"] = "integer", ["minimum"] = min, ["maximum"] = max };
  private static JsonObject Fields(bool step)
  {
    var fields = new JsonObject { ["window"] = String(), ["sessionId"] = String(), ["selector"] = String(), ["frame"] = String(), ["within"] = String(), ["timeoutMs"] = Integer(1, 30000) };
    if (step)
    {
      fields["verb"] = new JsonObject { ["type"] = "string", ["enum"] = new JsonArray("click", "type", "select", "check", "press", "submit") };
      fields["value"] = String(); fields["key"] = new JsonObject { ["type"] = "string", ["enum"] = new JsonArray("Enter", "Tab", "Escape", "Backspace", "Delete", "ArrowDown", "ArrowUp", "ArrowLeft", "ArrowRight") }; fields["nth"] = Integer(0, 5000);
    }
    else { fields["waitFor"] = String(); fields["waitText"] = String(); fields["waitUrl"] = String(); fields["offset"] = Integer(0, 5000); fields["limit"] = Integer(1, 200); fields["textChars"] = Integer(1, 30000); }
    return fields;
  }
  private static readonly JsonElement ReadSchema = Object(Fields(false), []);
  private static readonly JsonElement StepSchema = Object(Fields(true), ["verb", "selector"]);
  private static JsonElement BatchSchema()
  {
    var item = Fields(true); item.Remove("window"); item.Remove("sessionId");
    item["action"] = new JsonObject { ["type"] = "string", ["enum"] = new JsonArray("read", "step") };
    foreach (var field in Fields(false).Where(p => p.Key is not ("window" or "sessionId"))) if (!item.ContainsKey(field.Key)) item[field.Key] = field.Value?.DeepClone();
    return Object(new JsonObject { ["window"] = String(), ["sessionId"] = String(), ["steps"] = new JsonObject { ["type"] = "array", ["minItems"] = 1, ["maxItems"] = 20, ["items"] = JsonNode.Parse(Object(item, ["action"]).GetRawText()) } }, ["steps"]);
  }
  private static readonly JsonElement UploadSchema = Object(new JsonObject { ["window"] = String(), ["sessionId"] = String(), ["selector"] = String(), ["paths"] = new JsonObject { ["type"] = "array", ["minItems"] = 1, ["maxItems"] = 8, ["items"] = String() } }, ["selector", "paths"]);
  public static IReadOnlyList<McpToolSpec> Specs { get; } = [new("browser.upload", "browser_upload", McpTier.Act, UploadSchema), new("browser.read", "browser_read", McpTier.Read, ReadSchema), new("browser.step", "browser_step", McpTier.Act, StepSchema), new("browser.batch", "browser_batch", McpTier.Act, BatchSchema())];
}

public static partial class BrowserTools
{
  private static void RegisterBatch(McpDoor door, BrowserModel browser)
  {
    door.Register("browser.upload", async (caller, args, ct) =>
    {
      var tab = Resolve(caller, args, browser)!; caller.Require("profiles", tab.ProfileId); RequireOrigin(caller, tab.Url);
      var paths = args.GetProperty("paths").EnumerateArray().Select(p => Path.GetFullPath(p.GetString() ?? "")).ToArray();
      if (paths.Length is < 1 or > 8) throw new McpRefusal("Upload one to eight files.");
      long total = 0;
      foreach (var path in paths)
      {
        caller.Require("files", path);
        var file = new FileInfo(path);
        if (!file.Exists || file.Length > 50_000_000 || (total += file.Length) > 100_000_000) throw new McpRefusal("Choose existing files, up to 50 MB each and 100 MB in total.");
      }
      await caller.EnsureCurrentAsync(ct); browser.SetDriver(tab.Id, browser.ResolveDriverName(caller.Grant));
      var result = await browser.PerformAsync(tab.Id, BrowserPageAction.Upload, JsonSerializer.SerializeToElement(new { selector = DeckCoreTools.Required(args, "selector"), paths }), ct);
      if (result.TryGetProperty("url", out var url)) RequireOrigin(caller, url.GetString()!);
      await caller.EnsureCurrentAsync(ct); return result;
    });
    door.Register("browser.batch", async (caller, args, ct) =>
    {
      var tab = Resolve(caller, args, browser)!;
      caller.Require("profiles", tab.ProfileId); RequireOrigin(caller, tab.Url);
      var steps = args.GetProperty("steps");
      if (steps.ValueKind != JsonValueKind.Array || steps.GetArrayLength() is < 1 or > 20) throw new McpRefusal("Use one to 20 browser steps.");
      browser.SetDriver(tab.Id, browser.ResolveDriverName(caller.Grant));
      using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(60));
      var results = new List<JsonElement>(); var at = 0;
      foreach (var step in steps.EnumerateArray())
      {
        await caller.EnsureCurrentAsync(deadline.Token); RequireOrigin(caller, browser.Get(tab.Id).Url);
        var action = DeckCoreTools.Required(step, "action") switch { "read" => BrowserPageAction.Read, "step" => BrowserPageAction.Step, _ => throw new McpRefusal("A batch item is read or step.") };
        try
        {
          var result = await browser.PerformAsync(tab.Id, action, step, deadline.Token);
          if (result.TryGetProperty("url", out var url)) RequireOrigin(caller, url.GetString()!);
          await caller.EnsureCurrentAsync(deadline.Token); results.Add(result); at++;
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex) when (ex is ArgumentException or InvalidOperationException)
        {
          return JsonSerializer.SerializeToElement(new { done = false, completed = at, failedIndex = at, message = ex.Message, results });
        }
      }
      return JsonSerializer.SerializeToElement(new { done = true, completed = at, results });
    });
  }
}
