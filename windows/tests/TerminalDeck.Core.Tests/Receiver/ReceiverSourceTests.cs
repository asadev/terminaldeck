using System.Buffers.Binary;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Org.BouncyCastle.Math.EC.Rfc7748;
using TerminalDeck.Core.Mcp;
using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Tests.Mcp;

namespace TerminalDeck.Core.Tests.Receiver;

public sealed class ReceiverSourceTests
{
  [Fact] public async Task TokenProofIsWriteOnlyAndMappedIgnoresDoNotRoute()
  {
    var f = new Fixture(); var state = new State(); var keys = new TestSecretStore(); using var service = new ReceiverSourceService(f.Store, state, keys, "test/", clock: f.Clock);
    var source = service.Create("Gateway", "project", "whapi"); Assert.Matches("^[A-HJ-NP-Z2-9]{26}$", source.Id); await service.SetCredentialAsync(source.Id, "source-proof-secret-123");
    var body = Encoding.UTF8.GetBytes("{\"messages\":[{\"from\":\"Alice\",\"id\":\"one\",\"from_me\":true,\"text\":{\"body\":\"Our own message\"}},{\"from\":\"Bob\",\"id\":\"two\",\"text\":{\"body\":\"An inbound message\"}}]}");
    await Assert.ThrowsAsync<UnauthorizedAccessException>(() => service.AcceptAsync(new(source.Id, new Dictionary<string, string> { ["authorization"] = "Bearer wrong" }, body)));
    var items = await service.AcceptAsync(new(source.Id, new Dictionary<string, string> { ["authorization"] = "Bearer source-proof-secret-123" }, body));
    Assert.Equal(2, items.Length); Assert.Equal(InboxStatus.Ignored, items[0].Status); Assert.Equal("Bob", items[1].Title); Assert.Empty(f.Delivery.Keys);
    Assert.DoesNotContain("source-proof-secret-123", JsonSerializer.Serialize(state.Load())); Assert.DoesNotContain("source-proof-secret-123", items[1].Payload!.Value.GetRawText());
    service.SavePreset(source.Id, "A reusable gateway"); var saved = service.Presets().Single(p => !p.BuiltIn); Assert.DoesNotContain("source-proof-secret-123", JsonSerializer.Serialize(saved));
  }
  [Fact] public async Task HmacChecksTheExactBodyAndTimestampWindow()
  {
    var f = new Fixture(); var keys = new TestSecretStore(); using var service = new ReceiverSourceService(f.Store, new State(), keys, "test/", clock: f.Clock); var source = service.Create("Signed", "project", "github"); await service.SetCredentialAsync(source.Id, "hmac-proof-secret-123");
    var config = service.Read(source.Id); service.Save(config with { Proof = config.Proof with { TimestampHeader = "x-time", SignedPayload = "{timestamp}.{body}" } });
    var body = "{\"title\":\"Observed\"}"u8.ToArray(); var timestamp = f.Clock.GetUtcNow().ToUnixTimeSeconds().ToString(System.Globalization.CultureInfo.InvariantCulture);
    var signature = "sha256=" + Convert.ToHexStringLower(HMACSHA256.HashData("hmac-proof-secret-123"u8, Encoding.UTF8.GetBytes(timestamp + ".").Concat(body).ToArray()));
    var headers = new Dictionary<string, string> { ["x-time"] = timestamp, ["x-hub-signature-256"] = signature };
    await service.VerifyAsync(new(source.Id, headers, body), service.Read(source.Id), CancellationToken.None);
    await Assert.ThrowsAsync<UnauthorizedAccessException>(() => service.VerifyAsync(new(source.Id, headers, "{}"u8.ToArray()), service.Read(source.Id), CancellationToken.None));
    headers["x-time"] = "1"; await Assert.ThrowsAsync<UnauthorizedAccessException>(() => service.VerifyAsync(new(source.Id, headers, body), service.Read(source.Id), CancellationToken.None));
  }
  [Fact] public void MappingPreviewUsesOverridesFallbacksAndKeepsOriginalPayloadWithoutWriting()
  {
    var mapping = new ReceiverPayloadMapping(Title: "{{missing|\"Default | title\"}}", Text: "{{message}}", Fields: new() { ["repo"] = "{{repository.full_name}}" }, Overrides: new() { ["title"] = "{{title|\"Fallback\"}}" });
    var result = ReceiverPayloadMapper.Map(new("source", new Dictionary<string, string>(), "{\"title\":\"Sender title\",\"message\":\"Body\",\"repository\":{\"full_name\":\"sample/repo\"}}"u8.ToArray()), mapping).Single();
    Assert.Equal("Sender title", result.Title); Assert.Equal("sample/repo", result.Fields["repo"]); Assert.Equal("Sender title", result.Payload.GetProperty("payload").GetProperty("title").GetString());
    Assert.Equal("Default | title", ReceiverPayloadMapper.Template("{{missing|\"Default | title\"}}", JsonSerializer.SerializeToElement(new { })));
  }
  [Theory] [InlineData("192.168.1.0/24", "192.168.1.4", true)] [InlineData("192.168.1.0/24", "192.168.2.4", false)] [InlineData("::1", "::1", true)]
  public void SenderAddressRulesUseActualNetworkPrefixes(string rule, string address, bool allowed) => Assert.Equal(allowed, ReceiverSourceService.IpMatches(rule, address));
  [Fact] public async Task ReplyUsesProtectedHeaderEscapesJsonAndDoesNotDuplicateAnAcknowledgedSend()
  {
    var f = new Fixture(); using var service = new ReceiverSourceService(f.Store, new State(), new TestSecretStore(), "test/"); var source = service.Create("Reply", "project", "webhook"); var config = service.Read(source.Id); service.Save(config with { Reply = new(Url: "https://example.test/reply", Headers: new() { ["Authorization"] = "Bearer {{secret.reply}}" }) }); await service.SetCredentialAsync(source.Id, "reply-secret-123", reply: true);
    var item = f.Store.Receive(new(source.Id, "Incoming", "A message")); var handler = new ReplyHandler(); using var http = new HttpClient(handler);
    var first = await service.ReplyAsync(item.Id, "A \"quoted\" reply", client: http); var second = await service.ReplyAsync(item.Id, "A \"quoted\" reply", client: http);
    Assert.Equal("sent", first.State); Assert.Equal(first.Id, second.Id); Assert.Equal(1, handler.Sends); Assert.Equal("Bearer reply-secret-123", handler.Authorization); using var body = JsonDocument.Parse(handler.Body!); Assert.Equal("A \"quoted\" reply", body.RootElement.GetProperty("text").GetString()); Assert.DoesNotContain("reply-secret-123", JsonSerializer.Serialize(service.Replies(item.Id)));
  }
  [Fact] public async Task RelaySealedDeliveryAuthenticatesAndReplaysAcknowledgeWithoutDuplicatingItems()
  {
    var f = new Fixture(); using var sources = new ReceiverSourceService(f.Store, new State(), new TestSecretStore(), "test/", clock: f.Clock); var source = sources.Create("Relay", "project", "webhook"); await sources.SetCredentialAsync(source.Id, "relay-proof-secret-123");
    using var adapter = new ReceiverRelayAdapter(sources); var sent = new List<RelayPacket>(); await adapter.ConnectedAsync((packet, _) => { sent.Add(packet); return ValueTask.CompletedTask; }, CancellationToken.None);
    Assert.Equal(RelayKind.ReceiverSync, sent[0].Kind); Assert.DoesNotContain("relay-proof-secret-123", Encoding.UTF8.GetString(sent[0].Payload));
    var delivery = RandomNumberGenerator.GetBytes(16); var at = f.Clock.GetUtcNow().ToUnixTimeMilliseconds();
    var innerHeader = JsonSerializer.SerializeToUtf8Bytes(new { v = 1, method = "POST", headers = new Dictionary<string, string> { ["authorization"] = "Bearer relay-proof-secret-123" } });
    var inner = Head(innerHeader, "{\"title\":\"Observed\",\"message\":\"A sealed event\"}"u8.ToArray());
    using var recipient = await sources.RelayIdentityAsync(); var ephemeral = RandomNumberGenerator.GetBytes(32); var ephemeralPublic = new byte[32]; X25519.ScalarMultBase(ephemeral, 0, ephemeralPublic, 0); var shared = new byte[32]; Assert.True(X25519.CalculateAgreement(ephemeral, 0, recipient.PublicKey, 0, shared, 0));
    var key = HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 32, ephemeralPublic.Concat(recipient.PublicKey).ToArray(), "td-receiver-seal-v1"u8.ToArray()); var nonce = RandomNumberGenerator.GetBytes(12); var ciphertext = new byte[inner.Length]; var tag = new byte[16];
    using (var aes = new AesGcm(key, 16)) aes.Encrypt(nonce, inner, ciphertext, tag, Encoding.UTF8.GetBytes(source.Id + "." + Convert.ToHexStringLower(delivery) + "." + at));
    var payload = Head(JsonSerializer.SerializeToUtf8Bytes(new { v = 1, sourceId = source.Id, receivedAt = at }), ephemeralPublic.Concat(nonce).Concat(ciphertext).Concat(tag).ToArray());
    var frame = new RelayPacket(RelayKind.ReceiverDelivery, delivery, payload); await adapter.FrameAsync(frame, CancellationToken.None); await adapter.FrameAsync(frame, CancellationToken.None);
    Assert.Single(f.Store.Items(source.Id)); Assert.Equal(2, sent.Count(p => p.Kind == RelayKind.ReceiverAck && p.Payload.SequenceEqual(new byte[] { 1 })));
    CryptographicOperations.ZeroMemory(ephemeral); CryptographicOperations.ZeroMemory(shared); CryptographicOperations.ZeroMemory(key);
  }
  private static byte[] Head(byte[] header, byte[] body)
  { var bytes = new byte[2 + header.Length + body.Length]; BinaryPrimitives.WriteUInt16BigEndian(bytes, checked((ushort)header.Length)); header.CopyTo(bytes, 2); body.CopyTo(bytes, 2 + header.Length); return bytes; }
  private sealed class State : IStateStore<ReceiverSourceSettingsState> { private ReceiverSourceSettingsState? state; public ReceiverSourceSettingsState? Load() => state; public void Save(ReceiverSourceSettingsState value) => state = value; }
  private sealed class ReplyHandler : HttpMessageHandler
  {
    public int Sends; public string? Authorization, Body;
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) { Sends++; Authorization = request.Headers.Authorization?.ToString(); Body = await request.Content!.ReadAsStringAsync(ct); return new(HttpStatusCode.OK); }
  }
}
