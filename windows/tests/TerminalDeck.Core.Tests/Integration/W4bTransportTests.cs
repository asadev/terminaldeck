using System.Diagnostics;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Platform;

namespace TerminalDeck.Core.Tests.Integration;

public sealed class W4bTransportTests
{
  private static string Node => "node";
  private static string Fixture => Path.Combine(AppContext.BaseDirectory, "Fixtures", "w4b-mcp.cjs");
  [Theory]
  [InlineData("stdio")]
  [InlineData("http")]
  [InlineData("sse")]
  public async Task RealTransportNegotiatesFiltersNotificationsPaginatesAndCalls(string transport)
  {
    using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(25)); Process? server = null;
    try
    {
      string? url = null;
      if (transport != "stdio") { server = Start(transport); url = await AddressAsync(server, ct.Token); }
      var config = new McpServerConfig("fixture", "fixture", "user", null, transport, Node, [Fixture, "stdio"], url, [], []);
      await using var connection = await new ManagedMcpFactory().ConnectAsync(config, new NoSecrets(), ct.Token);
      var inventory = await connection.ToolsAsync(ct.Token);
      Assert.Equal(new[] { "echo", "second" }, inventory.Select(t => t.Name));
      Assert.Equal("Echo text", inventory[0].Title);
      Assert.Equal("Echo the supplied text", inventory[0].Description);
      var reply = await connection.CallAsync("echo", JsonSerializer.SerializeToElement(new { text = "transport fixture" }), ct.Token);
      Assert.Equal("transport fixture", reply.GetProperty("content")[0].GetProperty("text").GetString());
    }
    finally { if (server is not null && !server.HasExited) { server.Kill(true); await server.WaitForExitAsync(); } server?.Dispose(); }
  }
  [Theory]
  [InlineData("redirect", "http")]
  [InlineData("unsafe", "sse")]
  public async Task RefusesRedirectAndCrossOriginLegacyEndpoint(string mode, string transport)
  {
    using var server = Start(mode); using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(15));
    try
    {
      var url = await AddressAsync(server, ct.Token);
      await Assert.ThrowsAsync<IOException>(async () => await new ManagedMcpFactory().ConnectAsync(new("fixture", "fixture", "user", null, transport, null, [], url, [], []), new NoSecrets(), ct.Token));
    }
    finally { if (!server.HasExited) { server.Kill(true); await server.WaitForExitAsync(); } }
  }
  [Fact]
  public async Task W12RealManagerBlocksDisabledToolThroughThePermissionDoor()
  {
    var fixture = new McpServerConfig("fixture", "fixture", "user", null, "stdio", Node, [Fixture, "stdio"], null, [], []);
    await using var manager = new McpManager(new TerminalDeck.Core.Tests.Sessions.MemoryState<McpManagerState>(),
      new TerminalDeck.Core.Tests.Mcp.TestSecretStore(), TerminalDeck.Core.Storage.AppDataRoot.Explicit(Path.GetTempPath()), new FixtureCommand(fixture), new ManagedMcpFactory());
    var server = await manager.AddAsync(new() { Name = "fixture", Scope = "user", Transport = "stdio", Command = "fixture" });
    var door = new McpDoor(new TerminalDeck.Core.Tests.Mcp.FakePermission()); DeckCoreTools.RegisterManager(door, manager);
    var caller = door.RegisterCaller(TerminalDeck.Core.Tests.Mcp.McpTests.Grant("mcp.connect", "mcp.call", "mcp.edit"), (_, _, _, _, _) => ValueTask.FromResult(true));
    JsonElement Args(object value) => JsonSerializer.SerializeToElement(value);
    await door.CallAsync(caller.Id, "mcp.connect", Args(new { serverId = server.Id }));
    var reply = await door.CallAsync(caller.Id, "mcp.call", Args(new { serverId = server.Id, tool = "echo", arguments = new { text = "real-manager-proof" } }));
    Assert.Equal("real-manager-proof", reply.GetProperty("data").GetProperty("content")[0].GetProperty("text").GetString());
    await door.CallAsync(caller.Id, "mcp.edit", Args(new { name = "fixture", scope = "user", next = new { disabledTools = new[] { "echo" } } }));
    await door.CallAsync(caller.Id, "mcp.connect", Args(new { serverId = server.Id }));
    await Assert.ThrowsAsync<McpRefusal>(async () => await door.CallAsync(caller.Id, "mcp.call", Args(new { serverId = server.Id, tool = "echo", arguments = new { text = "must-not-run" } })));
    Assert.Equal(2, Assert.Single(await manager.ListAsync()).ToolCount);
  }
  private sealed class FixtureCommand(McpServerConfig config) : IMcpCommandResolver
  { public McpCommand Resolve(string commandLine) => new(config.Executable!, config.Arguments); }

  private static Process Start(string mode)
  {
    var start = new ProcessStartInfo(Node) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
    start.ArgumentList.Add(Fixture); start.ArgumentList.Add(mode); return Process.Start(start)!;
  }
  private static async Task<string> AddressAsync(Process process, CancellationToken ct)
  {
    using var line = JsonDocument.Parse(await process.StandardOutput.ReadLineAsync(ct) ?? throw new IOException("The fixture did not start."));
    return "http://127.0.0.1:" + line.RootElement.GetProperty("port").GetInt32() + "/mcp";
  }
  private sealed class NoSecrets : ISecretStore
  {
    public ValueTask<byte[]?> ReadAsync(string key, CancellationToken ct = default) => ValueTask.FromResult<byte[]?>(null);
    public ValueTask WriteAsync(string key, ReadOnlyMemory<byte> bytes, CancellationToken ct = default) => ValueTask.CompletedTask;
    public ValueTask DeleteAsync(string key, CancellationToken ct = default) => ValueTask.CompletedTask;
  }
}
