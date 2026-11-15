using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

// Reach by account on this PC, ported case for case from the Mac's BackendReachAccountTests.swift (lane/mac-next2): the
// gate, the door, presence, the HTTP client in the service's real formats, the relay's open mark, the phone host's
// `reach:` hello and the cut-offs, against fakes. Plus: a paired device is never touched by any of it.
public sealed class ReachAccountTests : IDisposable
{
  public const string PhoneId = "0f1e2d3c-4b5a-4968-8776-a5b4c3d2e1f0";
  public const string OtherId = "11111111-2222-4333-8444-555555555555";
  public const string MacId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
  private readonly List<string> folders = [];
  public void Dispose() { foreach (var f in folders) try { Directory.Delete(f, true); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
  private string Folder() { var f = Path.Combine(Path.GetTempPath(), "td-reach-" + Guid.NewGuid().ToString("N")); folders.Add(f); return f; }

  internal sealed class FakeService(ReachRoster roster) : IReachAccountService
  {
    private readonly object gate = new();
    public string? Account { get; set; } = "acct-A";
    public bool Entitled { get; set; } = true;
    public ReachRoster Roster { get; set; } = roster;
    public int RosterFetches, Tokens;
    public List<ReachPresenceRecord> Published { get; } = [];
    public List<string> Withdrawn { get; } = [];
    public List<string> Removed { get; } = [];
    public string? SignedInAccount() => Account;
    public string? MachineDeviceId() => MacId;
    public Task<bool> ReachEntitledAsync(CancellationToken ct = default) => Task.FromResult(Entitled);
    public Task<ReachRoster> RosterAsync(CancellationToken ct = default) { lock (gate) { RosterFetches++; return Task.FromResult(Roster); } }
    public Task<ReachRelayToken> RelayTokenAsync(CancellationToken ct = default)
    { lock (gate) Tokens++; return Task.FromResult(new ReachRelayToken("a.b.c", DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + 900_000)); }
    public Task PublishAsync(ReachPresenceRecord presence, CancellationToken ct = default) { lock (gate) Published.Add(presence); return Task.CompletedTask; }
    public Task WithdrawAsync(string deviceId, CancellationToken ct = default) { lock (gate) Withdrawn.Add(deviceId); return Task.CompletedTask; }
    public Task RemoveDeviceAsync(string deviceId, CancellationToken ct = default) { lock (gate) Removed.Add(deviceId); return Task.CompletedTask; }
  }
  internal sealed class FakeRelay : IReachRelayDoor
  {
    public bool Attached { get; private set; }
    public Task AttachAccountAsync(ReachRelayToken token) { Attached = true; return Task.CompletedTask; }
    public Task DetachAccountAsync() { Attached = false; return Task.CompletedTask; }
  }
  internal sealed class Clock { public double Ms = 1_800_000_000_000; public double Now() => Ms; }

  internal sealed class Rig
  {
    public readonly string Dir;
    public readonly FakeService Service;
    public readonly FakeRelay Relay = new();
    public readonly List<ReachNotice> Notices = [];
    public readonly Clock Clock = new();
    public readonly ReachAccountGate Gate;
    public readonly NoiseIdentity Host = NoiseIdentity.Generate();
    public readonly NoiseIdentity Phone = NoiseIdentity.Generate();
    public bool Posted;
    public Rig(string dir, IReadOnlyList<ReachRosterDevice>? devices = null, bool phoneActive = true, bool guardPosted = false)
    {
      Dir = dir; Posted = guardPosted;
      Service = new(new("acct-A", "1", ReachPolicy.AccountOnly, devices ?? [new(PhoneId, "Asad's iPhone", "ios", Phone.PublicKey, Active: phoneActive)]));
      Gate = NewGate();
    }
    public ReachAccountGate NewGate() => new(Dir, Service, n => { lock (Notices) Notices.Add(n); }, () => Posted, Clock.Now);
    public void On() => Gate.SetEnabled(true);
    public NoiseStart Frame(NoiseIdentity device) => NoiseChannel.Start(device, Host.PublicKey);
    public ReachPresence Presence() => new(Gate, Service, Relay, () => new("ABCDEFGHJKLMNPQRSTUVWXYZ23", ReachWire.Base64Url(Host.PublicKey), "Studio PC")); // real time, as the token's
  }

  private static async Task<ReachRefusal> Refusal(Func<Task> act) { try { await act(); } catch (ReachRefusedException r) { return r.Why; } throw new Xunit.Sdk.XunitException("expected a refusal"); }
  private static ReachRefusal? Why(ReachDecision d) => d is ReachDecision.Refused r ? r.Why : null;

  // ---- R1 cases, on the service's formats ----

  [Fact]
  public async Task OffByDefaultNothingPublishedTheRoomUntiedEveryDeviceRefused()
  {
    var rig = new Rig(Folder());
    Assert.Equal(new ReachSettings(false, ReachPolicy.AccountOnly), rig.Gate.Settings());
    Assert.Equal(ReachRefusal.SwitchOff, Why(await rig.Gate.AdmitAsync(rig.Phone.PublicKey)));
    Assert.Empty(await rig.Gate.CandidateKeysAsync());
    Assert.Equal(ReachPresenceStatus.Off, await rig.Presence().SyncAsync());
    Assert.Empty(rig.Service.Published); Assert.Equal(0, rig.Service.Tokens); Assert.False(rig.Relay.Attached);
    Assert.Equal(ReachRefusal.SwitchOff, await Refusal(() => new ReachAccountDoor(rig.Gate).AnswerAsync(rig.Host, rig.Frame(rig.Phone).Message)));
    Assert.Empty(rig.Notices);
    // A damaged settings file reads as OFF too.
    Directory.CreateDirectory(rig.Dir);
    File.WriteAllText(Path.Combine(rig.Dir, ReachAccountGate.FileName), "{not json");
    Assert.False(rig.NewGate().Settings().Enabled);
  }

  [Fact]
  public void OnByDefaultForAPcThatNeverChoseOnceAChoiceAndADamagedFileAreKept()
  {
    var rig = new Rig(Folder());
    Assert.True(rig.Gate.SwitchOnByDefaultIfNeverChosen());
    Assert.True(rig.Gate.Settings().Enabled);
    Assert.False(rig.Gate.SwitchOnByDefaultIfNeverChosen()); // once only
    rig.Gate.SetEnabled(false);
    var again = rig.NewGate();
    Assert.False(again.SwitchOnByDefaultIfNeverChosen());
    Assert.False(again.Settings().Enabled); // the person's off is kept
    var damaged = new Rig(Folder());
    Directory.CreateDirectory(damaged.Dir);
    File.WriteAllText(Path.Combine(damaged.Dir, ReachAccountGate.FileName), "{not json");
    var gate = damaged.NewGate();
    Assert.False(gate.SwitchOnByDefaultIfNeverChosen());
    Assert.False(gate.Settings().Enabled); // a damaged file still reads as OFF
  }

  [Fact]
  public async Task SwitchedOnPresenceIsPublishedAndTheRoomTiedOffWithdrawsBoth()
  {
    var rig = new Rig(Folder());
    rig.On();
    var presence = rig.Presence();
    Assert.Equal(ReachPresenceStatus.Published, await presence.SyncAsync());
    Assert.True(rig.Relay.Attached);
    Assert.Equal("ABCDEFGHJKLMNPQRSTUVWXYZ23", rig.Service.Published[^1].HostId);
    Assert.Equal(ReachWire.Base64Url(rig.Host.PublicKey), rig.Service.Published[^1].HostKey);
    Assert.Equal("windows", rig.Service.Published[^1].Platform);
    // A second minute: published again, the 15-minute token is not asked again.
    Assert.Equal(ReachPresenceStatus.Published, await presence.SyncAsync());
    Assert.Equal(1, rig.Service.Tokens);
    rig.Gate.SetEnabled(false);
    Assert.Equal(ReachPresenceStatus.Off, await presence.SyncAsync());
    Assert.False(rig.Relay.Attached);
    Assert.Equal([MacId], rig.Service.Withdrawn);
    rig.Service.Entitled = false;
    rig.Clock.Ms += ReachAccountGate.EntitlementMaxAgeMs + 1;
    rig.Gate.SetEnabled(true);
    Assert.Equal(ReachPresenceStatus.NotEntitled, await presence.SyncAsync());
  }

  [Fact]
  public async Task ADeviceOfAnotherAccountIsRefusedAtTheHandshakeAndByTheGate()
  {
    var rig = new Rig(Folder());
    rig.On();
    using var stranger = NoiseIdentity.Generate();
    Assert.Equal(ReachRefusal.UnknownDevice, Why(await rig.Gate.AdmitAsync(stranger.PublicKey)));
    Assert.Equal(ReachRefusal.UnknownDevice, await Refusal(() => new ReachAccountDoor(rig.Gate).AnswerAsync(rig.Host, rig.Frame(stranger).Message)));
    // This PC signed in to account B while it still held A's list: nothing from that list is trusted.
    rig.Service.Account = "acct-B";
    Assert.Equal(ReachRefusal.OtherAccount, Why(await rig.Gate.AdmitAsync(rig.Phone.PublicKey)));
    rig.Service.Account = null;
    Assert.Equal(ReachRefusal.SignedOut, Why(await rig.Gate.AdmitAsync(rig.Phone.PublicKey)));
    Assert.Empty(rig.Notices);
  }

  [Fact]
  public async Task ARemovedDeviceIsRefusedInTheAccountOrWithOneClickOnThisPc()
  {
    var rig = new Rig(Folder(), phoneActive: false);
    rig.On();
    Assert.Equal(ReachRefusal.Removed, Why(await rig.Gate.AdmitAsync(rig.Phone.PublicKey)));

    using var flagged = NoiseIdentity.Generate();
    var viaFlag = new Rig(Folder(), [new(PhoneId, "iPhone", "ios", flagged.PublicKey, Active: true, Removed: true)]);
    viaFlag.On();
    Assert.Equal(ReachRefusal.Removed, Why(await viaFlag.Gate.AdmitAsync(flagged.PublicKey)));

    var local = new Rig(Folder());
    local.On();
    Assert.IsType<ReachDecision.Admitted>(await local.Gate.AdmitAsync(local.Phone.PublicKey));
    local.Gate.Remove(PhoneId);
    Assert.Equal(ReachRefusal.Removed, Why(await local.Gate.AdmitAsync(local.Phone.PublicKey)));
    Assert.Empty(await local.Gate.CandidateKeysAsync());

    // Signed out on that device: refused too.
    using var other = NoiseIdentity.Generate();
    var signedOut = new Rig(Folder(), [new(PhoneId, "iPhone", "ios", other.PublicKey, SessionLive: false)]);
    signedOut.On();
    Assert.Empty(await signedOut.Gate.CandidateKeysAsync());
  }

  [Fact]
  public async Task MissingEntitlementIsRefusedEvenWithTheSwitchOn()
  {
    var rig = new Rig(Folder());
    rig.Service.Entitled = false;
    rig.On();
    Assert.Equal(ReachRefusal.NotEntitled, Why(await rig.Gate.AdmitAsync(rig.Phone.PublicKey)));
    Assert.Equal(ReachPresenceStatus.NotEntitled, await rig.Presence().SyncAsync());
    Assert.False(rig.Relay.Attached);
  }

  [Fact]
  public async Task ANewDevicesFirstConnectionRaisesTheNoticeOnceInNamesOnlyAndTheChannelOpens()
  {
    var rig = new Rig(Folder());
    rig.On();
    var door = new ReachAccountDoor(rig.Gate);
    var start = rig.Frame(rig.Phone);
    var opened = await door.AnswerAsync(rig.Host, start.Message, PhoneId);
    Assert.Equal(PhoneId, opened.Admission.DeviceId);
    Assert.True(opened.Admission.FirstTime);
    var notice = Assert.Single(rig.Notices);
    Assert.Equal(new ReachNotice(ReachNoticeKind.FirstConnection, PhoneId, "Asad's iPhone", "ios"), notice);
    Assert.Equal("Asad's iPhone connected to this PC for the first time.", notice.Sentence);
    Assert.DoesNotContain(PhoneId, notice.Sentence);
    Assert.DoesNotContain(ReachWire.Base64Url(rig.Phone.PublicKey), notice.Sentence);
    // The device finishes the same sealed handshake: a frame it seals opens on this PC.
    using var client = NoiseChannel.Finish(start.Pending, opened.Response.Reply);
    Assert.Equal("hello"u8.ToArray(), opened.Response.Transport.Receive(client.Send("hello"u8.ToArray())));
    // Second time: no notice.
    var second = await door.AnswerAsync(rig.Host, rig.Frame(rig.Phone).Message);
    Assert.False(second.Admission.FirstTime);
    Assert.Single(rig.Notices);
    // The pin survives a restart of the app.
    var again = Assert.IsType<ReachDecision.Admitted>(await rig.NewGate().AdmitAsync(rig.Phone.PublicKey));
    Assert.False(again.Admission.FirstTime);
  }

  [Fact]
  public async Task TheRelaysMarkMustNameTheDeviceWhoseKeyFinishedTheHandshake()
  {
    var rig = new Rig(Folder());
    rig.On();
    Assert.Equal(ReachRefusal.WrongDevice, await Refusal(() => new ReachAccountDoor(rig.Gate).AnswerAsync(rig.Host, rig.Frame(rig.Phone).Message, OtherId)));
    Assert.Empty(rig.Notices); // no pin and no notice for a channel the relay mislabelled
  }

  [Fact]
  public async Task ThePinnedKeyWinsTheSameDeviceIdWithANewKeyIsRefusedWithANotice()
  {
    var rig = new Rig(Folder());
    rig.On();
    _ = await rig.Gate.AdmitAsync(rig.Phone.PublicKey);
    using var swapped = NoiseIdentity.Generate();
    rig.Service.Roster = new("acct-A", "2", ReachPolicy.AccountOnly, [new(PhoneId, "iPhone", "ios", swapped.PublicKey)]);
    rig.Gate.RosterChanged();
    Assert.Equal(ReachRefusal.KeyChanged, Why(await rig.Gate.AdmitAsync(swapped.PublicKey)));
    Assert.Equal(new ReachNotice(ReachNoticeKind.KeyChanged, PhoneId, "iPhone"), rig.Notices[^1]);
  }

  [Fact]
  public async Task PolicyBANewDeviceWaitsForAnApprovalMadeAtThisPc()
  {
    var rig = new Rig(Folder());
    rig.On();
    rig.Gate.SetPolicy(ReachPolicy.ApproveNew);
    Assert.Equal(ReachRefusal.NotApproved, Why(await rig.Gate.AdmitAsync(rig.Phone.PublicKey)));
    Assert.Equal(new ReachNotice(ReachNoticeKind.AwaitingApproval, PhoneId, "Asad's iPhone", "ios"), rig.Notices[^1]);
    rig.Gate.Approve(PhoneId);
    Assert.IsType<ReachDecision.Admitted>(await rig.Gate.AdmitAsync(rig.Phone.PublicKey));
  }

  [Fact]
  public void TheRemoteInputGuardStillRefusesTrustPressesSwitchingOnLooseningApproving()
  {
    var rig = new Rig(Folder(), guardPosted: true);
    Assert.Throws<ReachRemoteInputException>(() => rig.Gate.SetEnabled(true));
    Assert.False(rig.Gate.Settings().Enabled);
    Assert.Throws<ReachRemoteInputException>(() => rig.Gate.Approve(PhoneId));
    rig.Gate.SetPolicy(ReachPolicy.ApproveNew); // stricter: taken
    Assert.Throws<ReachRemoteInputException>(() => rig.Gate.SetPolicy(ReachPolicy.AccountOnly));
    Assert.Equal(ReachPolicy.ApproveNew, rig.Gate.Settings().Policy);
    rig.Gate.SetEnabled(false); // off is always taken
  }

  [Fact]
  public async Task KnockingTooOftenIsRefusedNothingThatCannotBeFoundOutIsLetIn()
  {
    var rig = new Rig(Folder());
    rig.On();
    for (var i = 0; i < ReachAccountGate.HandshakesPerMinute; i++) _ = await rig.Gate.AdmitAsync(rig.Phone.PublicKey);
    Assert.Equal(ReachRefusal.RateLimited, Why(await rig.Gate.AdmitAsync(rig.Phone.PublicKey)));
    rig.Clock.Ms += 61_000;
    Assert.IsType<ReachDecision.Admitted>(await rig.Gate.AdmitAsync(rig.Phone.PublicKey));
    rig.Service.Entitled = false;
    rig.Clock.Ms += ReachAccountGate.EntitlementMaxAgeMs + 1;
    Assert.Equal(ReachRefusal.NotEntitled, Why(await rig.Gate.AdmitAsync(rig.Phone.PublicKey)));
  }

  // ---- The service's and the relay's formats ----

  [Fact]
  public void SignedTextsAndCanonicalJsonAreByteForByteTheServices()
  {
    Assert.Equal("TD-REACH-KEY-1\n" + PhoneId + "\nAAAA", ReachWire.ReachKeyMessage(PhoneId, "AAAA"));
    Assert.Equal("TD-REACH-APPROVE-1\n" + PhoneId + "\nAAAA", ReachWire.ApproveMessage(PhoneId, "AAAA"));
    var record = new ReachPresenceRecord(MacId, "ABCDEFGHJKLMNPQRSTUVWXYZ23", "k_-K", "Studio \"Mac\"\\é\n\u0001", "macos", ReachPolicy.AccountOnly);
    // What JSON.stringify writes for each value, keys sorted: the service signs exactly this text (the Mac's literal).
    const string expected = "{\"deviceId\":\"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee\",\"hostId\":\"ABCDEFGHJKLMNPQRSTUVWXYZ23\",\"hostKey\":\"k_-K\",\"name\":\"Studio \\\"Mac\\\"\\\\é\\n\\u0001\",\"platform\":\"macos\",\"policy\":\"A\",\"signedAt\":1800000000123}";
    Assert.Equal(expected, ReachWire.PresenceCanonical(record, 1_800_000_000_123));
    Assert.Equal("TD-REACH-PRESENCE-1\n" + expected, ReachWire.PresenceMessage(record, 1_800_000_000_123));
    Assert.Contains("\"policy\":\"A\",\"sig\":\"S\",\"signedAt\":1}", ReachWire.PresenceBody(record, 1, "S"));
  }

  [Fact]
  public void KeysAndSignaturesAreBase64UrlWithoutPaddingStrictly()
  {
    var bytes = Enumerable.Range(0, 32).Select(i => (byte)(i * 7 % 256)).ToArray();
    var text = ReachWire.Base64Url(bytes);
    Assert.DoesNotContain('=', text); Assert.DoesNotContain('+', text); Assert.DoesNotContain('/', text);
    Assert.Equal(bytes, ReachWire.UnBase64Url(text, 32));
    Assert.Null(ReachWire.UnBase64Url(text + "=", 32));
    Assert.Null(ReachWire.UnBase64Url(text, 31));
    var standard = Convert.ToBase64String(bytes);
    if (standard.Any(c => "+/=".Contains(c))) Assert.Null(ReachWire.UnBase64Url(standard, 32));
  }

  [Fact]
  public void TheRelaysOpenMarkEmptyIsPairedMarkedIsAccountMarkedButUnreadableIsClosed()
  {
    Assert.Equal(ReachWire.OpenKindTag.Paired, ReachWire.ReadOpen([]).Tag);
    Assert.Equal(ReachWire.OpenKindTag.Paired, ReachWire.ReadOpen([1, 2, 3]).Tag);
    // relay/cloudflare/src/reach.ts reachOpenPayload(deviceId)
    byte[] marked = [0x52, 0x01, .. Encoding.ASCII.GetBytes(PhoneId)];
    Assert.Equal(new ReachWire.OpenKind(ReachWire.OpenKindTag.Account, PhoneId), ReachWire.ReadOpen(marked));
    Assert.Equal(marked, ReachWire.OpenPayload(PhoneId));
    Assert.Equal(ReachWire.OpenKindTag.Invalid, ReachWire.ReadOpen([0x52]).Tag);
    Assert.Equal(ReachWire.OpenKindTag.Invalid, ReachWire.ReadOpen([0x52, 0x02, .. Encoding.ASCII.GetBytes(PhoneId)]).Tag);
    Assert.Equal(ReachWire.OpenKindTag.Invalid, ReachWire.ReadOpen([0x52, 0x01, .. Encoding.ASCII.GetBytes("not-a-device")]).Tag);
  }

  [Fact]
  public void TheDeviceListAnswerIsReadAsTheServiceWritesItUnreadableRowsAreDropped()
  {
    using var k = NoiseIdentity.Generate();
    var key = ReachWire.Base64Url(k.PublicKey);
    var json = "{\"account\":\"acct-A\",\"version\":\"7\",\"policy\":\"B\",\"devices\":[" +
      "{\"deviceId\":\"" + PhoneId + "\",\"label\":\"iPhone\",\"platform\":\"ios\",\"reachKey\":\"" + key + "\",\"active\":true,\"removed\":false,\"sessionLive\":true,\"expiresAtMs\":null,\"approved\":true,\"approvedBy\":\"" + MacId + "\",\"approvalSig\":\"c2ln\"}," +
      "{\"deviceId\":\"" + OtherId + "\",\"label\":\"Browser\",\"platform\":\"web\",\"reachKey\":\"" + key + "\",\"active\":false,\"removed\":true,\"sessionLive\":false,\"expiresAtMs\":1800000000000,\"approved\":false,\"approvedBy\":null,\"approvalSig\":null}," +
      "{\"deviceId\":\"bad\",\"label\":\"x\",\"platform\":\"ios\",\"reachKey\":\"" + key + "\",\"active\":true,\"removed\":false,\"sessionLive\":true,\"expiresAtMs\":null,\"approved\":false,\"approvedBy\":null,\"approvalSig\":null}]}";
    var roster = ReachWire.Roster(JsonDocument.Parse(json).RootElement);
    Assert.True(roster.Account == "acct-A" && roster.Version == "7" && roster.Policy == ReachPolicy.ApproveNew);
    Assert.Equal(2, roster.Devices.Count);
    Assert.True(roster.Devices[0].ApprovedBy == MacId && roster.Devices[0].Approved && roster.Devices[0].ExpiresAtMs is null);
    Assert.True(roster.Devices[1].Removed && roster.Devices[1].ExpiresAtMs == 1_800_000_000_000);
    var push = JsonDocument.Parse("{\"devicesVersion\":\"8\",\"reachRemoved\":[\"" + PhoneId + "\",\"junk\"]}").RootElement;
    Assert.Equal([PhoneId], ReachWire.RemovedIds(push));
  }

  // ---- The HTTP client ----

  internal sealed class FakeHttp(Func<CloudSyncHttpRequest, CloudSyncHttpResponse> answer) : ICloudSyncHttp
  {
    public List<CloudSyncHttpRequest> Sent { get; } = [];
    public Task<CloudSyncHttpResponse> SendAsync(CloudSyncHttpRequest request, CancellationToken ct) { lock (Sent) Sent.Add(request); return Task.FromResult(answer(request)); }
  }
  private static CloudSyncHttpResponse Ok(string body) => new(200, Encoding.UTF8.GetBytes(body));

  [Fact]
  public async Task EveryReachRouteIsASignedDeviceRequestPresenceCarriesSignedAtAndItsOwnSignature()
  {
    using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var http = new FakeHttp(r => (r.Method, r.Url.AbsolutePath) switch
    {
      ("GET", "/v1/capabilities") => Ok("{\"features\":[\"cloud\",\"reach\"],\"session\":\"valid\"}"),
      ("POST", "/v1/reach/token") => Ok("{\"token\":\"h.b.s\",\"expiresAt\":1800000900000,\"scope\":\"reach-host\"}"),
      ("GET", "/v1/reach/devices") => Ok("{\"account\":\"acct-A\",\"version\":\"3\",\"policy\":\"A\",\"devices\":[]}"),
      _ => Ok("{}")
    });
    var service = new ReachAccountHttpService(new Uri("https://td-cloud-test.example.test/v1"), http, new(() => "acct-A", () => MacId,
      _ => Task.FromResult("access-1"), bytes => key.SignData(bytes, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation)), () => 1_800_000_000_000);
    Assert.True(await service.ReachEntitledAsync());
    Assert.Equal(new ReachRelayToken("h.b.s", 1_800_000_900_000, "reach-host"), await service.RelayTokenAsync());
    Assert.Equal("3", (await service.RosterAsync()).Version);
    var record = new ReachPresenceRecord(MacId, "ABCDEFGHJKLMNPQRSTUVWXYZ23", "kkk", "Studio PC", "windows", ReachPolicy.AccountOnly);
    await service.PublishAsync(record);
    await service.WithdrawAsync(MacId);
    await service.RemoveDeviceAsync(PhoneId);

    var sent = http.Sent;
    Assert.Equal(["GET", "POST", "GET", "PUT", "DELETE", "POST"], sent.Select(s => s.Method));
    // /capabilities: bearer only, no device proof.
    Assert.Equal("Bearer access-1", sent[0].Headers["authorization"]);
    Assert.False(sent[0].Headers.ContainsKey("x-td-signature"));
    foreach (var request in sent.Skip(1))
    {
      Assert.Equal("Bearer access-1", request.Headers["authorization"]);
      Assert.Equal(MacId, request.Headers["x-td-device"]); Assert.Equal("1800000000000", request.Headers["x-td-time"]);
      var requestId = request.Headers["x-td-request"];
      var text = ReachAccountHttpService.ProofText(request.Method, request.Url.AbsolutePath, 1_800_000_000_000, requestId, request.Body);
      Assert.StartsWith("TD-CLOUD-1\n" + request.Method + "\n" + request.Url.AbsolutePath + "\n1800000000000\n" + requestId + "\n", text);
      var sig = ReachWire.UnBase64Url(request.Headers["x-td-signature"], 64)!;
      Assert.True(key.VerifyData(Encoding.UTF8.GetBytes(text), sig, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation));
    }
    // GET hashes the empty body.
    Assert.EndsWith("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", ReachAccountHttpService.ProofText("GET", "/v1/reach/devices", 1, "r", []));
    // The presence body: the seven fields + sig; the sig verifies over TD-REACH-PRESENCE-1 + canonical JSON.
    var body = JsonDocument.Parse(sent[3].Body).RootElement;
    Assert.Equal(1_800_000_000_000, body.GetProperty("signedAt").GetInt64());
    Assert.Equal("A", body.GetProperty("policy").GetString()); Assert.Equal("kkk", body.GetProperty("hostKey").GetString());
    var psig = ReachWire.UnBase64Url(body.GetProperty("sig").GetString(), 64)!;
    Assert.True(key.VerifyData(Encoding.UTF8.GetBytes(ReachWire.PresenceMessage(record, 1_800_000_000_000)), psig, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation));
    Assert.Equal("{\"deviceId\":\"" + PhoneId + "\"}", Encoding.UTF8.GetString(sent[5].Body));
  }

  [Fact]
  public async Task ARefusedAccessTokenIsAskedAgainOnceAServiceRefusalBecomesAnError()
  {
    var asked = 0;
    var http = new FakeHttp(r => r.Headers["authorization"] == "Bearer fresh"
      ? new(403, Encoding.UTF8.GetBytes("{\"error\":{\"code\":\"reach_required\"}}"))
      : new(401, Encoding.UTF8.GetBytes("{\"error\":{\"code\":\"sign_in_required\"}}")));
    var service = new ReachAccountHttpService(new Uri("https://td-cloud-test.example.test/v1"), http, new(() => "acct-A", () => MacId,
      _ => Task.FromResult(++asked == 1 ? "stale" : "fresh"), _ => new byte[64]));
    var refused = await Assert.ThrowsAsync<ReachServiceException>(() => service.RosterAsync());
    Assert.Equal("reach_required", refused.Code); Assert.False(refused.Retryable);
    Assert.Equal(2, http.Sent.Count); Assert.Equal(2, asked);
  }

  // ---- The phone host, the relay connection, the coordinator ----

  private static readonly byte[] ChannelA = Enumerable.Range(0, 16).Select(i => (byte)i).ToArray();
  private static readonly byte[] ChannelB = Enumerable.Range(16, 16).Select(i => (byte)i).ToArray();
  private static byte[] Packet(RelayKind kind, byte[] payload, byte[] channel) => new RelayPacket(kind, channel, payload).Encode();
  private static byte[] Hello(string token) => JsonSerializer.SerializeToUtf8Bytes(new
  {
    // A desktop guest (another of his computers): its welcome stays on the relay, so the test reads it there (a phone's
    // goes on the direct link, which these fakes do not make).
    t = "hello", protocol = 1, token, device = new { name = "Studio Mac", platform = "macos" }, capabilities = Array.Empty<string>()
  });

  internal sealed class HostRig
  {
    public readonly DeviceTrust Trust = new(new TestTrustStore());
    public readonly ReachRelayLink Link = new();
    public readonly RelayHostConnection Connection;
    public readonly NoiseIdentity Host = NoiseIdentity.Generate();
    public HostRig()
    {
      Link.Admitted = (channel, admission) => Trust.AdmitReachChannel(channel, admission);
      Connection = new RelayHostConnection(Host, new PhoneLink(Trust, "Test PC", "0.1", new TestSessionView())) { Reach = Link };
    }
    /// Opens a channel (marked for `account`, or unmarked) and runs the device's sealed handshake. Null when closed.
    public async Task<NoiseTransport?> OpenAsync(NoiseIdentity device, byte[] channel, string? account)
    {
      var open = await Connection.ProcessAsync(Packet(RelayKind.Open, account is null ? [] : ReachWire.OpenPayload(account), channel));
      if (open.Count > 0) return null;
      var start = NoiseChannel.Start(device, Host.PublicKey);
      var frames = await Connection.ProcessAsync(Packet(RelayKind.Data, RelayPacket.FrameHandshake(start.Message), channel));
      var reply = RelayPacket.Decode(frames[0]);
      if (reply.Kind != RelayKind.Data) return null;
      return NoiseChannel.Finish(start.Pending, RelayPacket.ReadHandshake(reply.Payload, false));
    }
    /// Says hello; true when welcomed.
    public async Task<bool> HelloAsync(NoiseTransport client, byte[] channel, string token)
    {
      var packets = await Connection.ProcessAsync(Packet(RelayKind.Data, client.Send(Hello(token)), channel));
      foreach (var raw in packets)
      {
        var packet = RelayPacket.Decode(raw);
        if (packet.Kind != RelayKind.Data) continue;
        using var doc = JsonDocument.Parse(client.Receive(packet.Payload));
        if (doc.RootElement.GetProperty("t").GetString() == "welcome") return true;
      }
      return false;
    }
  }

  private ReachAccountCoordinator Coordinator(string dir, FakeService service, HostRig? rig, ReachRelayLink? link = null) =>
    new(dir, service, _ => { }, rig?.Trust, () => new("ABCDEFGHJKLMNPQRSTUVWXYZ23", "k", "PC"), link ?? rig?.Link ?? new ReachRelayLink(), () => false, tick: TimeSpan.FromHours(1));

  [Fact]
  public async Task ThePhoneHostTakesReachOnlyOnAChannelTheDoorAdmittedWithThatDevicesKeyFullAccess()
  {
    var rig = new HostRig();
    using var phone = NoiseIdentity.Generate();
    var service = new FakeService(new("acct-A", "1", ReachPolicy.AccountOnly, [new(PhoneId, "Asad's iPhone", "ios", phone.PublicKey)]));
    var coordinator = Coordinator(Folder(), service, rig);
    await coordinator.StartAsync();
    await coordinator.SetEnabledAsync(true);
    // Admitted channel, matching hello: welcomed, full access, the person's own device, the pairing list untouched.
    using var ok = await rig.OpenAsync(phone, ChannelA, PhoneId);
    Assert.NotNull(ok);
    Assert.True(await rig.HelloAsync(ok!, ChannelA, "reach:" + PhoneId));
    var hostId = ReachAdmission.HostId(PhoneId);
    var device = rig.Trust.RequireCurrent(hostId, phone.PublicKey);
    Assert.Equal(PhoneAccess.Full, device.Access);
    Assert.Empty(rig.Trust.List()); // the pairing roster is not touched
    Assert.Equal(new HashSet<string> { PhoneId }, rig.Trust.ReachConnectedDeviceIds());
    // The same phone key on an UNMARKED channel: the sealed channel never opens (not a paired key).
    Assert.Null(await rig.OpenAsync(phone, ChannelB, null));
    // Another device's name on an admitted channel: refused.
    var rig2 = new HostRig();
    var c2 = Coordinator(Folder(), service, rig2);
    await c2.StartAsync(); await c2.SetEnabledAsync(true);
    using var wrong = await rig2.OpenAsync(phone, ChannelA, PhoneId);
    Assert.False(await rig2.HelloAsync(wrong!, ChannelA, "reach:" + OtherId));
    // A paired credential on an admitted channel: refused (an account channel never takes the pairing path).
    var rig3 = new HostRig();
    var c3 = Coordinator(Folder(), service, rig3);
    await c3.StartAsync(); await c3.SetEnabledAsync(true);
    using var mixed = await rig3.OpenAsync(phone, ChannelA, PhoneId);
    Assert.False(await rig3.HelloAsync(mixed!, ChannelA, "abcdefgh.c2VjcmV0"));
    // A marked channel whose key is not in the roster never opens.
    using var stranger = NoiseIdentity.Generate();
    Assert.Null(await rig3.OpenAsync(stranger, ChannelB, PhoneId));
    await coordinator.StopAsync(); await c2.StopAsync(); await c3.StopAsync();
  }

  [Fact]
  public async Task PairedDevicesAreUnaffectedAPairedDeviceStillPairsAndSaysHelloReachOnOrOff()
  {
    var rig = new HostRig();
    using var old = NoiseIdentity.Generate();
    // Paired before any of this (as on a PC updated from 0.21.x): the stored row is the same.
    var receipt = rig.Trust.Redeem(rig.Trust.Pairing.Create().Code, "Old phone", "ios", old.PublicKey);
    rig.Trust.Approve(receipt.DeviceId, PhoneAccess.Full);
    using (var first = await rig.OpenAsync(old, ChannelA, null)) Assert.True(await rig.HelloAsync(first!, ChannelA, receipt.Credential));
    var service = new FakeService(new("acct-A", "1", ReachPolicy.AccountOnly, []));
    var coordinator = Coordinator(Folder(), service, rig);
    await coordinator.StartAsync();
    await coordinator.SetEnabledAsync(true);
    Assert.True(rig.Trust.PairingLockedByReach);
    using (var again = await rig.OpenAsync(old, ChannelB, null)) Assert.True(await rig.HelloAsync(again!, ChannelB, receipt.Credential));
    Assert.Single(rig.Trust.List());
    Assert.Empty(rig.Trust.ReachConnectedDeviceIds());
    // A paired device is never cut by reach.
    await coordinator.SetEnabledAsync(false);
    Assert.Equal(receipt.DeviceId, rig.Trust.RequireCurrent(receipt.DeviceId, old.PublicKey).Id);
    await coordinator.StopAsync();
  }

  [Fact]
  public async Task RemovalCutsALiveAccountChannelAtOncePairedOnesStay()
  {
    var rig = new HostRig();
    using var phone = NoiseIdentity.Generate(); using var old = NoiseIdentity.Generate();
    var receipt = rig.Trust.Redeem(rig.Trust.Pairing.Create().Code, "Old", "ios", old.PublicKey);
    rig.Trust.Approve(receipt.DeviceId, PhoneAccess.Full);
    var service = new FakeService(new("acct-A", "1", ReachPolicy.AccountOnly, [new(PhoneId, "Asad's iPhone", "ios", phone.PublicKey)]));
    var coordinator = Coordinator(Folder(), service, rig);
    await coordinator.StartAsync();
    using var paired = await rig.OpenAsync(old, ChannelB, null);
    Assert.True(await rig.HelloAsync(paired!, ChannelB, receipt.Credential));
    await coordinator.SetEnabledAsync(true);
    using var client = await rig.OpenAsync(phone, ChannelA, PhoneId);
    Assert.True(await rig.HelloAsync(client!, ChannelA, "reach:" + PhoneId));
    Assert.Equal(new HashSet<string> { PhoneId }, rig.Trust.ReachConnectedDeviceIds());
    // The service says it was removed.
    await coordinator.EventAsync("devices", JsonDocument.Parse("{\"devicesVersion\":\"2\",\"reachRemoved\":[\"" + PhoneId + "\"]}").RootElement);
    await rig.Connection.CloseAccountChannelsAsync([PhoneId]); // what the link does for each live relay client
    Assert.Empty(rig.Trust.ReachConnectedDeviceIds());
    Assert.Throws<ProtocolException>(() => rig.Trust.RequireCurrent(ReachAdmission.HostId(PhoneId), phone.PublicKey));
    // The paired device's channel is still open and answered.
    var ping = await rig.Connection.ProcessAsync(Packet(RelayKind.Data, paired!.Send(JsonSerializer.SerializeToUtf8Bytes(new { t = "ping" })), ChannelB));
    Assert.Contains(ping, p => RelayPacket.Decode(p).Kind == RelayKind.Data);
    // Remove on this PC: refused, and the service told.
    await coordinator.RemoveAsync(PhoneId);
    Assert.Equal([PhoneId], service.Removed);
    Assert.Equal(ReachRefusal.Removed, Why(await coordinator.Gate.AdmitAsync(phone.PublicKey)));
    await coordinator.StopAsync();
  }

  [Fact]
  public async Task OneRemoveMeansOneThingReachsRemoveAlsoStopsTrustTrustsRemoveTakesReachOnlyWhileOn()
  {
    using var phone = NoiseIdentity.Generate();
    var service = new FakeService(new("acct-A", "1", ReachPolicy.AccountOnly, [new(PhoneId, "Asad's iPhone", "ios", phone.PublicKey)]));
    var coordinator = Coordinator(Folder(), service, null);
    var stopped = new List<string>();
    coordinator.SetTrustLink(id => { stopped.Add(id); return Task.CompletedTask; });
    // Off: the Cloud page's Remove does not touch reach.
    Assert.False(await coordinator.RemoveIfOnAsync(OtherId));
    Assert.Empty(service.Removed);
    await coordinator.SetEnabledAsync(true);
    await coordinator.RemoveAsync(PhoneId);
    Assert.Equal([PhoneId], stopped);
    Assert.Equal([PhoneId], service.Removed);
    Assert.Equal(ReachRefusal.Removed, Why(await coordinator.Gate.AdmitAsync(phone.PublicKey)));
    Assert.True(await coordinator.RemoveIfOnAsync(OtherId));
    Assert.Equal([PhoneId, OtherId], service.Removed);
    Assert.Equal([PhoneId], stopped);
    Assert.DoesNotContain("key", ReachPage.RemoveMeans.ToLowerInvariant());
    Assert.DoesNotContain("code", ReachPage.RemoveMeans.ToLowerInvariant());
    await coordinator.StopAsync();
  }

  [Fact]
  public async Task ReachOnNoPairingCodeCanBeMadeOrRedeemedOffAsBefore()
  {
    var rig = new HostRig();
    var service = new FakeService(new("acct-A", "1", ReachPolicy.AccountOnly, []));
    var coordinator = Coordinator(Folder(), service, rig);
    await coordinator.SyncAsync();
    var before = rig.Trust.Pairing.Create();
    Assert.True(new ReachPage(await coordinator.StatusAsync()).OffersPairing);
    await coordinator.SetEnabledAsync(true);
    Assert.True(rig.Trust.PairingLockedByReach);
    Assert.False(rig.Trust.Pairing.IsOpen); // a code shown before is withdrawn
    using var phone = NoiseIdentity.Generate();
    Assert.Throws<ProtocolException>(() => rig.Trust.Redeem(before.Code, "Phone", "ios", phone.PublicKey));
    var page = new ReachPage(await coordinator.StatusAsync());
    Assert.True(page.Mode == ReachPage.PageMode.On && !page.OffersPairing && !page.AsksFolders);
    await coordinator.SetEnabledAsync(false);
    Assert.False(rig.Trust.PairingLockedByReach);
    var code = rig.Trust.Pairing.Create();
    Assert.NotNull(rig.Trust.Redeem(code.Code, "Phone", "ios", phone.PublicKey));
    await coordinator.StopAsync();
  }

  [Fact]
  public async Task PresenceIsPublishedWhileOnAndWithdrawnWhenOffTheLinkHoldsTheTokenOnlyWhileOn()
  {
    var rig = new HostRig();
    var service = new FakeService(new("acct-A", "1", ReachPolicy.AccountOnly, []));
    var coordinator = Coordinator(Folder(), service, rig);
    Assert.Equal(ReachPresenceStatus.Off, await coordinator.SyncAsync());
    Assert.Null(rig.Link.Token); Assert.Empty(service.Published);
    await coordinator.SetEnabledAsync(true);
    Assert.Single(service.Published); Assert.NotNull(rig.Link.Token);
    await coordinator.SetEnabledAsync(false);
    Assert.Null(rig.Link.Token); Assert.Equal([MacId], service.Withdrawn);
    await coordinator.StopAsync();
  }

  [Fact]
  public void ThePageHiddenWithoutReachOffByDefaultOnWithNamesAndDatesOnlyTheToolReadsNoIdsOrKeys()
  {
    const double now = 1_800_000_000_000;
    Assert.Equal(ReachPage.PageMode.Hidden, new ReachPage(new ReachStatus(false, null, false, ReachPresenceStatus.SignedOut, false, [], []), now).Mode);
    var noPlan = new ReachPage(new ReachStatus(true, false, true, ReachPresenceStatus.NotEntitled, false, [], []), now);
    Assert.Equal(ReachPage.PageMode.Hidden, noPlan.Mode);
    Assert.True(noPlan.OffersPairing); // without the plan, pairing stays
    var device = new ReachStatus.Device(PhoneId, "Asad's iPhone", "ios", false, false, now - 86_400_000 * 3, now - 3_600_000);
    var gone = new ReachStatus.Device(OtherId, "Old tablet", "android", false, true, null, null);
    var off = new ReachStatus(true, true, false, ReachPresenceStatus.Off, false, [device], []);
    var offPage = new ReachPage(off, now);
    Assert.True(offPage.Mode == ReachPage.PageMode.Off && ReachPage.SwitchTitle == "Let my signed-in devices open this PC" && offPage.OffersPairing);
    var on = new ReachStatus(true, true, true, ReachPresenceStatus.Published, true, [device, gone],
      [new(PhoneId, "Asad's iPhone", "ios", now - 3_600_000, null)]);
    var page = new ReachPage(on, now);
    Assert.Equal(ReachPage.PageMode.On, page.Mode);
    var row = Assert.Single(page.Rows); // a removed device is not listed
    Assert.True(row.Title == "Asad's iPhone" && row.CanRemove);
    Assert.StartsWith("Added ", row.Detail); Assert.Contains("Last seen ", row.Detail);
    var shown = string.Join(" ", new[] { page.Explanation, row.Title, row.Detail }.Concat(page.Recent)).ToLowerInvariant();
    foreach (var secret in new[] { PhoneId, OtherId, "fingerprint", "key" }) Assert.DoesNotContain(secret.ToLowerInvariant(), shown);
    var tool = on.WireValue().GetRawText();
    Assert.DoesNotContain(PhoneId, tool); Assert.DoesNotContain("reachKey", tool); Assert.DoesNotContain("token\"", tool);
    Assert.Equal("join by signing in", on.WireValue().GetProperty("newDevices").GetString());
    Assert.Equal("not let in", off.WireValue().GetProperty("newDevices").GetString());
    Assert.Equal(["cloud.reach.status"], ReachAccountTools.Specs.Select(s => s.Id)); // one read tool; nothing switches reach on
  }
}
