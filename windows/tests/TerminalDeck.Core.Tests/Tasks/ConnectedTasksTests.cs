using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Tasks;

namespace TerminalDeck.Core.Tests.Tasks;

public sealed class ConnectedTasksTests
{
  private sealed class Gateway : IConnectedTaskGateway
  {
    public List<(string Tool, JsonElement Args)> Calls = [];
    public static JsonElement Schema(object value) => JsonSerializer.SerializeToElement(value);
    public ValueTask<IReadOnlyList<ConnectedTaskServer>> ServersAsync(CancellationToken ct) => ValueTask.FromResult<IReadOnlyList<ConnectedTaskServer>>([new("saved-server", "iLoop", "https://fixture.invalid/mcp")]);
    public ValueTask<IReadOnlyList<McpRemoteTool>> ToolsAsync(string server, CancellationToken ct) => ValueTask.FromResult<IReadOnlyList<McpRemoteTool>>([
      new("list_tasks", Schema(new { type = "object", properties = new { limit = new { type = "integer" }, include_done = new { type = "boolean" } }, additionalProperties = false })),
      new("get_task", Schema(new { type = "object", properties = new { task_id = new { type = "string" } }, required = new[] { "task_id" } })),
      new("set_task_status", Schema(new { type = "object", properties = new { task_id = new { type = "string" }, status = new { type = "string", @enum = new[] { "Open", "Closed" } } }, required = new[] { "task_id", "status" } })),
      new("add_comment", Schema(new { type = "object", properties = new { task_id = new { type = "string" }, body = new { type = "string" } }, required = new[] { "task_id", "body" } }))
    ]);
    public ValueTask<JsonElement> CallAsync(string server, string tool, JsonElement args, CancellationToken ct)
    {
      Calls.Add((tool, args));
      return ValueTask.FromResult(tool switch
      {
        "list_tasks" => Schema(new { tasks = new[] { new { id = "remote-one", title = "Read the report", status = "Open", assignedToMe = true }, new { id = "closed", title = "Finished work", status = "Closed", assignedToMe = false } } }),
        "get_task" => Schema(new { id = "remote-one", title = "Read the report", status = "Open", description = "Keep the external system's words." }),
        _ => Schema(new { ok = true })
      });
    }
  }
  [Fact] public async Task ILoopShapeIsDiscoveredFromSavedMcpAndReadsPreserveExternalWords()
  {
    var f = new TaskFixture(); var gateway = new Gateway(); var service = new ConnectedTasksService(new MemoryStore<ConnectedTasksState>(), gateway, f.Projects);
    var system = await service.ConnectExistingAsync("iLoop", "https://fixture.invalid/mcp", "sample", "off");
    var row = Assert.Single(await service.ListAsync(system.Id)); Assert.Equal("Open", row.Status); Assert.True(row.AssignedToMe);
    Assert.Equal(200, gateway.Calls[0].Args.GetProperty("limit").GetInt32()); Assert.Equal(2, (await service.ListAsync(system.Id, includeDone: true)).Count);
    var task = await service.GetAsync(system.Id, row.Id); Assert.Equal("Keep the external system's words.", task.GetProperty("description").GetString());
    Assert.Equal("remote-one", gateway.Calls.Last().Args.GetProperty("task_id").GetString());
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await service.CommentAsync(system.Id, row.Id, "not allowed"));
    Assert.DoesNotContain(gateway.Calls, c => c.Tool == "add_comment");
  }
  [Fact] public async Task ExternalWritesNeedEnabledChangesAndCurrentAuthorityAfterDiscovery()
  {
    var f = new TaskFixture(); var gateway = new Gateway(); var service = new ConnectedTasksService(new MemoryStore<ConnectedTasksState>(), gateway, f.Projects);
    var system = await service.ConnectExistingAsync("iLoop", "https://fixture.invalid/mcp", "sample", "ask");
    await Assert.ThrowsAsync<InvalidOperationException>(async () => await service.UpdateAsync(system.Id, "remote-one", "Closed", null, null, false,
      current: _ => throw new InvalidOperationException("Permission changed.")));
    Assert.Empty(gateway.Calls);
    await Assert.ThrowsAsync<McpRefusal>(async () => await service.UpdateAsync(system.Id, "remote-one", "Invented", null, null, false));
    await service.UpdateAsync(system.Id, "remote-one", "Closed", null, null, false);
    await service.CommentAsync(system.Id, "remote-one", "Reviewed.");
    Assert.Equal("set_task_status", gateway.Calls[0].Tool); Assert.Equal("Closed", gateway.Calls[0].Args.GetProperty("status").GetString());
    Assert.Equal("add_comment", gateway.Calls[1].Tool); Assert.Equal("Reviewed.", gateway.Calls[1].Args.GetProperty("body").GetString());
  }
  [Fact] public void RemoteMcpErrorAndMalformedRowsAreNotReportedAsEmptySuccess()
  {
    Assert.Throws<InvalidOperationException>(() => ConnectedTaskMapping.Unwrap(Gateway.Schema(new { isError = true, content = new[] { new { type = "text", text = "Refused" } } })));
    Assert.Throws<InvalidOperationException>(() => ConnectedTaskMapping.Rows(Gateway.Schema(new { unexpected = true })));
    var data = ConnectedTaskMapping.Unwrap(Gateway.Schema(new { content = new[] { new { type = "text", text = "{\"tasks\":[]}" } } })); Assert.Empty(ConnectedTaskMapping.Rows(data));
  }
}
