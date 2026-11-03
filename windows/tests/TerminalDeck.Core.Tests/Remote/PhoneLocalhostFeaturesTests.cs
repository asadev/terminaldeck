using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class PhoneLocalhostFeaturesTests
{
  private static readonly ApprovedDevice Device = new("device", "Phone", "ios", PhoneAccess.Full);
  private static JsonElement Message(object value) => JsonSerializer.SerializeToElement(value);
  [Fact]
  public async Task OnlyOfferedLoopbackPortIsDialledAndBytesUseBoundedWireFrames()
  {
    using var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
    var port = ((IPEndPoint)listener.LocalEndpoint).Port;
    using var host = new PhoneLocalhostFeatures((_, p) => p == port);
    var published = Channel.CreateUnbounded<JsonObject>();
    host.Bind((_, message, _) => { published.Writer.TryWrite(message); return ValueTask.CompletedTask; }, _ => Device);
    var denied = Assert.Single(await host.HandleAsync("phone", Device, "tunnel.open", Message(new { id = "denied", port = port == 65535 ? port - 1 : port + 1 }), null, default));
    Assert.Equal("tunnel.closed", denied["t"]!.GetValue<string>());
    var opened = Assert.Single(await host.HandleAsync("phone", Device, "tunnel.open", Message(new { id = "tunnel", port }), null, default));
    Assert.Equal("tunnel.opened", opened["t"]!.GetValue<string>());
    var accepting = listener.AcceptTcpClientAsync();
    await host.HandleAsync("phone", Device, "net.open", Message(new { ch = "one", tunnel = "tunnel" }), null, default);
    using var server = await accepting.WaitAsync(TimeSpan.FromSeconds(5));
    await server.GetStream().WriteAsync("hello"u8.ToArray());
    var collected = new List<byte>();
    while (collected.Count < 5)
    {
      var data = await published.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
      Assert.Equal("net.data", data["t"]!.GetValue<string>()); collected.AddRange(Convert.FromBase64String(data["data"]!.GetValue<string>()));
    }
    Assert.Equal("hello"u8.ToArray(), collected.ToArray());
    var ack = Assert.Single(await host.HandleAsync("phone", Device, "net.data", Message(new { ch = "one", data = "d29ybGQ=" }), null, default));
    Assert.Equal("net.ack", ack["t"]!.GetValue<string>()); Assert.Equal(5, ack["bytes"]!.GetValue<int>());
    var buffer = new byte[5]; await server.GetStream().ReadExactlyAsync(buffer).AsTask().WaitAsync(TimeSpan.FromSeconds(5)); Assert.Equal("world"u8.ToArray(), buffer);
    var badAck = Assert.Single(await host.HandleAsync("phone", Device, "net.ack", Message(new { ch = "one", bytes = 6 }), null, default));
    Assert.Equal("net.close", badAck["t"]!.GetValue<string>());
  }
  [Fact]
  public async Task ReservedPortAndLookAccessNeverOpenTunnel()
  {
    using var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
    var port = ((IPEndPoint)listener.LocalEndpoint).Port;
    using var host = new PhoneLocalhostFeatures((_, _) => true, () => [port]);
    host.Bind((_, _, _) => ValueTask.CompletedTask, _ => Device);
    var result = Assert.Single(await host.HandleAsync("phone", Device, "tunnel.open", Message(new { id = "one", port }), null, default));
    Assert.Equal("tunnel.closed", result["t"]!.GetValue<string>());
    await Assert.ThrowsAsync<PhoneRefusal>(async () => await host.HandleAsync("look", Device with { Access = PhoneAccess.Look }, "tunnel.open", Message(new { id = "one", port }), null, default));
  }
  [Fact]
  public async Task WithdrawalBeforeReadPreventsAnyBytesFromBeingPublished()
  {
    using var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start();
    var port = ((IPEndPoint)listener.LocalEndpoint).Port;
    ApprovedDevice? current = Device;
    using var host = new PhoneLocalhostFeatures((_, p) => p == port);
    var published = Channel.CreateUnbounded<JsonObject>();
    host.Bind((_, message, _) => { published.Writer.TryWrite(message); return ValueTask.CompletedTask; }, _ => current);
    await host.HandleAsync("phone", Device, "tunnel.open", Message(new { id = "tunnel", port }), null, default);
    var accepting = listener.AcceptTcpClientAsync();
    await host.HandleAsync("phone", Device, "net.open", Message(new { ch = "one", tunnel = "tunnel" }), null, default);
    using var server = await accepting.WaitAsync(TimeSpan.FromSeconds(5));
    current = Device with { Access = PhoneAccess.Look };
    await server.GetStream().WriteAsync("private"u8.ToArray());
    var result = await published.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
    Assert.Equal("net.close", result["t"]!.GetValue<string>());
    await host.DisconnectedAsync("phone");
  }
}
