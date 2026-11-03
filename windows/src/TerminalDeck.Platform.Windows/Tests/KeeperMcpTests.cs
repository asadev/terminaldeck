using System.Diagnostics;
using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Platform.Windows.Tests;

public sealed class KeeperMcpTests
{
  [Fact(Timeout = 60000)]
  public async Task PermissionCheckedMcpUsesRealKeeperAndWorker()
  {
    var root = AppDataRoot.Explicit(Path.Combine(@"C:\TD\out\w3-mcp-data", Guid.NewGuid().ToString("N")));
    var executable = Environment.GetEnvironmentVariable("TD_KEEPER_EXE") ?? throw new InvalidOperationException("Set TD_KEEPER_EXE.");
    using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(45));
    var client = await KeeperConnection.AttachAsync(root, executable, ct.Token); string? id = null;
    try
    {
      var row = (await client.CreateAsync(new(Guid.NewGuid().ToString(), "shell", root.DirectoryPath, "MCP proof"), ct.Token)).Session!; id = row.Definition.Id;
      var door = new McpDoor(new TestPermission()); KeeperSessionTools.Register(door, client);
      var caller = door.RegisterCaller(new("w3-proof", null, null, true, AiPermissionMode.Ask,
        ["sessions.list", "sessions.screen", "sessions.send", "sessions.rename", "sessions.stop"], [McpTier.Read, McpTier.Act, McpTier.Alter], ["sessions:" + id], DateTimeOffset.UtcNow.AddMinutes(2)), (_, _, _, _, _) => ValueTask.FromResult(true));
      Assert.Equal(5, door.List(caller.Id).Count);
      var sent = await door.CallAsync(caller.Id, "sessions.send", JsonSerializer.SerializeToElement(new { sessionId = id, text = "echo W3_MCP_MARKER" }), ct.Token);
      Assert.True(sent.TryGetProperty("sentAt", out _));
      while (true)
      {
        var screen = await door.CallAsync(caller.Id, "sessions.screen", JsonSerializer.SerializeToElement(new { sessionId = id }), ct.Token);
        if (screen.GetProperty("screen").GetString()!.Contains("W3_MCP_MARKER")) break;
        await Task.Delay(100, ct.Token);
      }
      await door.CallAsync(caller.Id, "sessions.rename", JsonSerializer.SerializeToElement(new { sessionId = id, title = "Renamed by MCP" }), ct.Token);
      Assert.Equal("Renamed by MCP", (await client.ListAsync(ct.Token)).Sessions!.Single().Definition.Title);
      var denied = door.RegisterCaller(new("denied", null, null, true, AiPermissionMode.Ask, ["sessions.screen"], [McpTier.Read], [], DateTimeOffset.UtcNow.AddMinutes(2)), (_, _, _, _, _) => ValueTask.FromResult(true));
      await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(denied.Id, "sessions.screen", JsonSerializer.SerializeToElement(new { sessionId = id }), ct.Token));
      door.Revoke(caller.Id);
      await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "sessions.screen", JsonSerializer.SerializeToElement(new { sessionId = id }), ct.Token));
    }
    finally
    {
      try { if (id is not null) await client.StopAsync(id); }
      finally
      {
        using var identity = JsonDocument.Parse(File.ReadAllBytes(Path.Combine(root.DirectoryPath, "keeper", "supervisor.identity.json")));
        using var process = Process.GetProcessById(identity.RootElement.GetProperty("Pid").GetInt32());
        if (process.StartTime.ToUniversalTime().Ticks == identity.RootElement.GetProperty("StartedUtcTicks").GetInt64()) process.Kill();
      }
    }
  }
  private sealed class TestPermission : IMcpPermissionBroker
  {
    public ValueTask<McpPermissionProof> AuthorizeAsync(McpPermissionRequest request, CancellationToken ct) => ValueTask.FromResult(new McpPermissionProof(Guid.NewGuid(), request.CallerId, request.ActionDigest, DateTimeOffset.UtcNow.AddSeconds(20), true));
  }
}
