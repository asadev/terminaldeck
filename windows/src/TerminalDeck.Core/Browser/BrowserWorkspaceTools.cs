using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Browser;

public static class BrowserWorkspaceTools
{
  private static readonly JsonElement Schema = JsonSerializer.SerializeToElement(new
  {
    type = "object", properties = new
    {
      window = new { type = "string" }, command = new { type = "string" }, text = new { type = "string" },
      id = new { type = "string" },
      tool = new { type = "string", @enum = new[] { "Draw", "Box", "Arrow", "Text" } },
      points = new { type = "array", minItems = 1, maxItems = 20000, items = new { type = "object", properties = new { x = new { type = "number", minimum = 0, maximum = 1 }, y = new { type = "number", minimum = 0, maximum = 1 } }, required = new[] { "x", "y" }, additionalProperties = false } },
      profile = new { type = "string" }, isolated = new { type = "boolean" }
    }, required = new[] { "command" }, additionalProperties = false
  });
  public static IReadOnlyList<McpToolSpec> Specs { get; } = [
    new("browser.workspace.read", "browser_workspace_read", McpTier.Read, Schema),
    new("browser.workspace.change", "browser_workspace_change", McpTier.Alter, Schema)
  ];
  public static void RegisterIfComposed(McpDoor door, BrowserModel browser)
  {
    // The shell lane owns catalogue composition. Missing composition must stay
    // explicit in the handoff instead of advertising an uncallable tool.
    if (!McpCatalogue.Load().Any(s => s.Id == Specs[0].Id)) return;
    foreach (var spec in Specs)
      door.Register(spec.Id, async (caller, args, ct) =>
      {
        caller.Require("settings", "browser");
        var command = DeckCoreTools.Required(args, "command");
        var profile = DeckCoreTools.Text(args, "profile") ?? browser.Read().ActiveProfileId; caller.Require("profiles", profile);
        if (spec.Tier == McpTier.Read)
        {
          if (command == "history") return JsonSerializer.SerializeToElement(browser.History(profile, DeckCoreTools.Text(args, "text") ?? "").Where(v => caller.Has("origins", new Uri(v.Url).GetLeftPart(UriPartial.Authority))));
          if (command == "settings") return JsonSerializer.SerializeToElement(new { startUrl = browser.Read().StartUrl, viewports = BrowserViewport.Presets });
        }
        else
        {
          await caller.EnsureCurrentAsync(ct);
          if (command is "historyForget" or "historyClear")
          {
            var affected = browser.History(profile, DeckCoreTools.Text(args, "text") ?? "")
              .Where(v => command == "historyClear" || v.Id == DeckCoreTools.Required(args, "id")).ToArray();
            foreach (var visit in affected) caller.Require("origins", new Uri(visit.Url).GetLeftPart(UriPartial.Authority));
            await caller.EnsureCurrentAsync(ct);
            await browser.ForgetHistoryAsync(profile, command == "historyForget" ? DeckCoreTools.Required(args, "id") : null, DeckCoreTools.Text(args, "text"), ct);
            return JsonSerializer.SerializeToElement(new { saved = true });
          }
          if (command == "startUrl")
          {
            var url = DeckCoreTools.Required(args, "text"); var address = BrowserModel.Address(url);
            if (address.Scheme is "http" or "https") caller.Require("origins", address.GetLeftPart(UriPartial.Authority));
            await browser.SetStartUrlAsync(url, ct); return JsonSerializer.SerializeToElement(new { saved = true });
          }
        }
        var tab = browser.Get(DeckCoreTools.Required(args, "window")); caller.Require("browser", tab.Id); caller.Require("profiles", tab.ProfileId);
        if (tab.SessionId is { } session) caller.Require("sessions", session);
        var origin = BrowserModel.Address(tab.Url);
        if (origin.Scheme is "http" or "https") caller.Require("origins", origin.GetLeftPart(UriPartial.Authority));
        if (spec.Tier == McpTier.Alter && command == "takeover")
        { await browser.TakeHumanControlAsync(tab.Id, ct); return JsonSerializer.SerializeToElement(new { done = true }); }
        if (spec.Tier == McpTier.Alter && command == "store")
        {
          await browser.ChangeStoreAsync(tab.Id, profile, args.TryGetProperty("isolated", out var isolated) && isolated.GetBoolean(), ct);
          return JsonSerializer.SerializeToElement(browser.Get(tab.Id));
        }
        if (command is "downloads" or "downloadStop" or "downloadClear" or "drawing") caller.Require("files", "*");
        if (command == "home")
        {
          var home = BrowserModel.Address(browser.Read().StartUrl);
          if (home.Scheme is "http" or "https") caller.Require("origins", home.GetLeftPart(UriPartial.Authority));
        }
        await caller.EnsureCurrentAsync(ct);
        return await browser.PerformAsync(tab.Id, spec.Tier == McpTier.Read ? BrowserPageAction.WorkspaceRead : BrowserPageAction.WorkspaceChange, args, ct);
      });
  }
}
