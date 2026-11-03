using System.Buffers.Binary;
using System.Text.Json;
using System.Threading.Channels;
using TerminalDeck.Core.Browser;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Integration;

public sealed class W4bRelayBrowserTests
{
  [Fact]
  public async Task RelayRequiresSeparateGrantAndRechecksRevocation()
  {
    var door = new McpDoor(new Broker()); var bridge = new McpRelayBridge(door);
    McpRegistration Register(bool internet) => door.RegisterCaller(new("fixture-" + internet, null, null, true, AiPermissionMode.Ask, [], [McpTier.Read], [], DateTimeOffset.UtcNow.AddMinutes(1), AllowRelay: internet), (_, _, _, _, _) => ValueTask.FromResult(true));
    var local = Register(false); var remote = Register(true);
    Assert.Equal(401, Status(await bridge.ReceiveAsync(Envelope(local.Token), default)));
    Assert.Equal(200, Status(await bridge.ReceiveAsync(Envelope(remote.Token), default)));
    door.Revoke(remote.Id); Assert.Equal(401, Status(await bridge.ReceiveAsync(Envelope(remote.Token), default)));
  }
  [Fact]
  public async Task LongRelayRequestDoesNotBlockCancelOrPhonePackets()
  {
    using var identity = NoiseIdentity.Generate(); var mcp = new WaitingMcp(); var socket = new Socket();
    await using var connection = new RelayHostConnection(identity, new NoPhone(), mcp);
    var work = connection.RunAsync(socket, default); var id = Guid.NewGuid().ToByteArray();
    socket.Input.Writer.TryWrite(new RelayPacket(RelayKind.McpRequest, id, []).Encode());
    await mcp.Started.Task.WaitAsync(TimeSpan.FromSeconds(5));
    socket.Input.Writer.TryWrite(new RelayPacket(RelayKind.McpCancel, id, []).Encode());
    await mcp.Cancelled.Task.WaitAsync(TimeSpan.FromSeconds(5)); socket.Input.Writer.Complete(); await work;
    Assert.Contains(socket.Sent, packet => RelayPacket.Decode(packet).Kind == RelayKind.McpReach);
  }
  [Fact]
  public async Task BrowserDriverNeedsBothProfileAndOriginAndRechecksReturnedOrigin()
  {
    var page = new Page(); await using var browser = new BrowserModel(new Store<BrowserState>(), new Factory(page), new Storage());
    var tab = await browser.OpenAsync("https://example.com"); var door = new McpDoor(new Broker()); BrowserTools.RegisterWithSessionLookup(door, browser, _ => throw new ArgumentException());
    McpRegistration Register(string[] resources) => door.RegisterCaller(new(Guid.NewGuid().ToString(), null, null, true, AiPermissionMode.Ask, ["browser.read"], [McpTier.Read], resources, DateTimeOffset.UtcNow.AddMinutes(1)), (_, _, _, _, _) => ValueTask.FromResult(true));
    var denied = Register(["browser:" + tab.Id, "origins:https://example.com"]);
    await Assert.ThrowsAsync<McpRefusal>(() => door.CallAsync(denied.Id, "browser.read", JsonSerializer.SerializeToElement(new { window = tab.Id })).AsTask()); Assert.Equal(0, page.Reads);
    var allowed = Register(["browser:" + tab.Id, "profiles:default", "origins:https://example.com"]);
    await door.CallAsync(allowed.Id, "browser.read", JsonSerializer.SerializeToElement(new { window = tab.Id })); Assert.Equal(1, page.Reads);
    page.Url = "https://other.invalid/";
    await Assert.ThrowsAsync<McpRefusal>(() => door.CallAsync(allowed.Id, "browser.read", JsonSerializer.SerializeToElement(new { window = tab.Id })).AsTask());
  }
  private static byte[] Envelope(string token)
  {
    var head = JsonSerializer.SerializeToUtf8Bytes(new { v = 1, authorization = "Bearer " + token });
    var body = JsonSerializer.SerializeToUtf8Bytes(new { jsonrpc = "2.0", id = 1, method = "ping" });
    var result = new byte[2 + head.Length + body.Length]; BinaryPrimitives.WriteUInt16BigEndian(result, (ushort)head.Length); head.CopyTo(result, 2); body.CopyTo(result, 2 + head.Length); return result;
  }
  private static int Status(IReadOnlyList<byte[]> replies) { var first = Assert.Single(replies); using var head = JsonDocument.Parse(first.AsMemory(3, BinaryPrimitives.ReadUInt16BigEndian(first.AsSpan(1)))); return head.RootElement.GetProperty("status").GetInt32(); }
  private sealed class Broker : IMcpPermissionBroker { public ValueTask<McpPermissionProof> AuthorizeAsync(McpPermissionRequest r, CancellationToken ct) => ValueTask.FromResult(new McpPermissionProof(Guid.NewGuid(), r.CallerId, r.ActionDigest, DateTimeOffset.UtcNow.AddMinutes(1), true)); }
  private sealed class Store<T> : IStateStore<T> { private T? state; public T? Load() => state; public void Save(T value) => state = value; }
  private sealed class Storage : IBrowserProfileStorage
  {
    public ValueTask EnsureProfileAsync(string id, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask CreatePrivateAsync(string id, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask DeletePrivateAsync(string id, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask DeleteProfileAsync(string id, CancellationToken ct) => ValueTask.CompletedTask;
  }
  private sealed class Factory(Page page) : IBrowserSurfaceFactory { public ValueTask<IBrowserPage> CreateAsync(BrowserSurfaceOptions options, CancellationToken ct) { page.TabId = options.TabId; return ValueTask.FromResult<IBrowserPage>(page); } }
  private sealed class Page : IBrowserPage
  {
    public int Reads; public string Url = "https://example.com/"; public string TabId { get; set; } = "fixture";
    public Task NavigateAsync(Uri url, CancellationToken ct = default) => Task.CompletedTask;
    public Task<JsonElement> DevToolsAsync(string method, JsonElement args, CancellationToken ct = default) => throw new NotSupportedException();
    public ValueTask<JsonElement> PerformAsync(BrowserPageAction action, JsonElement args, CancellationToken ct) { Reads++; return ValueTask.FromResult(JsonSerializer.SerializeToElement(new { url = Url, text = "fixture" })); }
    public ValueTask ReloadAsync(bool bypass, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
  }
  private sealed class WaitingMcp : IRelayMcpApplication
  {
    public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public TaskCompletionSource Cancelled { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public async ValueTask<IReadOnlyList<byte[]>> ReceiveAsync(ReadOnlyMemory<byte> payload, CancellationToken ct)
    {
      Started.SetResult(); try { await Task.Delay(Timeout.Infinite, ct); return []; } finally { Cancelled.TrySetResult(); }
    }
  }
  private sealed class Socket : IRelaySocket
  {
    public Channel<byte[]> Input { get; } = Channel.CreateUnbounded<byte[]>(); public List<byte[]> Sent { get; } = [];
    public Task ConnectAsync(Uri url, ReadOnlyMemory<byte> secret, CancellationToken ct) => Task.CompletedTask;
    public ValueTask SendAsync(ReadOnlyMemory<byte> packet, CancellationToken ct) { Sent.Add(packet.ToArray()); return ValueTask.CompletedTask; }
    public async ValueTask<byte[]?> ReceiveAsync(CancellationToken ct) => await Input.Reader.WaitToReadAsync(ct) ? await Input.Reader.ReadAsync(ct) : null;
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
  }
  private sealed class NoPhone : IRelayPhoneApplication
  {
    public IReadOnlyCollection<byte[]> KnownPeers => []; public bool PairingOpen => false;
    public ValueTask<PhoneApplicationReply> ReceiveAsync(string channel, ReadOnlyMemory<byte> key, ReadOnlyMemory<byte> plain, CancellationToken ct) => ValueTask.FromResult(new PhoneApplicationReply([]));
    public ValueTask DisconnectedAsync(string channel) => ValueTask.CompletedTask;
  }
}
