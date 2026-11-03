using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Browser;

namespace TerminalDeck.App.Views;

public sealed partial class BrowserPane
{
  // Page.createIsolatedWorld names an actual CDP frame, including frames whose
  // document the top page cannot access. No page-supplied JavaScript is run.
  private static async Task<JsonElement> EvaluateFrameDomAsync(BrowserTab tab, JsonElement args, bool step, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested();
    var tree = await tab.Model.CommandAsync("Page.getFrameTree", new { });
    var frames = new List<JsonObject>();
    void Visit(JsonElement node, string? parent, int depth)
    {
      if (frames.Count >= 64 || depth > 16) return;
      var frame = node.GetProperty("frame"); var id = frame.GetProperty("id").GetString()!;
      frames.Add(new() { ["id"] = id, ["parent"] = parent, ["depth"] = depth, ["url"] = frame.GetProperty("url").GetString(), ["name"] = frame.TryGetProperty("name", out var name) ? name.GetString() : "" });
      if (node.TryGetProperty("childFrames", out var children)) foreach (var child in children.EnumerateArray()) Visit(child, id, depth + 1);
    }
    Visit(tree.GetProperty("frameTree"), null, 0);
    var wanted = args.TryGetProperty("frame", out var selected) && selected.ValueKind == JsonValueKind.String ? selected.GetString() : null;
    var expression = step ? BrowserDomAutomation.Step(args) : BrowserDomAutomation.Read(args);
    JsonElement response;
    if (wanted is { Length: > 0 })
    {
      if (!frames.Any(f => f["id"]?.GetValue<string>() == wanted)) throw new InvalidOperationException("Choose a frame id from the current browser.read result.");
      var world = await tab.Model.CommandAsync("Page.createIsolatedWorld", new { frameId = wanted, worldName = "terminaldeck-dom" });
      response = await tab.Model.CommandAsync("Runtime.evaluate", new { expression, contextId = world.GetProperty("executionContextId").GetInt32(), returnByValue = true });
    }
    else response = await tab.Model.CommandAsync("Runtime.evaluate", new { expression, returnByValue = true });
    ct.ThrowIfCancellationRequested();
    if (response.TryGetProperty("exceptionDetails", out _)) throw new InvalidOperationException("The element could not be used in this frame. Refresh browser.read and choose its current frame and selector.");
    var result = JsonNode.Parse(response.GetProperty("result").GetProperty("value").GetRawText())!.AsObject();
    if (!step) result["frames"] = new JsonArray(frames.Select(f => (JsonNode)f).ToArray());
    if (wanted is not null) result["frame"] = wanted;
    return JsonSerializer.SerializeToElement(result);
  }
}
