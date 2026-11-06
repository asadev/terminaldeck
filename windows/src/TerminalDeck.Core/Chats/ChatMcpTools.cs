using System.Text.Json;
using System.Text.Json.Serialization;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Accounts;

namespace TerminalDeck.Core.Chats;

// Uses the existing session tools and their exact permission door. W4 can
// compose these handlers with its terminal handlers, without another approval UI.
public sealed class ChatMcpTools(IChatSessions chats, Func<string, AiPermissionMode>? defaultPermission = null) : IDisposable
{
  private static readonly JsonSerializerOptions WireJson = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) } };
  private static JsonElement Value<T>(T value) => JsonSerializer.SerializeToElement(value, WireJson);
  private readonly ChatImageUploads images = new(chats);
  private readonly ChatHistoryTools history = new(chats);
  public const string CommandPrefix = "deck-chat:";
  public bool Owns(string id) => chats.List().Any(c => c.Definition.Id == id);
  public static readonly string[] Tools = ["sessions.get", "sessions.screen", "sessions.rename", "sessions.send", "sessions.stop", "agents.controls", "agents.models", "agents.set_control", "sessions.account", "chats.list", "chats.read"];
  public void Register(McpDoor door, IReadOnlyDictionary<string, McpToolHandler>? terminalFallbacks = null)
  {
    foreach (var tool in Tools)
    {
      var name = tool;
      door.Compose(name, previous => async (context, arguments, ct) =>
      {
        var fallbacks = terminalFallbacks is null ? new Dictionary<string, McpToolHandler>() : new Dictionary<string, McpToolHandler>(terminalFallbacks);
        if (previous is not null) fallbacks[name] = previous;
        if (name is "chats.list" or "chats.read")
        {
          var locator = ChatLineProtocol.S(arguments, "transcriptPath");
          if (name == "chats.read" && locator.Length > 0 && !locator.StartsWith("chat:", StringComparison.Ordinal) && fallbacks.TryGetValue(name, out var read)) return await read(context, arguments, ct);
          var own = history.Read(context, arguments, name == "chats.list");
          if (name == "chats.list" && fallbacks.TryGetValue(name, out var other))
          {
            var rows = await other(context, arguments, ct);
            if (rows.ValueKind != JsonValueKind.Array) throw new McpRefusal("The transcript list could not be combined.");
            return Value(rows.EnumerateArray().Concat(own.EnumerateArray()).ToArray());
          }
          return own;
        }
        if (name == "sessions.account" && ChatLineProtocol.S(arguments, "action") == "armed")
        {
          if (fallbacks.TryGetValue(name, out var armed)) return await armed(context, arguments, ct);
          return Value(Array.Empty<object>());
        }
        var id = arguments.GetProperty("sessionId").GetString() ?? throw new McpRefusal("Choose a chat.");
        if (!Owns(id))
        {
          if (fallbacks.TryGetValue(name, out var fallback)) return await fallback(context, arguments, ct);
          throw new McpRefusal("That chat was not found.");
        }
        return await CallAsync(name, context, arguments, ct);
      });
    }
  }
  public async ValueTask<JsonElement> CallAsync(string tool, McpCallContext context, JsonElement arguments, CancellationToken ct)
  {
    if (tool is "chats.list" or "chats.read") return history.Read(context, arguments, tool == "chats.list");
    if (tool == "sessions.account" && ChatLineProtocol.S(arguments, "action") == "armed") return Value(Array.Empty<object>());
    var id = arguments.GetProperty("sessionId").GetString() ?? throw new McpRefusal("Choose a chat.");
    context.Require("sessions", id); var chat = chats.Get(id); context.Require("accounts", chat.Definition.AccountId); context.Require("folders", chat.Definition.Cwd);
    if (tool is "sessions.get" or "sessions.screen") return View(chat);
    if (tool == "agents.controls") return Value(new { chat.Definition.Options, chat.Definition.AccountId, chat.Definition.PermissionMode, chat.Busy, appliedModel = ChatProviderSnapshot.Read(chat).Model, providerState = ChatProviderSnapshot.Read(chat), whenItChanges = "Saved choices are used on the next message. Applied values come only from this worker’s provider report." });
    if (tool == "agents.models") return Value(await chats.ModelsAsync(id, ct));
    await context.EnsureCurrentAsync(ct);
    if (tool == "sessions.account")
    {
      var action = arguments.GetProperty("action").GetString();
      if (action == "show") return Value(new { accountId = chat.Definition.AccountId });
      if (action is not ("plan" or "switch")) throw new McpRefusal("This chat supports show, plan and switch here.");
      var name = arguments.GetProperty("account").GetString();
      var destination = chats.Accounts(id).SingleOrDefault(a => a.Id == name || a.Name == name) ?? throw new McpRefusal("Choose one account from the account list.");
      context.Require("accounts", destination.Id);
      if (action == "plan") return Value(new { accountId = destination.Id, canSwitch = await chats.CanSwitchAccountAsync(id, destination.Id, ct), keepsConversation = true });
      await chats.SetAccountAsync(id, destination.Id, ct);
    }
    else if (tool == "sessions.rename") await chats.RenameAsync(id, arguments.GetProperty("title").GetString() ?? "", ct);
    else if (tool == "sessions.stop") await chats.StopAsync(id, ct);
    else if (tool == "agents.set_control")
    {
      var control = arguments.GetProperty("control").GetString(); var value = arguments.GetProperty("value").GetString() ?? "";
      if (control == "permission")
      {
        if (!Enum.TryParse<AiPermissionMode>(value == "manual" ? "Ask" : value, true, out var mode)) throw new McpRefusal("Choose a supported chat permission mode.");
        await chats.SetPermissionAsync(id, mode, ct);
        return View(chats.Get(id));
      }
      await chats.SetOptionsAsync(id, control switch
      {
        "model" => chat.Definition.Options with { Model = value == "default" ? "" : value },
        "effort" => chat.Definition.Options with { Effort = value },
        _ => throw new McpRefusal("This chat supports model, effort and permission choices here.")
      }, ct);
    }
    else if (tool == "sessions.send")
    {
      var text = arguments.GetProperty("text").GetString() ?? "";
      if (!text.StartsWith(CommandPrefix, StringComparison.Ordinal))
        throw new McpRefusal("Send chat text as deck-chat:{\"action\":\"send\",\"clientId\":\"<uuid>\",\"text\":\"...\"}. Keep this id for retries.");
      if (text.Length > 4000) throw new McpRefusal("Send at most 4000 characters through this tool.");
      using var command = JsonDocument.Parse(text[CommandPrefix.Length..]); var value = command.RootElement;
      string Required(string name) => value.TryGetProperty(name, out var p) && p.ValueKind == JsonValueKind.String ? p.GetString()! : throw new McpRefusal("The chat action is missing " + name + ".");
      switch (Required("action"))
      {
        case "sideQuestion": ChatDraftWorkspace.Require(id).SideQuestion.SetQuestion(Required("text"), value.GetProperty("expectedRevision").GetInt64(), value.TryGetProperty("append", out var appendQuestion) && appendQuestion.GetBoolean()); break;
        case "sideBriefPrepare": return Value(ChatDraftWorkspace.Require(id).SideQuestion.Prepare(chat));
        case "sideBriefEdit": ChatDraftWorkspace.Require(id).SideQuestion.EditBrief(Required("text"), value.GetProperty("expectedRevision").GetInt64(), value.TryGetProperty("append", out var append) && append.GetBoolean()); break;
        case "draftEditorPrepare": case "draftEditorImport": case "draftEditorDiscard":
          var copies = new ChatDraftEditorCopies(chats.DataRoot ?? throw new McpRefusal("This chat has no private editor folder."));
          var buffer = ChatDraftWorkspace.Require(id);
          chat = await chats.ReadAsync(id, ct);
          if (Required("action") == "draftEditorPrepare") return Value(new { editorCopy = copies.Prepare(chat, buffer), draft = buffer.Read() });
          if (Required("action") == "draftEditorImport") copies.Import(chat, buffer); else copies.Discard(buffer);
          break;
        case "openControl":
          var target = Required("control");
          if (target is not ("model" or "effort" or "account" or "permission" or "environment" or "fullPrompt" or "promptSearch" or "eventLog" or "usage" or "modelTiming" or "find" or "rename" or "changes" or "history" or "inspector" or "editorCopy" or "connections" or "skills" or "instructions" or "commands" or "sideQuestion" or "commandOutput")) throw new McpRefusal("Choose an available chat control.");
          ChatDraftWorkspace.Require(id).OpenControl(target); break;
        case "draftApply": case "draftAppend":
          if (chat.Ended) throw new McpRefusal("This chat ended. Its draft is kept without sending.");
          if (!value.TryGetProperty("expectedRevision", out var revision) || !revision.TryGetInt64(out var expected)) throw new McpRefusal("Read the current draft revision before editing.");
          ChatDraftWorkspace.Require(id).Apply(Required("text"), expected, Required("action") == "draftAppend");
          break;
        case "send": await chats.SendAsync(id, Required("clientId"), Required("text"), await images.ResolveAsync(id, context.Grant.CallerId, value, ct), ct); break;
        case "sendNow": await chats.SendNowAsync(id, Required("clientId"), ct); break;
        case "edit": await chats.EditQueuedAsync(id, Required("clientId"), Required("text"), ct); break;
        case "remove": await chats.RemoveQueuedAsync(id, Required("clientId"), ct); break;
        case "answer": await chats.AnswerAsync(id, Required("requestId"), value.GetProperty("allow").GetBoolean(), ct); break;
        case "continue": await chats.ContinueWithoutResendingAsync(id, ct); break;
        case "end": await chats.EndAsync(id, ct); break;
        case "retry": await chats.RetryAsync(id, ct); break;
        case "reconnect": await chats.ReconnectAsync(id, ct); break;
        case "imageBegin": case "imageChunk": case "imageFinish": return Value(await images.ApplyAsync(id, context.Grant.CallerId, value, ct));
        case "account":
          throw new McpRefusal("Use sessions.account so the existing account-change permission applies.");
        case "signIn": throw new McpRefusal("Use accounts.sign_in so the existing sign-in permission applies.");
        default: throw new McpRefusal("Choose send, sendNow, edit, remove, answer, continue, end, retry, reconnect, draftApply, draftAppend, draftEditorPrepare, draftEditorImport, draftEditorDiscard, openControl, imageBegin, imageChunk or imageFinish.");
      }
    }
    else throw new McpRefusal("This chat tool is unavailable.");
    return View(chats.Get(id));
  }
  public async ValueTask<JsonElement> StartAsync(McpCallContext context, JsonElement arguments, AccountService accounts, IDeckSessionStarter starter, CancellationToken ct)
  {
    var folder = arguments.GetProperty("cwd").GetString() ?? throw new McpRefusal("Choose a folder."); context.Require("folders", folder);
    var provider = arguments.TryGetProperty("provider", out var p) ? p.GetString()! : "claude";
    var account = arguments.TryGetProperty("account", out var a) ? accounts.Get(a.GetString()!) : accounts.Preferred(provider, folder) ?? throw new McpRefusal("Choose an account before starting this chat.");
    context.Require("accounts", account.Id);
    var prepared = await starter.PrepareAsync(arguments, account, ct);
    if (prepared.Cwd != folder || prepared.Provider != account.Provider || prepared.AccountId != account.Id || prepared.AccountHome != account.HomeId) throw new McpRefusal("This chat launch does not match the chosen folder and account.");
    var options = new ChatOptions();
    if (arguments.TryGetProperty("differ", out var differ)) options = new(ChatLineProtocol.S(differ, "model"), ChatLineProtocol.S(differ, "effort"));
    await context.EnsureCurrentAsync(ct);
    var chat = await chats.CreateAsync(new(prepared.Id, prepared.Provider, prepared.Cwd, prepared.Title, account.Id, account.HomeId, options, PermissionMode: (defaultPermission ?? (p => ChatPermissionModes.DefaultFor(p)))(prepared.Provider)), prepared.ConversationId, ct);
    context.NoteStarted(chat.Definition.Id); return View(chat);
  }
  public void Dispose() => images.Dispose();
  public static JsonElement View(ChatRecord chat) => Value(new
  {
    chatActions = new[] { "send", "sendNow", "edit", "remove", "answer", "continue", "end", "retry", "reconnect", "draftApply", "draftAppend", "sideQuestion", "sideBriefPrepare", "sideBriefEdit", "draftEditorPrepare", "draftEditorImport", "draftEditorDiscard", "openControl", "imageBegin", "imageChunk", "imageFinish" },
    openControls = new[] { "model", "effort", "account", "permission", "environment", "fullPrompt", "promptSearch", "eventLog", "usage", "modelTiming", "find", "rename", "changes", "history", "inspector", "editorCopy", "connections", "skills", "instructions", "commands", "sideQuestion", "commandOutput" },
    id = chat.Definition.Id, provider = chat.Definition.Provider, cwd = chat.Definition.Cwd, title = chat.Definition.Title,
    mode = "chat", accountId = chat.Definition.AccountId, options = chat.Definition.Options, conversationId = chat.ConversationId,
    sideQuestion = ChatDraftWorkspace.ReadSideQuestion(chat.Definition.Id),
    draft = ChatDraftWorkspace.Read(chat.Definition.Id) is { } draft ? new { revision = draft.Revision, preview = draft.Text[..Math.Min(draft.Text.Length, 4000)], characters = draft.Text.Length, source = "unsent app draft" } : null,
    ended = chat.Ended, busy = chat.Busy, stopping = chat.Stopping, problem = chat.Problem, sequence = chat.Events.LastOrDefault()?.Sequence ?? 0,
    renderedToolBlocks = ChatMcpApps.RenderedBlocks(chat.Definition.Id),
    renderedMessages = ChatProjection.Rows(chat).Where(r => r.Kind is "user" or "assistant").TakeLast(200).Select(r => new { r.Id, r.Kind, blocks = ChatRichContent.Blocks(r.Text) }),
    events = chat.Events.TakeLast(200), messages = chat.Messages.Where(m => m.State != ChatMessageState.Removed).TakeLast(100)
  });
}
