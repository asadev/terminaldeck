using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.WhatsApp;

/// WhatsApp agents' tools (DESIGN-WHATSAPP.md section 6; every feature ships with its tools), a port of the Mac's
/// BackendWhatsAppTools.swift. Reading is free; add, remove, rename and replace_key are Alter (he must be present and the
/// calling AI's own permission asks him); receive, send and sending are Act (the calling AI's permission asks him).
/// The key (`apiKey`) is taken by add and replace_key only and is never in an answer, an error or the action line
/// (McpCallerAuthority.Describe names only ids and actions).
public static class WhatsAppTools
{
  public const string AgentsId = "whatsapp.agents", AddId = "whatsapp.add", RemoveId = "whatsapp.remove", RenameId = "whatsapp.rename",
    ReplaceKeyId = "whatsapp.replace_key", ReceiveId = "whatsapp.receive", SendId = "whatsapp.send", SendingId = "whatsapp.sending";
  public const string NotReady = "WhatsApp agents are not ready on this computer yet.";

  private const string AgentArg = "\"agent\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":200,\"description\":\"The WhatsApp agent's id or its name as listed by whatsapp_agents.\"}";
  private const string Key = "\"apiKey\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":4096}";
  private const string Name = "\"name\":{\"type\":\"string\",\"maxLength\":200}";
  private static McpToolSpec Spec(string id, McpTier tier, string properties = "", string required = "") =>
    new(id, id.Replace('.', '_'), tier, JsonDocument.Parse("{\"type\":\"object\",\"properties\":{" + properties + "},\"additionalProperties\":false" +
      (required.Length == 0 ? "" : ",\"required\":[" + required + "]") + "}").RootElement.Clone());

  public static IReadOnlyList<McpToolSpec> Specs { get; } =
  [
    Spec(AgentsId, McpTier.Read),
    Spec(AddId, McpTier.Alter, Name + "," + Key, "\"apiKey\""),
    Spec(RemoveId, McpTier.Alter, AgentArg, "\"agent\""),
    Spec(RenameId, McpTier.Alter, AgentArg + "," + Name, "\"agent\",\"name\""),
    Spec(ReplaceKeyId, McpTier.Alter, AgentArg + "," + Key, "\"agent\",\"apiKey\""),
    Spec(ReceiveId, McpTier.Act, AgentArg + ",\"kind\":{\"type\":\"string\",\"enum\":[\"hoot\",\"agent\",\"session\",\"nowhere\"]},\"id\":{\"type\":\"string\",\"maxLength\":200}," + Name, "\"agent\",\"kind\""),
    Spec(SendId, McpTier.Act, AgentArg + ",\"text\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":64000}", "\"agent\",\"text\""),
    Spec(SendingId, McpTier.Act, AgentArg + ",\"on\":{\"type\":\"boolean\"}", "\"agent\",\"on\""),
  ];

  /// Registers the eight tools on the door. `engine`: null while WhatsApp agents are not ready on this computer.
  public static void Register(McpDoor door, Func<WhatsAppAgents?> engine)
  {
    foreach (var spec in Specs)
    {
      var id = spec.Id;
      door.Register(id, async (_, args, _) =>
      {
        var current = engine() ?? throw new McpRefusal(NotReady);
        return await RunAsync(id, args, current);
      });
    }
  }

  /// One profile as the tools answer it. Never a key.
  public static JsonObject Wire(WhatsAppAgentProfile p)
  {
    var receiver = new JsonObject { ["kind"] = p.Receiver.Kind.ToString().ToLowerInvariant() };
    if (p.Receiver.Kind == WhatsAppReceiverKind.Hoot) receiver["name"] = "Hoot";
    if (p.Receiver.Kind is WhatsAppReceiverKind.Agent or WhatsAppReceiverKind.Session) { receiver["id"] = p.Receiver.Id; receiver["name"] = p.Receiver.Name; }
    return new JsonObject
    {
      ["id"] = p.Id, ["name"] = p.Name,
      ["state"] = p.State switch { WhatsAppAgentState.Connected => "connected", WhatsAppAgentState.Waiting => "waiting for his first message", _ => "key refused" },
      ["receivedBy"] = receiver, ["sending"] = p.Sending, ["answeredBy"] = p.AnsweringComputerName, ["answeredHere"] = p.AnsweredHere,
      ["lastMessage"] = p.LastMessageAt?.ToString("O"),
    };
  }

  private static string Text(JsonElement args, string name, bool required = true)
  {
    var value = args.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
    if (required && value.Trim().Length == 0) throw new McpRefusal(name + " is required.");
    return value;
  }

  public static async Task<WhatsAppAgentProfile> FindAsync(WhatsAppAgents engine, JsonElement args)
  {
    var wanted = Text(args, "agent");
    var all = await engine.AgentsAsync();
    if (all.FirstOrDefault(p => p.Id == wanted) is { } byId) return byId;
    var named = all.Where(p => string.Equals(p.Name, wanted, StringComparison.OrdinalIgnoreCase)).ToArray();
    if (named.Length != 1) throw new McpRefusal(named.Length == 0 ? "There is no WhatsApp agent called " + wanted + "." : "Two WhatsApp agents are called " + wanted + "; use its id.");
    return named[0];
  }
  public static WhatsAppReceiver ReceiverOf(JsonElement args)
  {
    var kind = Text(args, "kind");
    switch (kind)
    {
      case "hoot": return WhatsAppReceiver.Hoot;
      case "nowhere": return WhatsAppReceiver.Nowhere;
      case "agent" or "session":
        var id = Text(args, "id");
        var name = Text(args, "name", required: false) is { Length: > 0 } n ? n : id;
        return kind == "agent" ? WhatsAppReceiver.Agent(id, name) : WhatsAppReceiver.Session(id, name);
      default: throw new McpRefusal("kind is hoot, agent, session or nowhere.");
    }
  }

  private static async Task<T> Plain<T>(Func<Task<T>> work)
  {
    try { return await work(); }
    catch (WhatsAppProblem problem) { throw new McpRefusal(problem.Message); }
  }
  private static Task Plain(Func<Task> work) => Plain(async () => { await work(); return true; });
  private static JsonElement Out(JsonNode node) => JsonSerializer.SerializeToElement(node);

  public static async Task<JsonElement> RunAsync(string id, JsonElement args, WhatsAppAgents engine)
  {
    switch (id)
    {
      case AgentsId:
        return Out(new JsonObject { ["agents"] = new JsonArray((await engine.AgentsAsync()).Select(p => (JsonNode)Wire(p)).ToArray()) });
      case AddId:
      {
        var name = Text(args, "name", required: false);
        var key = Text(args, "apiKey");
        return Out(Wire(await Plain(() => engine.AddAsync(name, key))));
      }
      case RemoveId:
      {
        var agent = await FindAsync(engine, args);
        await Plain(() => engine.RemoveAsync(agent.Id));
        return Out(new JsonObject { ["removed"] = agent.Name });
      }
      case RenameId:
      {
        var agent = await FindAsync(engine, args); var name = Text(args, "name");
        await Plain(() => engine.RenameAsync(agent.Id, name));
        return Out(new JsonObject { ["renamed"] = name });
      }
      case ReplaceKeyId:
      {
        var agent = await FindAsync(engine, args); var key = Text(args, "apiKey");
        await Plain(() => engine.ReplaceKeyAsync(agent.Id, key));
        return Out(new JsonObject { ["replaced"] = agent.Name });
      }
      case ReceiveId:
      {
        var agent = await FindAsync(engine, args); var target = ReceiverOf(args);
        await Plain(() => engine.SetReceiverAsync(agent.Id, target));
        return Out(Wire((await engine.AgentsAsync()).FirstOrDefault(p => p.Id == agent.Id) ?? agent));
      }
      case SendId:
      {
        var agent = await FindAsync(engine, args); var text = Text(args, "text");
        await Plain(() => engine.SendAsync(agent.Id, text));
        return Out(new JsonObject { ["sent"] = true });
      }
      case SendingId:
      {
        var agent = await FindAsync(engine, args);
        if (!args.TryGetProperty("on", out var on) || on.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) throw new McpRefusal("on is true or false.");
        await Plain(() => engine.SetSendingAsync(on.GetBoolean(), agent.Id));
        return Out(Wire((await engine.AgentsAsync()).FirstOrDefault(p => p.Id == agent.Id) ?? agent));
      }
      default: throw new McpRefusal("Unknown WhatsApp tool.");
    }
  }
}
