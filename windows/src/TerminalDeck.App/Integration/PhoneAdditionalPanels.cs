using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private PhonePanelOwner[] PhoneAdditionalPanels() => [
    PhoneHooksPanel(),
    new("mcp", true, async (device, request, ct) =>
    {
      var rows = new JsonArray();
      foreach (var server in (await Mcp.ListAsync(ct)).Take(200)) rows.Add(new JsonObject { ["id"] = server.Id, ["title"] = server.Name,
        ["detail"] = server.Scope + " · " + server.Transport, ["value"] = server.Connected ? "Connected" : server.Enabled ? "Ready" : "Off",
        ["actions"] = new JsonArray(PanelAction(server.Connected ? "disconnect" : "connect", server.Connected ? "Disconnect" : "Connect"), PanelAction(server.Enabled ? "disable" : "enable", server.Enabled ? "Turn off" : "Turn on")) });
      return Panel("MCP servers", rows);
    }, async (device, request, ct) =>
    {
      await RequirePhoneCurrentAsync(device, ct); var id = PanelText(request, "id")!; var action = PanelText(request, "action")!;
      if (action == "connect") await Mcp.ConnectAsync(id, ct);
      else if (action == "disconnect") await Mcp.DisconnectAsync(id, ct);
      else await Mcp.EditPatchAsync(id, JsonSerializer.SerializeToElement(new { enabled = action == "enable" }), ct);
    }),
    new("ai-apps", true, (device, request, ct) => ValueTask.FromResult(Panel("Coding AIs", new JsonArray(Accounts.List().Take(100).Select(a => (JsonNode)new JsonObject
    { ["id"] = a.Id, ["title"] = a.Name, ["detail"] = a.Provider, ["value"] = a.SignedIn ? "Signed in" : "Signed out", ["actions"] = new JsonArray(PanelAction(a.SignedIn ? "signout" : "signin", a.SignedIn ? "Sign out" : "Sign in")) }).ToArray()))),
      async (device, request, ct) =>
      {
        await RequirePhoneCurrentAsync(device, ct); var id = PanelText(request, "id")!;
        if (PanelText(request, "action") == "signout") await Accounts.SignOutAsync(id, ct);
        else await Accounts.SignInAsync(id, Hoot.Read().Settings?.Folder ?? Root.DirectoryPath, ct);
      }),
    new("connected-tasks", false, async (device, request, ct) =>
    {
      var rows = new JsonArray(); var scope = PanelText(request, "scope");
      foreach (var system in ConnectedTasks.Systems().Where(s => PhoneProjectAllowed(device, s.ProjectId) && (scope is null || scope == s.Id)).Take(20))
        foreach (var task in (await ConnectedTasks.ListAsync(system.Id, PanelText(request, "query") ?? "", ct: ct)).Take(100))
          rows.Add(new JsonObject { ["id"] = system.Id + ":" + task.Id, ["title"] = task.Title, ["detail"] = task.Status, ["group"] = system.Name, ["body"] = task.Details[..Math.Min(task.Details.Length, 2000)] });
      return Panel("Connected tasks", rows);
    }),
    PhoneStorePanel("plugins", "Browser tools"),
    new("settings", true, async (device, request, ct) =>
    {
      var reply = await PhoneManagementMessageAsync(device, "settings.read", JsonSerializer.SerializeToElement(new { }), "panel", ct);
      var rows = new JsonArray((reply["settings"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().Select(setting => (JsonNode)new JsonObject { ["id"] = setting["key"]!.GetValue<string>(),
        ["title"] = setting["key"]!.GetValue<string>() == "agents.defaultProvider" ? "Default coding AI" : "Restore sessions at launch", ["value"] = setting["value"]!.GetValue<string>(),
        ["actions"] = setting["options"] is JsonArray choices ? new JsonArray(choices.Select(v => (JsonNode)PanelAction("provider:" + v!.GetValue<string>(), v.GetValue<string>())).ToArray()) : new JsonArray() }).ToArray());
      return Panel("Computer settings", rows);
    }, async (device, request, ct) =>
    {
      await RequirePhoneCurrentAsync(device, ct); var action = PanelText(request, "action")!;
      await PhoneManagementMessageAsync(device, "settings.apply", JsonSerializer.SerializeToElement(new { key = "agents.defaultProvider", value = action[9..] }), "panel", ct);
    })
  ];
}
