using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Receiver;

namespace TerminalDeck.Core.Remote;

public static class PhoneReceiverPanel
{
  private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, string> sourceNotes = new();
  private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, ReceiverSourceConfiguration> sourceDrafts = new();
  private static void Note(string key, string value)
  { foreach (var old in sourceNotes.Keys.Take(Math.Max(0, sourceNotes.Count - 127)).ToArray()) { sourceNotes.TryRemove(old, out _); sourceDrafts.TryRemove(old, out _); } sourceNotes[key] = value.Length > 16000 ? value[..16000] + "\n[Preview excerpt.]" : value; }
  public static PhonePanelOwner Create(IReceiver receiver, Func<ApprovedDevice, string, bool> projectAllowed,
    Func<ApprovedDevice, ReceiverTarget, bool> targetAllowed, ReceiverSourceService? sourceSettings = null) => new("receiver", false,
    (device, request, ct) =>
    {
      ct.ThrowIfCancellationRequested(); var rows = new JsonArray(); var scope = Text(request, "scope") ?? "inbox";
      if (scope == "sources")
        foreach (var source in receiver.Sources().Where(s => projectAllowed(device, s.ProjectId)).Take(200))
        {
          var actions = device.Access == PhoneAccess.Full ? new JsonArray(Action(source.Enabled ? "pause-source" : "resume-source", source.Enabled ? "Pause" : "Resume"), Action("remove-source", "Remove", true)) : new JsonArray();
          if (sourceSettings is { } sourceOwner && device.Access == PhoneAccess.Full)
          {
            actions.Add(Form("configure-source", "Edit proof, mapping and replies", Field("configuration", "Source configuration JSON", JsonSerializer.Serialize(sourceDrafts.GetValueOrDefault(sourceOwner.InstanceId + ":" + device.Id + ":" + source.Id) ?? sourceOwner.Read(source.Id), ReceiverJson.Options))));
            actions.Add(Form("proof-credential", "Set proof credential", Field("value", "Proof secret · empty removes", secret: true)));
            actions.Add(Form("reply-credential", "Set reply credential", Field("value", "Reply credential · empty removes", secret: true)));
            actions.Add(Form("save-preset", "Save as a preset without secrets", Field("name", "Preset name", source.Name)));
            actions.Add(Form("learn-source", "Learn mapping from latest event"));
            actions.Add(Form("preview-source", "Preview payload without receiving", Field("payload", "JSON payload", "{}"), Field("headers", "Headers JSON", "{}")));
          }
          rows.Add(new JsonObject { ["id"] = source.Id, ["title"] = source.Name, ["detail"] = sourceSettings is not null && source.Kind == IntakeKind.Webhook ? sourceSettings.Address(source.Id) : source.Kind.ToString(), ["value"] = source.Enabled ? "On" : "Paused", ["body"] = sourceNotes.GetValueOrDefault((sourceSettings?.InstanceId ?? "") + ":" + device.Id + ":" + source.Id) ?? "", ["bodyStyle"] = "code", ["actions"] = actions });
        }
      else if (scope == "rules")
      {
        var sourceIds = receiver.Sources().Where(s => projectAllowed(device, s.ProjectId)).Select(s => s.Id).ToHashSet();
        foreach (var rule in receiver.Rules().Where(r => r.SourceId is not null && sourceIds.Contains(r.SourceId)).Take(200))
          rows.Add(new JsonObject { ["id"] = rule.Id, ["title"] = rule.Name, ["detail"] = rule.Contains, ["value"] = rule.Enabled ? "On" : "Paused",
            ["actions"] = device.Access == PhoneAccess.Full ? new JsonArray(Action(rule.Enabled ? "pause-rule" : "resume-rule", rule.Enabled ? "Pause" : "Resume"), Action("remove-rule", "Remove", true)) : new JsonArray() });
      }
      else
        foreach (var item in receiver.Items(query: Text(request, "query") ?? "", limit: 1000).Where(i => projectAllowed(device, i.ProjectId)).Take(200))
        {
          var actions = new JsonArray();
          if (device.Access != PhoneAccess.Look)
          {
            actions.Add(Action("dismiss", "Dismiss"));
            if (item.Status is InboxStatus.Failed or InboxStatus.Held && item.Target is { } target && targetAllowed(device, target)) actions.Add(Action("retry", "Retry"));
            foreach (var destination in receiver.Destinations(item.ProjectId).Where(d => targetAllowed(device, d.Target)).Take(8))
              actions.Add(Action("route:" + destination.Target.Kind + ":" + destination.Target.Id, "Send to " + destination.Name));
          }
          if (sourceSettings is not null && device.Access == PhoneAccess.Full && sourceSettings.Read(item.SourceId).Reply is not null) actions.Add(Form("reply", "Reply through this source", Field("text", "Reply")));
          rows.Add(new JsonObject { ["id"] = item.Id, ["title"] = item.Title, ["detail"] = item.Outcome ?? item.Status.ToString(), ["body"] = Cut(item.Text, 1500), ["badge"] = item.Status.ToString(), ["actions"] = actions });
        }
      return ValueTask.FromResult(new JsonObject { ["title"] = "Receiver", ["rows"] = rows, ["view"] = scope,
        ["scopes"] = new JsonArray(Scope("inbox", "Inbox"), Scope("sources", "Sources"), Scope("rules", "Rules")), ["actions"] = sourceSettings is not null && scope == "sources" && device.Access == PhoneAccess.Full ? new JsonArray(Form("create-source", "Add source", Field("name", "Source name"), Field("projectId", "Project ID", receiver.Sources().FirstOrDefault(s => projectAllowed(device, s.ProjectId))?.ProjectId ?? ""), Field("preset", "Preset", "webhook", sourceSettings.Presets().Select(p => p.Id).ToArray()))) : new JsonArray() });
    }, async (device, request, ct) =>
    {
      var action = Text(request, "action")!; var id = Text(request, "id")!;
      var fields = request.TryGetProperty("fields", out var input) && input.ValueKind == JsonValueKind.Object ? input.EnumerateObject().ToDictionary(p => p.Name, p => p.Value.GetString() ?? "") : new Dictionary<string, string>();
      if (action == "create-source" && sourceSettings is not null)
      { if (device.Access != PhoneAccess.Full || !projectAllowed(device, fields.GetValueOrDefault("projectId") ?? "")) throw new PhoneRefusal("unauthorized", "Choose an allowed project."); await sourceSettings.CreateAsync(fields.GetValueOrDefault("name") ?? "", fields.GetValueOrDefault("projectId") ?? "", fields.GetValueOrDefault("preset") ?? "webhook", ct); return; }
      if (sourceSettings is not null && action is "configure-source" or "proof-credential" or "reply-credential" or "save-preset" or "learn-source" or "preview-source")
      {
        var selected = receiver.Sources().Single(s => s.Id == id && projectAllowed(device, s.ProjectId)); if (device.Access != PhoneAccess.Full) throw new PhoneRefusal("unauthorized", "Source changes need Full control.");
        switch (action)
        {
          case "configure-source": sourceSettings.Save((JsonSerializer.Deserialize<ReceiverSourceConfiguration>(fields.GetValueOrDefault("configuration") ?? "{}", ReceiverJson.Options) ?? throw new PhoneRefusal("bad-message", "Give complete source settings.")) with { SourceId = selected.Id }); sourceDrafts.TryRemove(sourceSettings.InstanceId + ":" + device.Id + ":" + id, out _); Note(sourceSettings.InstanceId + ":" + device.Id + ":" + id, "Source settings saved."); break;
          case "proof-credential": case "reply-credential": await sourceSettings.SetCredentialAsync(id, fields.GetValueOrDefault("value") ?? "", action == "reply-credential", ct); break;
          case "save-preset": sourceSettings.SavePreset(id, fields.GetValueOrDefault("name") ?? ""); break;
          case "learn-source": var learned = sourceSettings.Learn(id); sourceDrafts[sourceSettings.InstanceId + ":" + device.Id + ":" + id] = learned; Note(sourceSettings.InstanceId + ":" + device.Id + ":" + id, "Suggested mapping, not saved. Open Edit proof, mapping and replies to review and save.\n" + JsonSerializer.Serialize(learned.Mapping, ReceiverJson.Options)); break;
          case "preview-source": var preview = sourceSettings.Preview(new(id, JsonSerializer.Deserialize<Dictionary<string, string>>(fields.GetValueOrDefault("headers") ?? "{}")!, System.Text.Encoding.UTF8.GetBytes(fields.GetValueOrDefault("payload") ?? "{}"))); Note(sourceSettings.InstanceId + ":" + device.Id + ":" + id, "Read-only preview. No event was received or delivered.\n" + JsonSerializer.Serialize(preview, ReceiverJson.Options)); break;
        }
        return;
      }
      if (action.EndsWith("-source", StringComparison.Ordinal))
      {
        if (device.Access != PhoneAccess.Full) throw new PhoneRefusal("unauthorized", "Changing intake sources needs Full control.");
        var source = receiver.Sources().Single(s => s.Id == id && projectAllowed(device, s.ProjectId));
        if (action == "remove-source") receiver.RemoveSource(id); else receiver.SaveSource(source with { Enabled = action == "resume-source" });
      }
      else if (action.EndsWith("-rule", StringComparison.Ordinal))
      {
        if (device.Access != PhoneAccess.Full) throw new PhoneRefusal("unauthorized", "Changing intake rules needs Full control.");
        var rule = receiver.Rules().Single(r => r.Id == id); var source = receiver.Sources().Single(s => s.Id == rule.SourceId && projectAllowed(device, s.ProjectId));
        if (action == "remove-rule") receiver.RemoveRule(id); else receiver.SaveRule(rule with { Enabled = action == "resume-rule" });
      }
      else
      {
        var item = receiver.Item(id); if (!projectAllowed(device, item.ProjectId)) throw new PhoneRefusal("unauthorized", "That item is no longer shared.");
        if (action == "reply" && sourceSettings is not null) { if (device.Access != PhoneAccess.Full) throw new PhoneRefusal("unauthorized", "Replies need Full control."); var outcome = await sourceSettings.ReplyAsync(id, fields.GetValueOrDefault("text") ?? "", ct); if (outcome.State != "sent") throw new PhoneRefusal("unavailable", outcome.Problem ?? "Reply delivery was not confirmed."); }
        else if (action == "dismiss") receiver.Dismiss(id);
        else
        {
          var target = action == "retry" ? item.Target : receiver.Destinations(item.ProjectId).FirstOrDefault(d => "route:" + d.Target.Kind + ":" + d.Target.Id == action)?.Target;
          if (target is null || !targetAllowed(device, target)) throw new PhoneRefusal("unauthorized", "That destination is not shared with this phone.");
          await receiver.RouteAsync(id, target, ct);
        }
      }
    });
  private static JsonObject Field(string id, string label, string value = "", string[]? choices = null, bool secret = false) => new() { ["id"] = id, ["label"] = label, ["value"] = value, ["secret"] = secret, ["choices"] = new JsonArray((choices ?? []).Select(c => (JsonNode)JsonValue.Create(c)!).ToArray()) };
  private static JsonObject Form(string id, string label, params JsonObject[] fields) => new() { ["id"] = id, ["label"] = label, ["fields"] = new JsonArray(fields.Select(f => (JsonNode)f).ToArray()) };
  private static JsonObject Action(string id, string label, bool destructive = false) => new() { ["id"] = id, ["label"] = label, ["kind"] = destructive ? "destructive" : "default" };
  private static JsonObject Scope(string id, string label) => new() { ["id"] = id, ["label"] = label };
  private static string Cut(string value, int max) => value[..Math.Min(max, value.Length)];
  private static string? Text(JsonElement m, string k) => m.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
}
