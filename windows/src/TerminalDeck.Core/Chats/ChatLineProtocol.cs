using System.Text.Json;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Chats;

public sealed record ChatProtocolUpdate(string[] Writes, ChatSignal[] Signals, bool Ready = false);

// Fresh protocol implementation; provider messages stay structured all the way
// to the view. Full messages replace partial text using their provider id.
public sealed class ChatLineProtocol(ChatRecord chat, IChatHistory media, bool codexAppServer = false, object[]? mcpServers = null)
{
  public const int MaximumLineCharacters = 16 * 1024 * 1024;
  private readonly string provider = chat.Definition.Provider;
  private string messageId = "";
  private string? conversation = chat.ConversationId;
  private string? turnId;
  private string? clientId;
  private bool images;
  private bool rpcReady;
  private bool contextSent;
  private readonly Dictionary<int, string> tools = [];
  private readonly Dictionary<int, System.Text.StringBuilder> toolInputs = [];
  private readonly Dictionary<string, JsonElement> approvalInputs = [];
  public string? ConversationId => conversation;
  public bool IsRpc => provider == "gemini" || provider == "codex" && codexAppServer;
  public static string Json(object value) => JsonSerializer.Serialize(value);
  private static JsonElement Element(object value) => JsonSerializer.SerializeToElement(value);
  public static string Rpc(string method, object? parameters = null, string? id = null) => id is null
    ? Json(new { jsonrpc = "2.0", method, @params = parameters ?? new { } })
    : Json(new { jsonrpc = "2.0", id, method, @params = parameters ?? new { } });
  public string? Begin() => !IsRpc ? null : provider == "codex"
    ? Rpc("initialize", new { clientInfo = new { name = "terminaldeck", version = "1" }, capabilities = new { experimentalApi = true } }, "hello")
    : Rpc("initialize", new { protocolVersion = 1, clientInfo = new { name = "terminaldeck", version = "1" }, clientCapabilities = new { terminal = false } }, "hello");
  public string User(ChatMessage message)
  {
    clientId = message.ClientId; messageId = ""; turnId = null; approvalInputs.Clear();
    var content = new List<object>();
    var replay = chat.ReplayHistory && !contextSent && chat.ConversationId is null;
    var text = ChatRichContent.Prompt(chat with { ReplayHistory = replay }, message.Text, drawing: !contextSent && provider != "codex");
    if (text.Length > 0) content.Add(new { type = "text", text });
    foreach (var attachment in (replay ? chat.Messages.SelectMany(m => m.Media).Concat(message.Media).DistinctBy(m => m.Id) : message.Media))
    {
      var bytes = media.ReadMedia(chat.Definition.Id, attachment);
      var data = Convert.ToBase64String(bytes);
      if (attachment.MimeType == "application/pdf" && provider != "claude") throw new InvalidOperationException("This coding AI connection does not accept PDF documents.");
      if (provider == "claude") content.Add(new { type = attachment.MimeType == "application/pdf" ? "document" : "image", source = new { type = "base64", media_type = attachment.MimeType, data } });
      else if (provider == "codex") content.Add(new { type = "image", url = "data:" + attachment.MimeType + ";base64," + data });
      else
      {
        if (!images) throw new InvalidOperationException("Gemini has not offered image attachments for this chat.");
        content.Add(new { type = "image", mimeType = attachment.MimeType, data });
      }
    }
    contextSent = true;
    if (provider == "claude") return Json(new { type = "user", uuid = message.ClientId, message = new { role = "user", content } });
    if (!IsRpc) throw new InvalidOperationException("Codex exec receives each message through its own input pipe.");
    if (conversation is null) throw new InvalidOperationException("This chat is still connecting.");
    return provider == "codex"
      ? Rpc("turn/start", new { threadId = conversation, input = content, effort = Empty(chat.Definition.Options.Effort) }, "turn:" + message.ClientId)
      : Rpc("session/prompt", new { sessionId = conversation, prompt = content }, "turn:" + message.ClientId);
  }
  private static string? Empty(string value) => value is "" or "auto" ? null : value;
  public string Interrupt() => provider == "claude"
    ? Json(new { type = "control_request", request_id = Guid.NewGuid().ToString(), request = new { subtype = "interrupt" } })
    : provider == "codex" && codexAppServer
      ? turnId is null ? throw new InvalidOperationException("Codex has not acknowledged this answer yet. Try Stop again in a moment.") : Rpc("turn/interrupt", new { threadId = conversation, turnId }, "interrupt:" + Guid.NewGuid().ToString())
      : Rpc("session/cancel", new { sessionId = conversation });
  public string Answer(string requestId, bool allow, JsonElement data)
  {
    if (allow && chat.Definition.PermissionMode == AiPermissionMode.Plan) throw new InvalidOperationException("Plan only cannot approve changes. Choose a different permission mode first.");
    if (!approvalInputs.TryGetValue(requestId, out data)) throw new InvalidOperationException("That approval is no longer waiting.");
    if (provider == "claude")
    {
      var input = data.TryGetProperty("input", out var value) ? value : Element(new { });
      object response = allow ? new { behavior = "allow", updatedInput = input } : new { behavior = "deny", message = "The person refused this request." };
      return Json(new { type = "control_response", response = new { subtype = "success", request_id = requestId, response } });
    }
    var rpcId = data.GetProperty("rpcId"); var method = data.GetProperty("method").GetString();
    object result;
    if (provider == "gemini")
    {
      var parameters = data.GetProperty("input");
      var option = parameters.GetProperty("options").EnumerateArray().FirstOrDefault(o => S(o, "kind") == (allow ? "allow_once" : "reject_once"));
      if (option.ValueKind == JsonValueKind.Undefined && allow) throw new InvalidOperationException("Gemini did not offer a one-use approval.");
      result = option.ValueKind == JsonValueKind.Undefined ? new { outcome = new { outcome = "cancelled" } } : new { outcome = new { outcome = "selected", optionId = S(option, "optionId") } };
    }
    else if (method == "item/permissions/requestApproval")
      result = new { permissions = allow ? data.GetProperty("input").GetProperty("permissions") : Element(new { }), scope = "turn" };
    else result = new { decision = allow ? "accept" : "decline" };
    return Json(new { jsonrpc = "2.0", id = rpcId, result });
  }
  public ChatProtocolUpdate Receive(string line)
  {
    if (line.Length > MaximumLineCharacters) throw new IOException("The coding AI returned a message that is too large.");
    JsonElement row;
    try { using var doc = JsonDocument.Parse(line); row = doc.RootElement.Clone(); }
    catch (JsonException)
    {
      if (line.TrimStart().StartsWith('{') || line.TrimStart().StartsWith('[')) throw new IOException("The coding AI returned malformed chat output.");
      var error = ChatErrors.FromProvider(provider, line);
      return new([], error == ChatErrors.NotSignedIn(provider) ? [new(0, "error", Text: error)] : []);
    }
    var update = IsRpc ? ReceiveRpc(row) : provider == "claude" ? ReceiveClaude(row) : ReceiveExec(row);
    if (update.Signals.Any(s => s.Kind is "complete" or "error")) approvalInputs.Clear();
    foreach (var signal in update.Signals)
    {
      if (signal.Kind == "approvalResolved") approvalInputs.Remove(signal.Id);
      if (signal.Kind == "approval" && signal.Data is { } original)
      {
        if (approvalInputs.Count >= 64 && !approvalInputs.ContainsKey(signal.Id)) throw new IOException("The coding AI has too many unanswered requests.");
        // The journal gets media references; a live CLI must receive the exact
        // original tool input when its person allows this request.
        if (approvalInputs.TryGetValue(signal.Id, out var previous) && !JsonElement.DeepEquals(previous, original)) throw new IOException("The coding AI reused a request id with different details.");
        approvalInputs[signal.Id] = original;
      }
    }
    var signals = update.Signals.Select(signal =>
    {
      var text = signal.Text;
      if (signal.Kind is "toolResult" or "toolInputDelta" && text.StartsWith("data:", StringComparison.Ordinal))
        text = media.ExternalizeData(chat.Definition.Id, Element(text)).GetRawText();
      if (signal.Kind is "toolResult" or "toolInputDelta" && (text.StartsWith('{') || text.StartsWith('[')))
      {
        try { using var document = JsonDocument.Parse(text); text = media.ExternalizeData(chat.Definition.Id, document.RootElement).GetRawText(); }
        catch (JsonException) { }
      }
      return signal with { Text = text, Data = signal.Data is { ValueKind: not JsonValueKind.Undefined } data ? media.ExternalizeData(chat.Definition.Id, data) : null };
    }).ToArray();
    return update with { Signals = signals };
  }
  private ChatProtocolUpdate ReceiveClaude(JsonElement row)
  {
    var signals = new List<ChatSignal>(); var type = S(row, "type");
    var child = S(row, "parent_tool_use_id").Length > 0;
    if (child && type is not ("control_request" or "control_cancel_request")) return new([], []);
    if (!child && S(row, "session_id") is { Length: > 0 } session && session != conversation)
    { conversation = session; signals.Add(new(0, "conversation", Text: session)); }
    switch (type)
    {
      case "system" when S(row, "subtype") == "init":
        signals.Add(new(0, "providerInit", "provider:" + chat.CreationKey, Data: ChatProviderSnapshot.Capture(provider, chat.CreationKey, row))); break;
      case "user":
        if (S(row, "uuid") is { Length: > 0 } uuid) signals.Add(new(0, "accepted", ClientId: uuid));
        foreach (var block in A(P(row, "message"), "content"))
          if (S(block, "type") == "tool_result") signals.Add(new(0, "toolResult", S(block, "tool_use_id"), TextValue(P(block, "content")), Data: block));
        break;
      case "stream_event":
        var ev = P(row, "event"); var index = P(ev, "index"); var blockIndex = index.ValueKind == JsonValueKind.Number && index.TryGetInt32(out var i) ? i : -1;
        switch (S(ev, "type"))
        {
          case "message_start":
            var startedMessage = P(ev, "message"); messageId = S(startedMessage, "id"); tools.Clear(); toolInputs.Clear();
            if (messageId.Length > 0) signals.Add(new(0, "requestStarted", messageId, ClientId: clientId, Data: Element(new { creationKey = chat.CreationKey, model = S(startedMessage, "model"), usage = P(startedMessage, "usage").ValueKind == JsonValueKind.Object ? P(startedMessage, "usage") : Element(new { }) })));
            break;
          case "message_delta":
            if (messageId.Length > 0 && P(ev, "usage").ValueKind == JsonValueKind.Object) signals.Add(new(0, "requestUsage", messageId, ClientId: clientId, Data: Element(new { creationKey = chat.CreationKey, usage = P(ev, "usage") })));
            break;
          case "content_block_start":
            var block = P(ev, "content_block");
            if (S(block, "type") == "tool_use") { var tool = S(block, "id"); tools[blockIndex] = tool; toolInputs[blockIndex] = new(); signals.Add(new(0, "toolCall", tool, S(block, "name"), Data: P(block, "input"))); }
            break;
          case "content_block_delta":
            var delta = P(ev, "delta");
            if (S(delta, "type") == "thinking_delta") signals.Add(new(0, "reasoningDelta", messageId + ":thought:" + blockIndex, S(delta, "thinking"), clientId));
            if (S(delta, "type") == "text_delta") signals.Add(new(0, "textDelta", messageId, S(delta, "text"), clientId));
            if (S(delta, "type") == "input_json_delta" && toolInputs.TryGetValue(blockIndex, out var input))
            {
              input.Append(S(delta, "partial_json"));
              if (input.Length > MaximumLineCharacters) throw new IOException("The tool input is too large.");
            }
            break;
          case "content_block_stop":
            if (toolInputs.Remove(blockIndex, out var assembled) && assembled.Length > 0 && tools.TryGetValue(blockIndex, out var toolId))
            {
              using var inputDocument = JsonDocument.Parse(assembled.ToString());
              var safe = media.ExternalizeData(chat.Definition.Id, inputDocument.RootElement);
              signals.Add(new(0, "toolInputDelta", toolId, safe.GetRawText()));
            }
            break;
        }
        break;
      case "assistant":
        var message = P(row, "message"); var id = S(message, "id"); if (id.Length == 0) id = messageId;
        var text = string.Concat(A(message, "content").Where(b => S(b, "type") == "text").Select(b => S(b, "text")));
        if (text.Length > 0) signals.Add(new(0, B(row, "is_api_error_message") ? "error" : "message", id, B(row, "is_api_error_message") ? ChatErrors.FromProvider(provider, text) : text, clientId));
        if (id.Length > 0 && P(message, "usage").ValueKind == JsonValueKind.Object) signals.Add(new(0, "requestUsage", id, ClientId: clientId, Data: Element(new { creationKey = chat.CreationKey, model = S(message, "model"), usage = P(message, "usage") })));
        foreach (var tool in A(message, "content").Where(b => S(b, "type") == "tool_use")) signals.Add(new(0, "toolCall", S(tool, "id"), S(tool, "name"), Data: P(tool, "input")));
        break;
      case "control_request":
        var request = P(row, "request");
        if (S(request, "subtype") != "can_use_tool")
          return new([Json(new { type = "control_response", response = new { subtype = "error", request_id = S(row, "request_id"), error = "This question is not supported by this chat." } })], signals.ToArray());
        // App tools that only read never ask (Mac: same); the change tools still reach the person.
        if (TerminalDeck.Core.Mcp.DeckToolReads.Quiet(S(request, "tool_name"), P(request, "input")))
          return new([Json(new { type = "control_response", response = new { subtype = "success", request_id = S(row, "request_id"), response = new { behavior = "allow", updatedInput = P(request, "input").ValueKind == JsonValueKind.Object ? P(request, "input") : Element(new { }) } } })], signals.ToArray(), true);
        signals.Add(new(0, "approval", S(row, "request_id"), S(request, "tool_name"), Data: request));
        break;
      case "control_cancel_request": signals.Add(new(0, "approvalResolved", S(row, "request_id"), "Cancelled")); break;
      case "result":
        if (P(row, "usage").ValueKind == JsonValueKind.Object)
          signals.Add(new(0, "usage", "usage:" + clientId, ClientId: clientId, Data: Element(new { source = "Claude turn result", usage = P(row, "usage"), totalCostUsd = P(row, "total_cost_usd").ValueKind == JsonValueKind.Number ? P(row, "total_cost_usd").GetDecimal() : (decimal?)null })));
        if (B(row, "is_error") || S(row, "subtype") != "success")
          signals.Add(new(0, "error", Text: ChatErrors.FromProvider(provider, S(row, "result") + TextValue(P(row, "errors"))), ClientId: clientId));
        else signals.Add(new(0, "complete", ClientId: clientId));
        break;
    }
    return new([], signals.ToArray(), true);
  }
  private ChatProtocolUpdate ReceiveExec(JsonElement row)
  {
    var type = S(row, "type"); var signals = new List<ChatSignal>();
    if (type == "thread.started") { conversation = S(row, "thread_id"); signals.Add(new(0, "conversation", Text: conversation)); }
    if (type is "item.started" or "item.updated" or "item.completed")
    {
      var item = P(row, "item"); var kind = S(item, "type"); var id = S(item, "id");
      if (kind == "agent_message") signals.Add(new(0, "message", id, S(item, "text"), clientId));
      if (kind == "command_execution") signals.Add(new(0, type == "item.completed" ? "toolResult" : "toolCall", id, type == "item.completed" ? S(item, "aggregated_output") : S(item, "command")));
      if (kind == "file_change") signals.Add(new(0, "toolResult", id, TextValue(P(item, "changes")), Data: item));
    }
    if (type is "error" or "turn.failed") signals.Add(new(0, "error", Text: ChatErrors.FromProvider(provider, S(row, "message") + S(P(row, "error"), "message")), ClientId: clientId));
    if (type == "turn.completed")
    {
      if (P(row, "usage").ValueKind == JsonValueKind.Object) signals.Add(new(0, "usage", "usage:" + clientId, ClientId: clientId, Data: Element(new { source = "Codex turn result", usage = P(row, "usage") })));
      signals.Add(new(0, "complete", ClientId: clientId));
    }
    return new([], signals.ToArray(), true);
  }
  private ChatProtocolUpdate GeminiReady(ChatSignal[] signals)
  {
    if (chat.Definition.Options.Model.Length > 0)
      return new([Rpc("session/set_model", new { sessionId = conversation, modelId = chat.Definition.Options.Model }, "model")], signals);
    rpcReady = true; return new([], signals, true);
  }
  private ChatProtocolUpdate ReceiveRpc(JsonElement row)
  {
    var id = S(row, "id"); var result = P(row, "result");
    if (P(row, "error").ValueKind == JsonValueKind.Object)
      return new([], [new(0, "error", Text: ChatErrors.FromProvider(provider, S(P(row, "error"), "message")), ClientId: clientId)]);
    if (id == "hello")
    {
      if (provider == "gemini")
      {
        if (!P(result, "protocolVersion").TryGetInt32(out var version) || version != 1) throw new IOException("Gemini returned an unsupported chat connection.");
        var capabilities = P(result, "agentCapabilities"); images = B(P(capabilities, "promptCapabilities"), "image");
        if (conversation is not null && !B(capabilities, "loadSession")) throw new IOException("This Gemini version cannot resume the saved conversation.");
      }
      object parameters = provider == "codex"
        ? new { cwd = chat.Definition.Cwd, model = Empty(chat.Definition.Options.Model), approvalPolicy = ChatPermissionModes.CodexApproval(chat.Definition.PermissionMode), sandbox = ChatPermissionModes.CodexSandbox(chat.Definition.PermissionMode), threadId = conversation, developerInstructions = ChatRichContent.Instruction }
        : new { cwd = chat.Definition.Cwd, mcpServers = mcpServers ?? Array.Empty<object>(), sessionId = conversation };
      var method = provider == "codex" ? conversation is null ? "thread/start" : "thread/resume" : conversation is null ? "session/new" : "session/load";
      return new(provider == "codex" ? [Rpc("initialized"), Rpc(method, parameters, "session")] : [Rpc(method, parameters, "session")], []);
    }
    if (id == "session")
    {
      var actual = provider == "codex" ? S(P(result, "thread"), "id") : S(result, "sessionId");
      if (actual.Length == 0 && provider == "gemini") actual = conversation ?? "";
      if (actual.Length == 0 || conversation is not null && actual != conversation) throw new IOException("The coding AI did not resume the requested conversation.");
      conversation = actual;
      var providerSnapshot = new ChatSignal(0, "providerInit", "provider:" + chat.CreationKey, Data: ChatProviderSnapshot.Capture(provider, chat.CreationKey, result));
      if (provider == "gemini")
      {
        var wanted = ChatPermissionModes.Gemini(chat.Definition.PermissionMode);
        var offered = P(P(result, "modes"), "availableModes");
        if (offered.ValueKind == JsonValueKind.Array)
        {
          if (!offered.EnumerateArray().Any(mode => S(mode, "id") == wanted))
            throw new IOException("This Gemini connection does not support the selected permission mode. No message was sent.");
          return new([Rpc("session/set_mode", new { sessionId = conversation, modeId = wanted }, "permission-mode")], [new(0, "conversation", Text: actual)]);
        }
        if (chat.Definition.PermissionMode != AiPermissionMode.Ask)
          throw new IOException("This Gemini connection did not confirm the selected permission mode. No message was sent.");
        return GeminiReady([new(0, "conversation", Text: actual)]);
      }
      rpcReady = true; return new([], [new(0, "conversation", Text: actual), providerSnapshot], true);
    }
    if (id == "permission-mode" && provider == "gemini") return GeminiReady([]);
    if (id == "model") { rpcReady = true; return new([], [], true); }
    if (id.StartsWith("turn:", StringComparison.Ordinal))
    {
      if (provider == "gemini") return new([], [new(0, "complete", ClientId: id[5..])]);
      turnId = S(P(result, "turn"), "id"); return new([], []);
    }
    var methodName = S(row, "method"); var p = P(row, "params");
    // Refuse unrelated provider threads and unsupported client capabilities.
    var scopedId = S(p, provider == "codex" ? "threadId" : "sessionId");
    if (scopedId.Length > 0 && scopedId != conversation) return new([], []);
    var rawId = P(row, "id");
    if (methodName.Length > 0 && rawId.ValueKind is JsonValueKind.Number or JsonValueKind.String)
    {
      var supported = provider == "gemini" ? methodName == "session/request_permission" : methodName is "item/commandExecution/requestApproval" or "item/fileChange/requestApproval" or "item/permissions/requestApproval";
      if (!rpcReady || !supported) return new([Json(new { jsonrpc = "2.0", id = rawId, error = new { code = -32601, message = "This chat does not provide that capability." } })], []);
      var requestId = rawId.GetRawText(); var name = provider == "gemini" ? S(P(p, "toolCall"), "title") : S(p, "command");
      return new([], [new(0, "approval", requestId, name.Length > 0 ? name : "Allow this tool?", Data: Element(new { rpcId = rawId, method = methodName, input = p }))]);
    }
    if (!rpcReady) return new([], []);
    if (provider == "gemini" && methodName == "session/update")
    {
      var update = P(p, "update"); var kind = S(update, "sessionUpdate"); var toolId = S(update, "toolCallId");
      if (kind == "agent_thought_chunk") return new([], [new(0, "reasoningDelta", "gemini-thought:" + clientId, S(P(update, "content"), "text"), clientId)]);
      if (kind == "agent_message_chunk") return new([], [new(0, "textDelta", "gemini:" + clientId, S(P(update, "content"), "text"), clientId)]);
      if (kind == "tool_call") return new([], [new(0, "toolCall", toolId, S(update, "title"), Data: update)]);
      if (kind == "tool_call_update") return new([], [new(0, "toolResult", toolId, TextValue(P(update, "content")), Data: update)]);
    }
    if (provider == "codex")
    {
      if (methodName == "thread/tokenUsage/updated" && P(p, "tokenUsage").ValueKind == JsonValueKind.Object)
        return new([], [new(0, "usage", "usage:" + S(p, "turnId"), ClientId: clientId, Data: Element(new { source = "Codex thread usage (includes cumulative totals)", creationKey = chat.CreationKey, usage = P(p, "tokenUsage") }))]);
      if (methodName == "turn/started") turnId = S(P(p, "turn"), "id");
      if (methodName == "item/reasoning/summaryTextDelta") return new([], [new(0, "reasoningDelta", S(p, "itemId"), S(p, "delta"), clientId)]);
      if (methodName == "item/agentMessage/delta") return new([], [new(0, "textDelta", S(p, "itemId"), S(p, "delta"), clientId)]);
      if (methodName is "item/started" or "item/completed")
      {
        var item = P(p, "item"); var kind = S(item, "type"); var itemId = S(item, "id");
        if (kind == "contextCompaction" && methodName == "item/completed") return new([], [new(0, "compaction", itemId, "The provider compacted its context.", clientId)]);
        if (kind == "agentMessage" && methodName == "item/completed") return new([], [new(0, "message", itemId, S(item, "text"), clientId)]);
        if (kind is "commandExecution" or "fileChange" or "mcpToolCall") return new([], [new(0, methodName == "item/started" ? "toolCall" : "toolResult", itemId, methodName == "item/started" ? S(item, "command") : S(item, "aggregatedOutput"), Data: item)]);
      }
      if (methodName == "turn/completed")
      {
        var turn = P(p, "turn");
        return new([], [new(0, "providerTurnComplete", S(turn, "id"), ClientId: clientId), S(turn, "status") == "failed" ? new(0, "error", Text: ChatErrors.FromProvider(provider, S(P(turn, "error"), "message")), ClientId: clientId) : new(0, "complete", ClientId: clientId)]);
      }
      if (methodName == "error") return new([], [new(0, "error", Text: ChatErrors.FromProvider(provider, S(P(p, "error"), "message")), ClientId: clientId)]);
    }
    return new([], []);
  }
  public static JsonElement P(JsonElement row, string key) => row.ValueKind == JsonValueKind.Object && row.TryGetProperty(key, out var value) ? value : default;
  public static string S(JsonElement row, string key) => P(row, key).ValueKind == JsonValueKind.String ? P(row, key).GetString()! : "";
  public static bool B(JsonElement row, string key) => P(row, key).ValueKind == JsonValueKind.True;
  private static IEnumerable<JsonElement> A(JsonElement row, string key) => P(row, key).ValueKind == JsonValueKind.Array ? P(row, key).EnumerateArray() : [];
  private static string TextValue(JsonElement value) => value.ValueKind == JsonValueKind.String ? value.GetString()! : value.ValueKind == JsonValueKind.Undefined ? "" : value.GetRawText();
}
