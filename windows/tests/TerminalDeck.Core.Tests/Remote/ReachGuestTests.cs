using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Cloud;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

// This PC as a reach guest, ported from the Mac's ReachGuestTests.swift (the parts that are the guest's core; the chat
// rows and the live join belong to the live chat page, lane U).
public sealed class ReachGuestTests : IDisposable
{
  private const string MacId = ReachAccountTests.MacId;
  private const string OtherMac = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff";
  private readonly List<string> folders = [];
  public void Dispose() { foreach (var f in folders) try { Directory.Delete(f, true); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
  private string Folder() { var f = Path.Combine(Path.GetTempPath(), "td-reach-guest-" + Guid.NewGuid().ToString("N")); folders.Add(f); return f; }

  private sealed class Clock { public double Ms = 1_800_000_000_000; public double Now() => Ms; }
  private sealed class FakeGuestService : IReachGuestService
  {
    public string? DeviceId { get; set; } = MacId;
    public IReadOnlyList<ReachMachine> Machines { get; set; } = [];
    public List<(string DeviceId, string Key)> Registered { get; } = [];
    public string? RefuseWith { get; set; }
    public string Scope { get; set; } = "reach";
    public int Tokens;
    public Func<double> Now = () => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    public string? MachineDeviceId() => DeviceId;
    public Task RegisterReachKeyAsync(string deviceId, string publicKey, CancellationToken ct = default)
    {
      if (RefuseWith is { } code) throw new ReachServiceException(code, 409);
      Registered.Add((deviceId, publicKey)); return Task.CompletedTask;
    }
    public Task<IReadOnlyList<ReachMachine>> ReachMachinesAsync(CancellationToken ct = default) => Task.FromResult(Machines);
    public Task<ReachRelayToken> RelayTokenAsync(CancellationToken ct = default) { Tokens++; return Task.FromResult(new ReachRelayToken("t.o." + Tokens, Now() + 900_000, Scope)); }
  }

  // A machine row as the service writes it, signed by the machine's own P-256 key over its presence.
  private static string Row(string id, ECDsa sign, NoiseIdentity host, string name = "Mac mini", string platform = "macos", bool online = true, bool self = false, bool tamper = false)
  {
    var q = sign.ExportParameters(false).Q;
    var record = new ReachPresenceRecord(id, "ABCDEFGHJKLMNPQRSTUVWXYZ23", ReachWire.Base64Url(host.PublicKey), name, platform, ReachPolicy.AccountOnly);
    var sig = ReachWire.Base64Url(sign.SignData(Encoding.UTF8.GetBytes(ReachWire.PresenceMessage(record, 1_800_000_000_000)), HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation));
    return JsonSerializer.Serialize(new
    {
      deviceId = id, hostId = record.HostId, hostKey = record.HostKey, name = tamper ? name + " (changed)" : name, displayName = (string?)null, platform, policy = "A",
      signedAt = 1_800_000_000_000L, sig, online, self, signPublicJwk = new { kty = "EC", crv = "P-256", x = ReachWire.Base64Url(q.X), y = ReachWire.Base64Url(q.Y) }
    });
  }
  private static IReadOnlyList<ReachMachine> Parse(params string[] rows) => ReachMachine.List(JsonDocument.Parse("{\"machines\":[" + string.Join(",", rows) + "]}").RootElement);

  [Fact]
  public void TheAccountsMachinesAreReadOnlyARecordSignedByTheMachinesOwnKeyIsEverDialled()
  {
    using var sign = ECDsa.Create(ECCurve.NamedCurves.nistP256); using var host = NoiseIdentity.Generate();
    var machines = Parse(Row(OtherMac, sign, host, "Studio.local"), Row(OtherMac, sign, host, tamper: true), "{\"deviceId\":\"junk\"}");
    Assert.Equal(2, machines.Count);
    Assert.True(machines[0].PresenceValid);
    Assert.Equal("Studio", machines[0].ShownName);
    Assert.Equal(host.PublicKey, machines[0].HostKey);
    Assert.False(machines[1].PresenceValid); // the relay is never trusted: a changed record does not verify
  }

  [Fact]
  public async Task DialledOnNotThisPcAComputerAndSigned()
  {
    using var sign = ECDsa.Create(ECCurve.NamedCurves.nistP256); using var host = NoiseIdentity.Generate();
    var service = new FakeGuestService
    {
      Machines = Parse(Row(OtherMac, sign, host), Row(MacId, sign, host, self: true), Row(OtherMac, sign, host, "Off Mac", online: false),
        Row(OtherMac, sign, host, "Phone", platform: "ios"), Row(OtherMac, sign, host, tamper: true), Row(OtherMac, sign, host, "Office PC", platform: "windows"))
    };
    var guest = new ReachGuest(service, new ReachGuestKeyFile(Folder()), RelayEndpoint.Default);
    Assert.Equal(["Mac mini", "Office PC"], (await guest.ReachableAsync()).Select(m => m.Name));
  }

  [Fact]
  public async Task ItsReachKeyIsRegisteredOncePerDeviceIdKeptAcrossRestartsAndANewDeviceIdGetsANewKey()
  {
    var dir = Folder();
    var service = new FakeGuestService();
    var guest = new ReachGuest(service, new ReachGuestKeyFile(dir), RelayEndpoint.Default);
    var (id, first) = await guest.PrepareAsync();
    Assert.Equal(MacId, id);
    Assert.Equal([(MacId, ReachWire.Base64Url(first.PublicKey))], service.Registered);
    _ = await guest.PrepareAsync();
    Assert.Single(service.Registered);
    // A restart of the app: the same key, not registered again.
    var restarted = new ReachGuest(service, new ReachGuestKeyFile(dir), RelayEndpoint.Default);
    var (_, again) = await restarted.PrepareAsync();
    Assert.Equal(first.PublicKey, again.PublicKey);
    Assert.Single(service.Registered);
    // Signed in again: a new device id gets a new key.
    service.DeviceId = OtherMac;
    var (newId, fresh) = await restarted.PrepareAsync();
    Assert.Equal(OtherMac, newId);
    Assert.NotEqual(first.PublicKey, fresh.PublicKey);
    Assert.Equal(2, service.Registered.Count);
    // The file never holds the key in a form the page or a tool could show by name: it is this copy's own file.
    Assert.True(File.Exists(Path.Combine(dir, "reach-guest-key.json")));
  }

  [Fact]
  public async Task AnUnreadableKeyFileAndAServiceThatKeepsTheOldKeyRefusedAndSaidInOnePlainLine()
  {
    var dir = Folder();
    Directory.CreateDirectory(dir);
    File.WriteAllText(Path.Combine(dir, "reach-guest-key.json"), "{damaged");
    var service = new FakeGuestService { RefuseWith = "reach_key_set" };
    var guest = new ReachGuest(service, new ReachGuestKeyFile(dir), RelayEndpoint.Default);
    var refused = await Assert.ThrowsAsync<ReachRefusedException>(() => guest.PrepareAsync());
    Assert.Equal(ReachRefusal.KeyChanged, refused.Why);
    Assert.True(guest.KeyRefused);
    Assert.DoesNotContain("key", ReachGuest.KeyRefusedLine.ToLowerInvariant());
    // Signed in again (a new device id): taken.
    service.RefuseWith = null; service.DeviceId = OtherMac;
    _ = await guest.PrepareAsync();
    Assert.False(guest.KeyRefused);
  }

  [Fact]
  public async Task TheRelayTokenIsReusedUntilTwoMinutesAreLeftAReachHostTokenNeverJoins()
  {
    var clock = new Clock();
    var service = new FakeGuestService { Now = clock.Now };
    var guest = new ReachGuest(service, new ReachGuestKeyFile(Folder()), RelayEndpoint.Default, clock.Now);
    var first = await guest.RelayTokenAsync();
    Assert.Equal(first, await guest.RelayTokenAsync());
    clock.Ms += 900_000 - ReachGuest.RenewBeforeMs + 1;
    Assert.NotEqual(first, await guest.RelayTokenAsync());
    Assert.Equal(2, service.Tokens);
    var hostOnly = new ReachGuest(new FakeGuestService { Scope = "reach-host" }, new ReachGuestKeyFile(Folder()), RelayEndpoint.Default);
    Assert.Equal(ReachRefusal.NotApproved, (await Assert.ThrowsAsync<ReachRefusedException>(() => hostOnly.RelayTokenAsync())).Why);
  }

  [Fact]
  public async Task TheServiceCallsAreSignedDeviceRequestsTheKeysOwnSignatureTheMachinesRoute()
  {
    using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
    var http = new ReachAccountTests.FakeHttp(r => new(200, Encoding.UTF8.GetBytes(r.Url.AbsolutePath == "/v1/reach/machines" ? "{\"machines\":[]}" : "{}")));
    var service = new ReachAccountHttpService(new Uri("https://td-cloud-test.example.test/v1"), http, new(() => "acct-A", () => MacId,
      _ => Task.FromResult("access-1"), bytes => key.SignData(bytes, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation)), () => 1_800_000_000_000);
    await service.RegisterReachKeyAsync(MacId, "PUBKEY");
    Assert.Empty(await service.ReachMachinesAsync());
    Assert.Equal(["/v1/devices/reach-key", "/v1/reach/machines"], http.Sent.Select(s => s.Url.AbsolutePath));
    var body = JsonDocument.Parse(http.Sent[0].Body).RootElement;
    Assert.Equal("PUBKEY", body.GetProperty("reachPublicKey").GetString());
    var sig = ReachWire.UnBase64Url(body.GetProperty("sig").GetString(), 64)!;
    Assert.True(key.VerifyData(Encoding.UTF8.GetBytes(ReachWire.ReachKeyMessage(MacId, "PUBKEY")), sig, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation));
    await Assert.ThrowsAsync<ReachRefusedException>(() => service.RegisterReachKeyAsync(OtherMac, "PUBKEY")); // only for this PC's own id
  }
}
