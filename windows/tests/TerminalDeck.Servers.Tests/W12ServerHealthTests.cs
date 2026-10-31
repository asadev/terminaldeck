using System.Text.Json;
using TerminalDeck.Core.Servers;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Servers.Tests;

public sealed class W12ServerHealthTests
{
  [Fact] public async Task HealthIsAReadEvenForLookOnlyAndNeverAsksForAChange()
  {
    using var f = new Fixture(); var server = await f.AddAsync();
    var expected = new ServerHealth(25, 4, 16, 30, 100, 1, 2, 3, 8, DateTimeOffset.UtcNow);
    f.Runtime.Reply = _ => new(0, JsonSerializer.Serialize(expected, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase }));
    var health = await f.Service.HealthAsync(server.Id, ServerCaller.Person); Assert.Equal(expected, health);
    Assert.Empty(f.Approval.Actions); Assert.Single(f.Runtime.Commands);
    await Assert.ThrowsAsync<ServerRefusal>(async () => await f.Service.HealthAsync(server.Id, new("unknown-ai")));
    Assert.Single(f.Runtime.Commands);
  }
  [Fact] public async Task RevokedCallerCannotReceiveAHealthResultAfterTheRead()
  {
    using var f = new Fixture(); var server = await f.AddAsync(); var live = true;
    var grant = new McpGrant("person", null, null, true, AiPermissionMode.Ask, ["servers.health"], [McpTier.Read], ["servers:" + server.Id], DateTimeOffset.UtcNow.AddMinutes(5), OwnerApplication: true);
    var context = new McpCallContext(grant, _ => live ? ValueTask.CompletedTask : ValueTask.FromException(new McpRefusal("Access changed.")), _ => { });
    f.Runtime.Reply = _ =>
    {
      live = false;
      return new(0, JsonSerializer.Serialize(new ServerHealth(10, 1, 2, 1, 2, 0, 0, 0, 1, DateTimeOffset.UtcNow), new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase }));
    };
    await Assert.ThrowsAsync<McpRefusal>(async () => await new ServersMcp(f.Service).CallAsync("servers.health", context, JsonSerializer.SerializeToElement(new { serverId = server.Id }), default));
    Assert.Empty(f.Approval.Actions);
  }
  [Theory]
  [InlineData(-1, 4, 16)]
  [InlineData(101, 4, 16)]
  [InlineData(25, 17, 16)]
  [InlineData(25, 0, 0)]
  public void InvalidReadingsNeverBecomeHealthFacts(double cpu, long used, long total)
  {
    var value = new ServerHealth(cpu, used, total, 10, 100, 0, 0, 0, 4, DateTimeOffset.UtcNow);
    Assert.Throws<IOException>(() => ServerResponses.Health(JsonSerializer.Serialize(value, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase })));
  }
}
