using System.Text.Json;
using System.Text.Json.Serialization;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Hoot;

public sealed class HootMcpTools(IHoot hoot, IHootSurface? surface = null)
{
  private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) } };
  private static JsonElement Value<T>(T value) => JsonSerializer.SerializeToElement(value, Json);
  private static McpToolSpec Spec(string id, McpTier tier, string properties = "", string required = "") =>
    new(id, id.Replace('.', '_'), tier, JsonDocument.Parse("{\"type\":\"object\",\"properties\":{" + properties + "},\"additionalProperties\":false" +
      (required.Length == 0 ? "" : ",\"required\":[" + required + "]") + "}").RootElement.Clone());
  private const string Text = "{\"type\":\"string\",\"maxLength\":64000}";
  private const string Id = "{\"type\":\"string\",\"minLength\":1,\"maxLength\":128}";
  public static IReadOnlyList<McpToolSpec> Specs { get; } = [
    Spec("hoot.chat.read", McpTier.Read, "\"cursor\":{\"type\":\"integer\",\"minimum\":0},\"limit\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":500}"),
    Spec("hoot.chat.history", McpTier.Read), Spec("hoot.chat.new", McpTier.Alter),
    Spec("hoot.chat.background", McpTier.Read), Spec("hoot.settings.read", McpTier.Read), Spec("memory.hoot.read", McpTier.Read),
    Spec("hoot.send", McpTier.Alter, $"\"clientId\":{Id},\"text\":{Text}", "\"clientId\",\"text\""),
    Spec("hoot.chat.stop", McpTier.Alter), Spec("hoot.chat.continue", McpTier.Alter), Spec("hoot.chat.keep_unconfirmed", McpTier.Alter),
    Spec("hoot.background.start", McpTier.Alter, $"\"clientId\":{Id},\"reason\":{{\"type\":\"string\",\"enum\":[\"task\",\"handoff\",\"dev-test\",\"background\"]}},\"sourceId\":{Id},\"title\":{{\"type\":\"string\",\"minLength\":1,\"maxLength\":200}},\"text\":{Text}", "\"clientId\",\"reason\",\"sourceId\",\"title\",\"text\""),
    Spec("hoot.background.cancel", McpTier.Alter, $"\"turnId\":{Id}", "\"turnId\""),
    Spec("hoot.settings.set", McpTier.Alter, "\"settings\":{\"type\":\"object\"}", "\"settings\""),
    Spec("memory.hoot.save", McpTier.Alter, "\"card\":{\"type\":\"string\",\"maxLength\":16000},\"playbook\":{\"type\":\"string\",\"maxLength\":16000}", "\"card\",\"playbook\""),
    Spec("memory.hoot.board", McpTier.Alter, "\"row\":{\"type\":\"object\"}", "\"row\""),
    Spec("memory.refresh.now", McpTier.Alter),
    Spec("hoot.handoff", McpTier.Alter, $"\"clientId\":{Id},\"sessionId\":{Id},\"text\":{{\"type\":\"string\",\"maxLength\":7000}}", "\"clientId\",\"sessionId\",\"text\""),
    Spec("hoot.open", McpTier.Act)
  ];
  public void Register(McpDoor door)
  {
    var known = McpCatalogue.Load().ToDictionary(s => s.Id);
    if (Specs.Any(s => !known.TryGetValue(s.Id, out var current) || current.Tier != s.Tier || !JsonElement.DeepEquals(current.InputSchema, s.InputSchema)))
      throw new InvalidOperationException("Install HootMcpTools.Specs in the central catalogue before registering Hoot handlers.");
    foreach (var spec in Specs) { var id = spec.Id; door.Register(id, (context, args, ct) => CallAsync(id, context, args, ct)); }
  }
  public async ValueTask<JsonElement> CallAsync(string tool, McpCallContext context, JsonElement args, CancellationToken ct)
  {
    var spec = Specs.SingleOrDefault(s => s.Id == tool) ?? throw new McpRefusal("Choose a Hoot tool.");
    McpSchema.Validate(spec.InputSchema, args);
    if (!context.Grant.Tools.Contains(tool) || !context.Grant.Tiers.Contains(spec.Tier)) throw new McpRefusal("That Hoot tool is outside this caller's permission.");
    context.Require("hoot", "main");
    var state = hoot.Read(); HootPolicy.Check(context.Grant, tool, args, state);
    if (state.Settings is { } settings)
    { context.Require("accounts", settings.AccountId); context.Require("folders", settings.Folder); }
    string S(string key) => args.GetProperty(key).GetString() ?? "";
    if (tool == "hoot.chat.read")
    {
      var cursor = args.TryGetProperty("cursor", out var c) ? c.GetInt64() : 0;
      var limit = args.TryGetProperty("limit", out var l) ? l.GetInt32() : 200;
      return Value(HootTranscript.Read(state, cursor, limit));
    }
    if (tool == "hoot.chat.history") return Value(state.History);
    if (tool == "hoot.settings.read") return Value(state.Settings);
    if (tool == "memory.hoot.read") return Value(state.Memory);
    if (tool == "hoot.chat.background") return Value(new { active = state.Active, waiting = state.Waiting, turns = state.Turns.Where(t => t.Source.Kind != "person").TakeLast(100) });
    await context.EnsureCurrentAsync(ct);
    switch (tool)
    {
      // Agent notes always keep their authenticated source. Arguments cannot
      // claim to be the person or widen their own permission.
      case "hoot.send": await hoot.SayAsync(S("clientId"), S("text"), new("session", context.Grant.SessionId ?? context.Grant.CallerId, "A note from " + context.Grant.CallerId), ct); break;
      case "hoot.chat.stop": await hoot.StopAsync(ct); break;
      case "hoot.chat.keep_unconfirmed": await hoot.KeepUnconfirmedAsync(ct); break;
      case "hoot.chat.continue": await hoot.ContinueAsync(ct); break;
      case "hoot.background.start":
        await hoot.BackgroundTurnAsync(S("clientId"), S("reason"), S("sourceId"), S("title"), S("text"), cancellationToken: ct); break;
      case "hoot.background.cancel": await hoot.CancelBackgroundAsync(S("turnId"), ct); break;
      case "hoot.settings.set":
        var choice = args.GetProperty("settings").Deserialize<HootSettings>(Json) ?? throw new ArgumentException("Choose Hoot's settings.");
        if (choice.PermissionMode == AiPermissionMode.Bypass && !context.Grant.OwnerApplication)
          throw new McpRefusal("Only the person can choose Bypass permissions in Hoot settings.");
        context.Require("accounts", choice.AccountId); context.Require("folders", choice.Folder);
        await hoot.ConfigureAsync(choice, ct); break;
      case "memory.hoot.save": await hoot.SaveMemoryAsync(S("card"), S("playbook"), ct); break;
      case "memory.hoot.board":
        var row = args.GetProperty("row").Deserialize<HootBoardRow>(Json) ?? throw new ArgumentException("Choose a board row.");
        if (row.SessionId is not null) context.Require("sessions", row.SessionId);
        await hoot.SaveBoardAsync(row, ct); break;
      case "memory.refresh.now": throw new McpRefusal("Memory upkeep keeps the conversation. Use hoot.chat.new only when the person explicitly requests a new chat.");
      case "hoot.chat.new": await hoot.RefreshAsync(ct); break;
      case "hoot.handoff": context.Require("sessions", S("sessionId")); return Value(await hoot.HandoffAsync(S("clientId"), S("sessionId"), S("text"), ct));
      case "hoot.open":
        if (surface is null) throw new InvalidOperationException("Hoot's window is not attached yet.");
        await surface.OpenAsync(ct); break;
    }
    return Value(new { ok = true });
  }
}
