using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Receiver;

public sealed record ReceiverIntakeStatus(bool Clipboard, bool Browser, int? Port);
public interface IReceiverIntakeSettings
{
  ReceiverIntakeStatus Status { get; }
  ValueTask ConfigureAsync(bool? clipboard, bool? browser, CancellationToken ct = default);
}
public sealed record ReceiverTool(McpToolSpec Spec, McpToolHandler Handler);

public sealed class ReceiverMcp(IReceiver receiver, IReceiverArtifacts artifacts, IReceiverIntakeSettings settings,
  Func<ReceiverItem, string, CancellationToken, ValueTask>? reply = null)
{
  public IReadOnlyList<ReceiverTool> Contributions() => ReceiverContracts.Specs.Where(s => s.Id != "receiver.reply" || reply is not null)
    .Select(s => new ReceiverTool(s, (context, args, ct) => CallAsync(s.Id, context, args, ct))).ToArray();
  public void Register(McpDoor door)
  {
    var catalogue = McpCatalogue.Load().ToDictionary(s => s.Id);
    foreach (var tool in Contributions())
      if (!catalogue.TryGetValue(tool.Spec.Id, out var spec) || spec.Tier != tool.Spec.Tier || !JsonElement.DeepEquals(spec.InputSchema, tool.Spec.InputSchema))
        throw new InvalidOperationException("Install ReceiverContracts.Specs in the shared catalogue before connecting Receiver tools.");
    foreach (var tool in Contributions()) door.Register(tool.Spec.Id, tool.Handler);
  }
  private async ValueTask<JsonElement> CallAsync(string tool, McpCallContext context, JsonElement args, CancellationToken ct)
  {
    await context.EnsureCurrentAsync(ct);
    ReceiverItem Item(string id)
    {
      var item = receiver.Item(id); context.Require("projects", item.ProjectId); return item;
    }
    ReceiverSource Source(string id)
    {
      var source = receiver.Sources().SingleOrDefault(s => s.Id == id) ?? throw new McpRefusal("Choose a Receiver source.");
      context.Require("projects", source.ProjectId); return source;
    }
    void Target(ReceiverTarget target, string project)
    {
      ReceiverStore.ValidateTarget(target);
      context.Require(target.Kind switch { RouteKind.Session => "sessions", RouteKind.Chat => "chats", RouteKind.Agent => "agents", RouteKind.Hoot => "receiver", _ => "tasks" }, target.Id ?? (target.Kind == RouteKind.Hoot ? "hoot" : project));
    }
    string S(string key) => args.GetProperty(key).GetString()!;
    string? Optional(string key) => args.TryGetProperty(key, out var v) && v.ValueKind != JsonValueKind.Null ? v.GetString() : null;
    object Summary(ReceiverItem item) => new { item.Id, source = item.SourceId, item.ProjectId, item.Title, item.Text, item.Url, item.Files, item.Status, item.Target, item.RuleId, item.ReceivedAt, item.Outcome, note = ReceiverStore.OutsideNote };
    if (tool.StartsWith("artifacts.", StringComparison.Ordinal))
    {
      var cwd = S("cwd"); context.Require("folders", cwd);
      var relative = Optional("relPath") ?? Optional("path");
      switch (tool)
      {
        case "artifacts.list":
          var count = args.TryGetProperty("limit", out var requested) ? requested.GetInt32() : 50;
          if (Optional("scope") == "all") return ReceiverJson.Value(new { artifacts = artifacts.Roots().Where(r => context.Has("folders", r.Path)).SelectMany(r => artifacts.List(r.Path, relative, count)).OrderByDescending(a => a.ProducedAt).Take(count) });
          return ReceiverJson.Value(new { artifacts = artifacts.List(cwd, relative, count) });
        case "artifacts.preview": return ReceiverJson.Value(artifacts.Preview(cwd, relative!));
        case "artifacts.open": await artifacts.OpenAsync(cwd, relative!, ct); break;
        case "artifacts.remove": artifacts.Remove(cwd, relative!); break;
        case "artifacts.send":
          var dest0 = S("target");
          if (dest0 != "hoot" && !Guid.TryParse(dest0, out _))
            throw new McpRefusal("Send hands an artifact to Hoot or a running session: use target \"hoot\" or a session id from sessions_list. Files a session writes appear in Artifacts by themselves; open one with artifacts_preview.");
          var row = artifacts.List(cwd, relative).SingleOrDefault() ?? throw new McpRefusal("Choose an artifact listed by artifacts_list for this folder.");
          context.Require("projects", row.ProjectId);
          var dest = S("target"); var target = new ReceiverTarget(dest == "hoot" ? RouteKind.Hoot : RouteKind.Session, dest == "hoot" ? null : dest);
          Target(target, row.ProjectId); await context.EnsureCurrentAsync(ct); await artifacts.SendAsync(cwd, relative!, target, ct); break;
      }
      return ReceiverJson.Value(new { ok = true });
    }
    switch (tool)
    {
      case "receiver.events":
        var status = Optional("status");
        if (status is not null && !Enum.TryParse<InboxStatus>(status, true, out _)) return ReceiverJson.Value(new { events = Array.Empty<object>(), note = ReceiverStore.OutsideNote });
        return ReceiverJson.Value(new { events = receiver.Items(Optional("source"), status is null ? null : Enum.Parse<InboxStatus>(status, true), Optional("query") ?? "", 1000)
          .Where(i => context.Has("projects", i.ProjectId)).Take(args.TryGetProperty("limit", out var l) ? l.GetInt32() : 50).Select(Summary), note = ReceiverStore.OutsideNote });
      case "receiver.event": return ReceiverJson.Value(new { item = Item(S("id")), note = ReceiverStore.OutsideNote });
      case "receiver.sources": return ReceiverJson.Value(new { sources = receiver.Sources().Where(s => context.Has("projects", s.ProjectId)) });
      case "receiver.rules":
        var allowedSources = receiver.Sources().Where(s => context.Has("projects", s.ProjectId)).Select(s => s.Id).ToHashSet();
        return ReceiverJson.Value(new { rules = receiver.Rules().Where(r => r.SourceId is not null && allowedSources.Contains(r.SourceId)) });
      case "receiver.test": case "receiver.source_check":
      {
        var previous = Optional("eventId") is { } id ? Item(id) : null;
        var source = Source(Optional("sourceId") ?? previous?.SourceId ?? throw new McpRefusal("Choose a source or event."));
        var sample = Optional("sample");
        var draft = previous is not null && sample is null ? new ReceiverDraft(source.Id, previous.Title, previous.Text, previous.Url, previous.Files) { Payload = previous.Payload } :
          new ReceiverDraft(source.Id, "Sample", sample ?? "");
        var rule = args.TryGetProperty("rule", out var value) ? ReceiverJson.Read<ReceiverRule>(value) : null;
        var decision = receiver.Test(draft, rule);
        return ReceiverJson.Value(new { decision, source, latest = receiver.Items(source.Id, limit: 1).Select(Summary).FirstOrDefault(), note = ReceiverStore.OutsideNote });
      }
      case "receiver.source_change":
      {
        var action = S("action");
        if (action == "create")
        {
          if (Optional("projectScope") == "all") throw new McpRefusal("Choose one project for this Windows source.");
          var project = Optional("projectId") ?? "independent"; context.Require("projects", project); context.Require("settings", "receiver");
          var kind = Enum.TryParse<IntakeKind>(Optional("type"), true, out var parsed) ? parsed : IntakeKind.Webhook;
          var source = new ReceiverSource(Guid.NewGuid().ToString("N"), Optional("name") ?? "New source", kind, project);
          receiver.SaveSource(source); return ReceiverJson.Value(source);
        }
        if (action == "update")
        {
          var source = ReceiverJson.Read<ReceiverSource>(args.GetProperty("source")); _ = Source(source.Id); context.Require("projects", source.ProjectId); receiver.SaveSource(source);
        }
        else
        {
          var source = Source(S("id"));
          if (action == "delete") receiver.RemoveSource(source.Id);
          else if (action is "pause" or "resume") receiver.SaveSource(source with { Enabled = action == "resume" });
          else throw new McpRefusal("Intake keys are managed by the person in Receiver settings.");
        }
        break;
      }
      case "receiver.rule_change":
      {
        var action = S("action");
        if (action == "save")
        {
          var rule = ReceiverJson.Read<ReceiverRule>(args.GetProperty("rule"));
          var existing = receiver.Rules().FirstOrDefault(r => r.Id == rule.Id);
          if (existing is not null) { if (existing.SourceId is null) context.Require("settings", "receiver"); else _ = Source(existing.SourceId); }
          if (rule.SourceId is null) throw new McpRefusal("Choose a source so this rule stays inside a project.");
          var source = Source(rule.SourceId); Target(rule.Target, source.ProjectId); receiver.SaveRule(rule);
        }
        else
        {
          var rule = receiver.Rules().Single(r => r.Id == S("id"));
          if (rule.SourceId is null) context.Require("settings", "receiver"); else _ = Source(rule.SourceId);
          if (action == "delete") receiver.RemoveRule(rule.Id); else receiver.MoveRule(rule.Id, args.GetProperty("index").GetInt32());
        }
        break;
      }
      case "receiver.route":
      {
        var item = Item(S("id")); var target = ReceiverJson.Read<ReceiverTarget>(args.GetProperty("target")); Target(target, item.ProjectId);
        if (!string.IsNullOrEmpty(Optional("instruction"))) throw new McpRefusal("Put instructions in the destination after routing. The original shared item stays intact.");
        return ReceiverJson.Value(Summary(await receiver.RouteAsync(item.Id, target, ct)));
      }
      case "receiver.replay":
      {
        var item = Item(S("id"));
        if (Optional("mode") == "replay")
          return ReceiverJson.Value(Summary(receiver.Replay(item.Id)));
        var target = item.Target ?? throw new McpRefusal("Choose a destination with receiver_route first."); Target(target, item.ProjectId);
        return ReceiverJson.Value(Summary(await receiver.RouteAsync(item.Id, target, ct)));
      }
      case "receiver.reply":
        var eventItem = Item(S("id")); context.Require("receiver", eventItem.SourceId);
        if (reply is null) throw new McpRefusal("This source has no reply connection.");
        await reply(eventItem, S("text"), ct); break;
      case "receiver.dismiss": _ = Item(S("id")); receiver.Dismiss(S("id")); break;
      case "receiver.intake": context.Require("settings", "receiver"); return ReceiverJson.Value(settings.Status);
      case "receiver.intake_change":
        context.Require("settings", "receiver");
        await settings.ConfigureAsync(args.TryGetProperty("clipboard", out var clip) ? clip.GetBoolean() : null, args.TryGetProperty("browser", out var browser) ? browser.GetBoolean() : null, ct);
        return ReceiverJson.Value(settings.Status);
      default: throw new McpRefusal("This Receiver action is unavailable.");
    }
    return ReceiverJson.Value(new { ok = true });
  }
}
