using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  private void InitializePhoneManagementTools()
  {
    foreach (var spec in PhoneManagementTools.Specs.Where(s => s.Id != "hoot.routines.manage"))
      Door.Register(spec.Id, async (context, args, ct) =>
      {
        context.Require("settings", "remote");
        var type = args.GetProperty("type").GetString()!;
        if (args.TryGetProperty("id", out var id) && type.StartsWith("controls.", StringComparison.Ordinal)) context.Require("sessions", id.GetString()!);
        if (args.TryGetProperty("accountId", out var account)) context.Require("accounts", account.GetString()!);
        if (args.TryGetProperty("folder", out var folder)) context.Require("folders", folder.GetString()!);
        await context.EnsureCurrentAsync(ct);
        var device = context.Grant.DeviceId is { } deviceId ? Remote.Trust.List().FirstOrDefault(d => d.Id == deviceId && d.Access == PhoneAccess.Full)
          ?? throw new McpRefusal("This device cannot manage its host.") : new ApprovedDevice("mcp:" + context.Grant.CallerId, "Approved app caller", "mcp", PhoneAccess.Full);
        var frame = JsonNode.Parse(args.GetRawText())!.AsObject(); frame["t"] = type; frame["rid"] = Guid.NewGuid().ToString("N");
        using var request = JsonDocument.Parse(frame.ToJsonString());
        return JsonSerializer.SerializeToElement(await PhoneManagementWithAuthorityAsync(device, type, request.RootElement, frame["rid"]!.GetValue<string>(), ct, context.EnsureCurrentAsync));
      });
    Door.Register("hoot.routines.manage", async (context, args, ct) =>
    {
      context.Require("hoot", "main"); context.Require("settings", "remote"); await context.EnsureCurrentAsync(ct);
      var id = args.GetProperty("id").GetString()!;
      if (Routines.List().FirstOrDefault(r => r.Id == id) is { } prior)
      { context.Require("folders", prior.Folder); if (prior.AgentId != "@hoot") context.Require("agents", prior.AgentId); }
      if (args.GetProperty("action").GetString() == "run") await Routines.RunAsync(id, ct);
      else if (args.GetProperty("action").GetString() == "stop") await Routines.StopAsync(id, ct);
      else if (args.GetProperty("action").GetString() == "keep-unconfirmed") Routines.KeepUnconfirmed(id);
      else if (args.GetProperty("action").GetString() == "remove") Routines.Remove(id);
      else
      {
        var folder = args.GetProperty("folder").GetString()!; context.Require("folders", folder);
        Routines.Save(new(id, args.GetProperty("name").GetString()!, args.TryGetProperty("purpose", out var purpose) ? purpose.GetString()! : "", folder,
          args.GetProperty("everyMinutes").GetInt32(), args.GetProperty("text").GetString()!, args.TryGetProperty("enabled", out var enabled) && enabled.GetBoolean()));
      }
      return JsonSerializer.SerializeToElement(Routines.List().Where(r => context.Has("folders", r.Folder)));
    });
  }
}
