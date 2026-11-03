using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Storage;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Mcp;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class PhoneFinishTests
{
  private sealed class Store<T>(T value) : IStateStore<T> { public T? Load() => value; public void Save(T next) => value = next; }
  private static JsonElement Json(object value) => JsonSerializer.SerializeToElement(value);
  [Fact] public async Task PushRoundTripsPhoneAesEnvelopeHonorsPresenceAndChecksRevocationAtDelivery()
  {
    var key = RandomNumberGenerator.GetBytes(32); byte[]? posted = null; var allowed = true;
    var push = new PhonePushFeatures(new Store<PhonePushState>(new([])), (_, _) => allowed,
      () => new("host", new byte[32], new Uri("https://relay.example/")),
      (_, _, bytes, _) => { posted = bytes; return ValueTask.FromResult((200, "{\"apns\":false,\"fcm\":false}"u8.ToArray())); }, "Windows test");
    var phone = new ApprovedDevice("phone", "Phone", "android", PhoneAccess.Look);
    var register = Json(new { mailbox = "abc", key = Convert.ToBase64String(key), platform = "android", sandbox = false, needsYou = true, finished = true, hoot = true, preview = true, onScreen = true, name = "Phone" });
    var reply = Assert.Single(await push.HandleAsync("channel", phone, "push.register", register, null, default));
    Assert.Equal("push.state", reply["t"]!.GetValue<string>());
    var notice = new PhonePushNotice("finished", "session", "Codex", "Private project", "/work", "token=123456789012345678901234567890123456");
    Assert.Equal(0, await push.NotifyAsync(notice)); Assert.Null(posted);
    await push.DisconnectedAsync("channel"); Assert.Equal(1, await push.NotifyAsync(notice));
    using var body = JsonDocument.Parse(posted!); var envelope = body.RootElement.GetProperty("messages")[0];
    Assert.DoesNotContain("Private project", System.Text.Encoding.UTF8.GetString(posted!));
    var encoded = envelope.GetProperty("sealed").GetString()!; var sealedBytes = Convert.FromBase64String(encoded.Replace('-', '+').Replace('_', '/').PadRight((encoded.Length + 3) / 4 * 4, '='));
    var plain = new byte[sealedBytes.Length - 28]; using var aes = new AesGcm(key, 16); aes.Decrypt(sealedBytes.AsSpan(0, 12), sealedBytes.AsSpan(12, plain.Length), sealedBytes.AsSpan(12 + plain.Length, 16), plain);
    using var decoded = JsonDocument.Parse(plain); Assert.Equal("finished", decoded.RootElement.GetProperty("k").GetString()); Assert.Contains("•••", decoded.RootElement.GetProperty("preview").GetString());
    allowed = false; posted = null; Assert.Equal(0, await push.NotifyAsync(notice)); Assert.Null(posted);
    push.Forget("phone"); Assert.Empty(push.DeviceIds());
  }
  [Fact] public async Task PanelRejectsForgedDisabledAndStaleActionsAndBoundsRows()
  {
    var calls = 0; var offered = true;
    var registry = new PhonePanelRegistry((_, p) => p == "/shared", new PhonePanelOwner("tasks", false, (_, _, _) =>
      ValueTask.FromResult(new JsonObject { ["rows"] = new JsonArray(new JsonObject { ["id"] = "one", ["title"] = "Item", ["actions"] = new JsonArray(new JsonObject { ["id"] = "send", ["disabled"] = !offered }) }) }),
      (_, _, _) => { calls++; return ValueTask.CompletedTask; }));
    var device = new ApprovedDevice("phone", "Phone", "ios", PhoneAccess.Work);
    var request = Json(new { panel = "tasks", path = "/shared", id = "one", action = "send" });
    await registry.HandleAsync("ch", device, "panel.act", request, null, default); Assert.Equal(1, calls);
    offered = false; await Assert.ThrowsAsync<PhoneRefusal>(async () => await registry.HandleAsync("ch", device, "panel.act", request, null, default));
    await Assert.ThrowsAsync<PhoneRefusal>(async () => await registry.HandleAsync("ch", device with { Access = PhoneAccess.Look }, "panel.act", request, null, default));
    await Assert.ThrowsAsync<PhoneRefusal>(async () => await registry.HandleAsync("ch", device, "panel.read", Json(new { panel = "tasks", path = "/private" }), null, default)); Assert.Equal(1, calls);
    using var stop = new CancellationTokenSource(); stop.Cancel();
    var management = new PhoneOwnerFeatures((_, _, _, _, token) => { token.ThrowIfCancellationRequested(); throw new InvalidOperationException(); });
    await Assert.ThrowsAnyAsync<OperationCanceledException>(async () => await management.HandleAsync("ch", device, "dev.start", Json(new { }), null, stop.Token));
  }
  [Theory] [InlineData(PhoneAccess.Look)] [InlineData(PhoneAccess.Work)] [InlineData(PhoneAccess.Hoot)]
  public void HootNeverBorrowsOwnerScopeForARestrictedPhone(PhoneAccess access)
  {
    var active = new HootTurn("turn", "ask", new("person") { DeviceId = "phone", Restricted = true }, HootTurnState.Running, DateTimeOffset.UtcNow, "chat");
    var state = HootState.Empty with { ChatId = "chat", Turns = [active] };
    var grant = new McpGrant("hoot:chat", "chat", null, true, AiPermissionMode.Bypass, [], [], ["*"], DateTimeOffset.UtcNow.AddHours(1), SeatId: HootDesk.Seat);
    ApprovedDevice? Current(string id) => new(id, "Phone", "ios", access);
    Assert.Throws<McpRefusal>(() => HootPhoneAuthority.Check(grant, "sessions.send", Json(new { sessionId = "unshared" }), state, Current, (_, _, _) => false, McpTier.Act));
    Assert.Throws<McpRefusal>(() => HootPhoneAuthority.Check(grant, "remote.workspace", Json(new { }), state, Current, (_, _, _) => true, McpTier.Alter));
    Assert.Throws<McpRefusal>(() => HootPhoneAuthority.Check(grant, "sessions.read", Json(new { sessionId = "shared" }), state, _ => null, (_, _, _) => true, McpTier.Read));
  }
}
