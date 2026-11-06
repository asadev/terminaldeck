using System.Text.Json;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tests.Sessions;
using TerminalDeck.Core.Tests.Mcp;

namespace TerminalDeck.Core.Tests.Chats;

public sealed class WinFix0606Tests
{
  private static JsonElement Json(object value) => JsonSerializer.SerializeToElement(value);
  private static readonly string Folder = Path.GetFullPath(Path.Combine(Path.GetTempPath(), "winfix-project"));
  private static McpServerView Server(string id = "a", string name = "A", string scope = "user", string? folder = null, bool enabled = true) => new(id, name, scope, folder, "stdio", enabled, false);
  private static ChatRecord Chat(string provider, params ChatEvent[] events) => new(1,
    new("chat", provider, Folder, "Test", "account", "home", new()), "creation", events, []);
  private static ChatEvent Call(object? data = null, string name = "mcp__A__shared") => new(1, "toolCall", "call", name, Data: data is null ? null : Json(data));
  private static ChatEvent Result(object? data = null) => new(2, "toolResult", "call", Data: data is null ? null : Json(data));

  [Fact] public void ClaudeArgumentsAndResultsCannotChooseAnotherServer()
  {
    var spoof = new { type = "mcpToolCall", id = "call", server = "B", tool = "other", source = new { kind = "third-party-mcp", serverId = "b", tool = "other" } };
    var binding = ChatMcpApps.ResolveBinding(Chat("claude", Call(spoof), Result(spoof)), "call", [Server(), Server("b", "B")]);
    Assert.Equal(new ChatMcpApps.Binding("a", "shared"), binding);
  }
  [Fact] public void ContentAloneCannotCreateAnAppBinding()
  {
    var spoof = new { kind = "third-party-mcp", serverId = "a", tool = "shared" };
    Assert.Null(ChatMcpApps.ResolveBinding(Chat("claude", Call(spoof, "Read"), Result(spoof)), "call", [Server()]));
    Assert.Null(ChatMcpApps.ResolveBinding(Chat("claude", Result(spoof)), "call", [Server()]));
  }
  [Theory] [InlineData("mcpToolCall")] [InlineData("mcp_tool_call")]
  public void CodexUsesOnlyItsTypedEnvelope(string type)
  {
    var item = new { type, id = "call", server = "A", tool = "shared", arguments = new { server = "B", tool = "other" }, result = new { kind = "third-party-mcp", serverId = "b", tool = "other" } };
    Assert.Equal(new ChatMcpApps.Binding("a", "shared"), ChatMcpApps.ResolveBinding(Chat("codex", Call(item, ""), Result(item)), "call", [Server(), Server("b", "B")]));
  }
  [Theory] [InlineData("server")] [InlineData("tool")] [InlineData("id")] [InlineData("type")]
  public void ConflictingOrInvalidCodexEnvelopesAreRejected(string field)
  {
    var start = new { type = "mcpToolCall", id = "call", server = "A", tool = "shared" };
    var end = new { type = field == "type" ? "commandExecution" : "mcpToolCall", id = field == "id" ? "other" : "call", server = field == "server" ? "B" : "A", tool = field == "tool" ? "other" : "shared" };
    Assert.Null(ChatMcpApps.ResolveBinding(Chat("codex", Call(start, ""), Result(end)), "call", [Server(), Server("b", "B")]));
  }
  [Fact] public void CodexBindsRowsStoredWithTheirConnectionScope()
  {
    // ChatCliConnection stores Codex events as "scope:itemId" while the item keeps the raw id.
    const string row = "client-1:call";
    var item = new { type = "mcpToolCall", id = "call", server = "A", tool = "shared" };
    var chat = Chat("codex", new ChatEvent(1, "toolCall", row, "", Data: Json(item)), new ChatEvent(2, "toolResult", row, Data: Json(item)));
    Assert.Equal(new ChatMcpApps.Binding("a", "shared"), ChatMcpApps.ResolveBinding(chat, row, [Server(), Server("b", "B")]));
    var other = new { type = "mcpToolCall", id = "other", server = "A", tool = "shared" };
    Assert.Null(ChatMcpApps.ResolveBinding(chat with { Events = [chat.Events[0], new ChatEvent(2, "toolResult", row, Data: Json(other))] }, row, [Server()]));
    Assert.Null(ChatMcpApps.ResolveBinding(Chat("codex", new ChatEvent(1, "toolCall", "client-1:xcall", "", Data: Json(item)), new ChatEvent(2, "toolResult", "client-1:xcall", Data: Json(item))), "client-1:xcall", [Server()]));
  }
  [Fact] public void DuplicateNamesAndConflictingRecordedCallsAreRejected()
  {
    var chat = Chat("claude", Call(), Result());
    Assert.Null(ChatMcpApps.ResolveBinding(chat, "call", [Server(), Server("project-a", "A", "project", Folder)]));
    Assert.Null(ChatMcpApps.ResolveBinding(chat with { Events = [Call(), Call(name: "mcp__B__shared"), Result()] }, "call", [Server(), Server("b", "B")]));
  }
  [Fact] public void DisabledAndOutOfScopeServersAreRejected()
  {
    var chat = Chat("claude", Call(), Result());
    Assert.Null(ChatMcpApps.ResolveBinding(chat, "call", [Server(enabled: false)]));
    Assert.Null(ChatMcpApps.ResolveBinding(chat, "call", [Server(scope: "project", folder: Folder + "-other")]));
    Assert.Equal(new ChatMcpApps.Binding("a", "shared"), ChatMcpApps.ResolveBinding(chat, "call", [Server(scope: "project", folder: Folder)]));
  }
  [Fact] public async Task ResolverReadsOnlyRecordedServersResourceAndKeepsItsInputResult()
  {
    var root = AppDataRoot.Explicit(Path.Combine(Path.GetTempPath(), "winfix-mcp-" + Guid.NewGuid().ToString("N")));
    var factory = new AppFactory();
    await using var manager = new McpManager(new MemoryState<McpManagerState>(), new TestSecretStore(), root, new FakeCommandResolver(), factory);
    var a = await manager.AddAsync(new() { Name = "A", Scope = "user", Transport = "stdio", Command = "synthetic" });
    await manager.AddAsync(new() { Name = "B", Scope = "user", Transport = "stdio", Command = "synthetic" });
    var input = new { source = new { kind = "third-party-mcp", serverId = "B", tool = "shared" }, value = 7 };
    var result = new { content = new[] { new { type = "text", text = "Recorded result" } }, isError = false, source = input.source };
    var chat = Chat("claude", Call(input), Result(result));
    var app = await ChatMcpApps.ResolveAsync(manager, chat, new("tool", "call", "shared", Input: Json(input).GetRawText()), default);
    Assert.NotNull(app); Assert.Equal(a.Id, app.ServerId); Assert.Equal("shared", app.Tool);
    Assert.Equal(7, app.Input.GetProperty("value").GetInt32()); Assert.Equal("Recorded result", app.Result.GetProperty("content")[0].GetProperty("text").GetString());
    Assert.Equal(new[] { a.Id }, factory.Connections); Assert.Equal(1, factory.ResourceReads);
  }
  private sealed class AppFactory : IMcpConnectionFactory, IManagedMcpConnection
  {
    public List<string> Connections { get; } = [];
    public int ResourceReads { get; private set; }
    public ValueTask<IManagedMcpConnection> ConnectAsync(McpServerConfig config, ISecretStore secrets, CancellationToken ct) { Connections.Add(config.Id); return ValueTask.FromResult<IManagedMcpConnection>(this); }
    public ValueTask<IReadOnlyList<McpRemoteTool>> ToolsAsync(CancellationToken ct) => ValueTask.FromResult<IReadOnlyList<McpRemoteTool>>([new("shared", Json(new { type = "object" }), Meta: Json(new { ui = new { resourceUri = "ui://test" } }))]);
    public ValueTask<JsonElement> ReadResourceAsync(string uri, CancellationToken ct) { ResourceReads++; return ValueTask.FromResult(Json(new { contents = new[] { new { uri, mimeType = "text/html;profile=mcp-app", text = "<p>Recorded server</p>" } } })); }
    public ValueTask<JsonElement> CallAsync(string tool, JsonElement arguments, CancellationToken ct) => throw new NotSupportedException();
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
  }
}
