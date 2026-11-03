using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Usage;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  public PhoneDeferredWorkspace PhoneBrowser { get; } = new();

  private IPhoneHostWorkspace CreatePhoneWorkspace(PhoneSessionsHost host)
  {
    var extended = CreateExtendedPhoneWorkspace(host);
    return new PhoneWorkspaceComposite(
      OtherComputers.CreateClipboardFeature(),
      new PhoneWorkspaceFeatures(host.Folders, PhoneOwnerMessageAsync),
      new PhoneConnectedFeatures(Projects, Agents, Artifacts, (d, p) => d.Access == PhoneAccess.Full || TaskGrants.HasProject(d, p),
        (d, id) => Sessions.Any(s => s.Definition.Id == id && host.Visible(d, s)) || Chats.List().Any(c => c.Definition.Id == id && host.Visible(d, c)), PhoneImageCodec.PngAsync, phoneArtifactServer),
      new PhoneUploadFeatures((device, requested) => PhoneUploadDestination(device, requested, host), completed: phoneUploadedFiles),
      CreateGrantedPhonePorts(host),
      extended, PhoneBrowser);
  }
  private IReadOnlyList<int> ReservedPhonePorts() => new int?[] { LocalToolAddress?.Port, Remote.LocalWebPort, providerHookHost?.Port, phoneArtifactServer?.Port }.Where(p => p is not null).Select(p => p!.Value).Distinct().ToArray();

  private async ValueTask<JsonObject> PhoneOwnerMessageAsync(ApprovedDevice device, string type, JsonElement message, string? rid, CancellationToken ct)
  {
    if (device.Access != PhoneAccess.Full) throw new PhoneRefusal("unauthorized", "This action needs Full control.");
    var reply = new JsonObject { ["rid"] = rid };
    if (type is "devices.list" or "devices.revoke")
    {
      if (type == "devices.revoke")
      {
        var id = PhoneWorkspaceFeatures.Text(message, "device")!;
        Remote.Trust.Revoke(id);
        reply["ok"] = true; reply["message"] = "Device access removed.";
      }
      reply["t"] = type == "devices.list" ? "devices.rows" : "devices.revoked";
      reply["devices"] = new JsonArray(Remote.Trust.List().Concat(Remote.Trust.Pending()).Select(d => (JsonNode)new JsonObject
      {
        ["id"] = d.Id, ["name"] = d.Name, ["kind"] = "mine", ["status"] = Remote.Trust.Pending().Any(p => p.Id == d.Id) ? "pending" : "approved",
        ["platform"] = d.Platform, ["addedAt"] = d.PairedAt?.ToUnixTimeMilliseconds() ?? 0, ["lastSeenAt"] = d.LastSeen?.ToUnixTimeMilliseconds(), ["connected"] = d.Connected, ["fingerprint"] = null
      }).ToArray());
      return reply;
    }
    var sessionId = PhoneWorkspaceFeatures.Text(message, "id")!;
    var host = new PhoneSessionsHost(this);
    var terminal = Sessions.FirstOrDefault(s => s.Definition.Id == sessionId && host.Visible(device, s));
    var chat = Chats.List().FirstOrDefault(c => c.Definition.Id == sessionId && host.Visible(device, c));
    if (terminal is null && chat is null) throw new PhoneRefusal("unknown-session", "That session is not shared with this device.");
    reply["id"] = sessionId;
    if (type == "usage.read")
    {
      var want = PhoneWorkspaceFeatures.Text(message, "want")!;
      object reading;
      if (want == "context") reading = Usage.Context(sessionId);
      else if (want == "plan")
      {
        var report = Usage.Read(sessionId);
        reading = new { sessionId = report.SessionId, account = report.Account is { } a ? new { provider = a.Provider, id = a.Id, name = a.Name } : null,
          readings = report.Readings.Select(r => new { id = r.Id, account = new { provider = r.Account.Provider, id = r.Account.Id, name = r.Account.Name },
            window = r.Window switch { UsageWindow.FiveHour => "five-hour", UsageWindow.Weekly => "weekly", UsageWindow.Monthly => "monthly", _ => "other" },
            windowMinutes = r.WindowMinutes, label = r.Label, used = r.Used is { } fraction ? (object)new { kind = "reported", fraction } : new { kind = "not-reported" },
            resets = r.ResetAt is { } at ? (object)new { kind = "at", at } : r.ResetText is { Length: > 0 } text ? new { kind = "described", text } : new { kind = "not-reported" }, observedAt = r.ObservedAt, reportedAt = r.ReportedAt, source = r.Source }), reason = report.Reason, assembledAt = report.AssembledAt };
      }
      else if (want == "refresh") reading = await Usage.RefreshAsync(sessionId, message.TryGetProperty("force", out var f) && f.ValueKind == JsonValueKind.True, ct);
      else throw new PhoneRefusal("bad-message", "Choose plan, context or refresh.");
      reply["t"] = "usage.reading"; reply["want"] = want;
      reply["answer"] = new JsonObject { ["reading"] = JsonSerializer.SerializeToNode(reading, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase }) };
      return reply;
    }
    var provider = terminal?.Definition.Provider ?? chat!.Definition.Provider;
    var accountId = terminal?.Definition.AccountId ?? chat?.Definition.AccountId;
    var offered = Accounts.List().Where(a => a.Provider == provider && a.SignedIn).ToArray();
    if (type == "account.switch")
    {
      var destination = PhoneWorkspaceFeatures.Text(message, "accountId")!;
      if (!offered.Any(a => a.Id == destination)) throw new PhoneRefusal("unauthorized", "Choose a signed-in account offered for this session.");
      if (chat is not null) await Chats.SetAccountAsync(sessionId, destination, ct);
      else await AccountSwitches.SwitchAsync(sessionId, destination, ct);
      await RefreshSessionsAsync();
      reply["t"] = "account.switched"; reply["ok"] = true; reply["message"] = "Account switched; conversation kept."; reply["session"] = sessionId;
      return reply;
    }
    reply["t"] = "account.state"; reply["current"] = Accounts.List().FirstOrDefault(a => a.Id == accountId) is { } current ? PhoneAccount(current) : null;
    reply["accounts"] = new JsonArray(offered.Select(a => (JsonNode)PhoneAccount(a)).ToArray());
    return reply;
  }
  private static JsonObject PhoneAccount(AccountProfile a) => new()
  {
    ["id"] = a.Id, ["name"] = a.Name, ["provider"] = a.Provider, ["color"] = a.Color, ["system"] = false,
    ["signIn"] = new JsonObject { ["state"] = a.SignedIn ? "signed-in" : "signed-out", ["account"] = a.Email, ["plan"] = a.Plan, ["detail"] = a.SignedIn ? "Signed in." : "Sign in on this PC." }
  };
}
