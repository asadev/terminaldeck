using System.Buffers.Binary;
using System.Text.Json;
using TerminalDeck.Core.Integration;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class CloudRelayLifecycleTests
{
  private sealed class Host
  {
    public CloudRelayMode Mode;
    public int Starts, Stops;
    public Action? OnStop;
    public Task Stop() { Stops++; Mode = CloudRelayMode.Stopped; OnStop?.Invoke(); return Task.CompletedTask; }
    public Task Start(bool phones) { Starts++; Mode = phones ? CloudRelayMode.Phones : CloudRelayMode.Receiver; return Task.CompletedTask; }
    public Task Reconcile(CloudRelayLifecycle policy, Func<bool>? receiver = null) => policy.ReconcileAsync(receiver ?? (() => false), () => Mode, Stop, Start);
  }
  [Fact] public async Task DefaultAndPaywallOffKeepTheExistingHostUntouched()
  {
    var policy = new CloudRelayLifecycle(); var host = new Host { Mode = CloudRelayMode.Phones }; policy.RequestPhones(true);
    Assert.True(policy.Allowed); await host.Reconcile(policy); await host.Reconcile(policy);
    Assert.Equal(0, host.Starts); Assert.Equal(0, host.Stops); Assert.True(policy.PhonesRequested);
  }
  [Fact] public async Task KnownUnpaidBootDoesNotStartAndRegainRestoresTheExistingLaunchIntent()
  {
    var allowed = false; var policy = new CloudRelayLifecycle { CloudServicesAllowed = () => allowed }; var host = new Host();
    policy.RequestPhones(true, existingAtLaunch: true); await host.Reconcile(policy);
    Assert.Equal(0, host.Starts); Assert.Equal(CloudRelayMode.Stopped, host.Mode);
    allowed = true; await host.Reconcile(policy); Assert.Equal(CloudRelayMode.Phones, host.Mode); Assert.Equal(1, host.Starts);
  }
  [Fact] public async Task LapseStopsOnceAndRegainOnlyRestoresAnEnabledHost()
  {
    var allowed = true; var policy = new CloudRelayLifecycle { CloudServicesAllowed = () => allowed }; var host = new Host();
    policy.RequestPhones(true); await host.Reconcile(policy); allowed = false; await host.Reconcile(policy); await host.Reconcile(policy);
    Assert.Equal(1, host.Stops); Assert.True(policy.PhonesRequested);
    allowed = true; await host.Reconcile(policy); Assert.Equal(2, host.Starts);
    allowed = false; await host.Reconcile(policy); policy.RequestPhones(false); allowed = true; await host.Reconcile(policy);
    Assert.Equal(2, host.Starts); Assert.Equal(CloudRelayMode.Stopped, host.Mode);
  }
  [Fact] public async Task ABlockedNewRequestDoesNotBecomeFutureConsent()
  {
    var allowed = false; var policy = new CloudRelayLifecycle { CloudServicesAllowed = () => allowed }; var host = new Host();
    Assert.Throws<InvalidOperationException>(() => policy.RequestPhones(true)); Assert.False(policy.PhonesRequested);
    allowed = true; await host.Reconcile(policy); Assert.Equal(0, host.Starts);
  }
  [Fact] public async Task ReceiverIntentIsReadAgainAndCannotStartWhileUnpaid()
  {
    var allowed = true; var receiver = true; var policy = new CloudRelayLifecycle { CloudServicesAllowed = () => allowed }; var host = new Host();
    await host.Reconcile(policy, () => receiver); Assert.Equal(CloudRelayMode.Receiver, host.Mode);
    allowed = false; await host.Reconcile(policy, () => receiver); Assert.Equal(CloudRelayMode.Stopped, host.Mode);
    receiver = false; allowed = true; await host.Reconcile(policy, () => receiver); Assert.Equal(1, host.Starts);
    receiver = true; await host.Reconcile(policy, () => receiver); Assert.Equal(2, host.Starts);
  }
  [Fact] public async Task EntitlementLostDuringAStopCannotOpenTheReplacementRelay()
  {
    var allowed = true; var policy = new CloudRelayLifecycle { CloudServicesAllowed = () => allowed }; policy.RequestPhones(true);
    var host = new Host { Mode = CloudRelayMode.Receiver, OnStop = () => allowed = false };
    await host.Reconcile(policy); Assert.Equal(1, host.Stops); Assert.Equal(0, host.Starts);
  }
  [Fact] public async Task PaidLossBlocksRelayFramesAndPushButKeepsTheLocalHubAndCleanup()
  {
    var allowed = true; var app = new Phone(); var hub = new PhoneTransportHub(app); var remote = new CloudRelayPhoneApplication(hub, () => allowed); var remotePush = 0; var localPush = 0;
    remote.SetPublisher((_, _, _) => { remotePush++; return ValueTask.CompletedTask; }); hub.SetLocalPublisher((_, _, _) => { localPush++; return ValueTask.CompletedTask; });
    await remote.ReceiveAsync("relay", new byte[32], new byte[] { 1 }, default); Assert.Equal(1, app.Messages);
    allowed = false; Assert.Empty(remote.KnownPeers); Assert.False(remote.PairingOpen);
    var refusal = await remote.ReceiveAsync("relay", new byte[32], new byte[] { 1 }, default); Assert.True(refusal.Close); Assert.Equal(1, app.Messages);
    Assert.Contains("subscription_required", System.Text.Encoding.UTF8.GetString(refusal.Messages[0]));
    await app.Publish!("relay", [], default); await app.Publish!("local-web:one", [], default); Assert.Equal(0, remotePush); Assert.Equal(1, localPush);
    await hub.ReceiveAsync("local-web:one", new byte[32], new byte[] { 1 }, default); Assert.Equal(2, app.Messages);
    await remote.DisconnectedAsync("relay"); Assert.Equal(1, app.Disconnects);
  }
  [Fact] public async Task ReceiverGateBlocksNewFramesAndExistingPublisherButAlwaysDisconnects()
  {
    var allowed = true; var receiver = new Receiver(); var guarded = new CloudRelayReceiverApplication(receiver, () => allowed); var sent = 0;
    await guarded.ConnectedAsync((_, _) => { sent++; return ValueTask.CompletedTask; }, default); allowed = false;
    var packet = new RelayPacket(RelayKind.ReceiverSync, new byte[16], []);
    await Assert.ThrowsAsync<ProtocolException>(async () => await guarded.FrameAsync(packet, default));
    await Assert.ThrowsAsync<ProtocolException>(async () => await receiver.Send!(packet, default)); Assert.Equal(0, sent); Assert.Equal(0, receiver.Frames);
    await guarded.DisconnectedAsync(); Assert.Equal(1, receiver.Disconnects);
  }
  [Fact] public async Task McpGateReturnsTheExisting402EnvelopeWithoutCallingTheDoor()
  {
    var allowed = true; var app = new Mcp(); var guarded = new CloudRelayMcpApplication(app, () => allowed);
    Assert.Equal(new byte[] { 7 }, Assert.Single(await guarded.ReceiveAsync(ReadOnlyMemory<byte>.Empty, default))); Assert.Equal(1, app.Calls);
    allowed = false; var bytes = Assert.Single(await guarded.ReceiveAsync(ReadOnlyMemory<byte>.Empty, default)); Assert.Equal(1, app.Calls);
    var headerLength = BinaryPrimitives.ReadUInt16BigEndian(bytes.AsSpan(1)); using var header = JsonDocument.Parse(bytes.AsMemory(3, headerLength)); Assert.Equal(402, header.RootElement.GetProperty("status").GetInt32());
    using var body = JsonDocument.Parse(bytes.AsMemory(3 + headerLength)); Assert.Equal("subscription_required", body.RootElement.GetProperty("code").GetString());
  }
  private sealed class Phone : IRelayPhoneApplication, IW9PhonePushApplication
  {
    public int Messages, Disconnects;
    public Func<string, byte[], CancellationToken, ValueTask>? Publish;
    public IReadOnlyCollection<byte[]> KnownPeers => [new byte[32]];
    public bool PairingOpen => true;
    public void SetPublisher(Func<string, byte[], CancellationToken, ValueTask>? publish) => Publish = publish;
    public ValueTask<PhoneApplicationReply> ReceiveAsync(string channel, ReadOnlyMemory<byte> key, ReadOnlyMemory<byte> bytes, CancellationToken ct) { Messages++; return ValueTask.FromResult(new PhoneApplicationReply([])); }
    public ValueTask DisconnectedAsync(string channel) { Disconnects++; return ValueTask.CompletedTask; }
  }
  private sealed class Receiver : IRelayReceiverApplication
  {
    public int Frames, Disconnects;
    public Func<RelayPacket, CancellationToken, ValueTask>? Send;
    public ValueTask ConnectedAsync(Func<RelayPacket, CancellationToken, ValueTask> send, CancellationToken ct) { Send = send; return ValueTask.CompletedTask; }
    public ValueTask FrameAsync(RelayPacket packet, CancellationToken ct) { Frames++; return ValueTask.CompletedTask; }
    public ValueTask DisconnectedAsync() { Disconnects++; return ValueTask.CompletedTask; }
  }
  private sealed class Mcp : IRelayMcpApplication
  {
    public int Calls;
    public ValueTask<IReadOnlyList<byte[]>> ReceiveAsync(ReadOnlyMemory<byte> bytes, CancellationToken ct) { Calls++; return ValueTask.FromResult<IReadOnlyList<byte[]>>([new byte[] { 7 }]); }
  }
}
