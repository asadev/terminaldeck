using System.Text.Json;
using TerminalDeck.Core.Browser;

namespace TerminalDeck.App.Views;

public sealed partial class BrowserPane
{
  private async Task<JsonElement> EvaluateStoreRecipeAsync(BrowserTab tab, string recipe, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested();
    var frames = await tab.Model.CommandAsync("Page.getFrameTree", new { });
    var frame = frames.GetProperty("frameTree").GetProperty("frame").GetProperty("id").GetString();
    var world = await tab.Model.CommandAsync("Page.createIsolatedWorld", new { frameId = frame, worldName = "deck-store-tools" });
    var result = await tab.Model.CommandAsync("Runtime.evaluate", new {
      expression = BrowserRecipes.Script(recipe),
      contextId = world.GetProperty("executionContextId").GetInt32(), returnByValue = true
    });
    ct.ThrowIfCancellationRequested();
    if (result.TryGetProperty("exceptionDetails", out _)) throw new InvalidOperationException("Browser extraction failed.");
    return result.GetProperty("result").GetProperty("value").Clone();
  }
}
