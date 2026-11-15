using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

/// The service's side of one row per machine, around the shared fake (which stays as it is): `Knows` takes the machine
/// fields and echoes the name, `Refuses` refuses any of them, `NoHost` refuses only the host name, `Ignores` takes the
/// body and says nothing about them.
internal sealed class CloudMachineService : ICloudHttp
{
  public enum Mode { Ignores, Knows, Refuses, NoHost }
  public readonly CloudServiceFake Inner = new();
  public Mode Service = Mode.Ignores;
  public readonly List<JsonObject> Registrations = [], Describes = [];
  public readonly Dictionary<string, string> Names = [];
  private static CloudHttpResponse Refuse() => new(400, JsonSerializer.SerializeToUtf8Bytes(new { error = new { code = "invalid_request", message = "x", retryable = false, requestId = "" } }));
  private bool Refused(JsonObject body) => Service == Mode.Refuses && (body.ContainsKey("machineId") || body.ContainsKey("hostName")) || Service == Mode.NoHost && body.ContainsKey("hostName");

  public async Task<CloudHttpResponse> SendAsync(CloudHttpRequest request, CancellationToken ct)
  {
    var path = request.Url.AbsolutePath;
    if (path == "/v1/devices" && request.Method == HttpMethod.Post)
    {
      var body = JsonNode.Parse(request.Body)!.AsObject();
      Registrations.Add(body);
      if (Refused(body)) return Refuse();
      var answer = await Inner.SendAsync(request, ct);
      if (Service == Mode.Ignores || body["displayName"] is null) return answer;
      var receipt = JsonNode.Parse(answer.Body)!.AsObject();
      Names[receipt["deviceId"]!.GetValue<string>()] = body["displayName"]!.GetValue<string>();
      receipt["displayName"] = body["displayName"]!.GetValue<string>();
      return answer with { Body = Encoding.UTF8.GetBytes(receipt.ToJsonString()) };
    }
    if (path == "/v1/devices/rename")
    {
      var body = JsonNode.Parse(request.Body)!.AsObject();
      Describes.Add(body);
      if (Refused(body) || Service == Mode.Ignores) return Refuse();
      Names[body["deviceId"]!.GetValue<string>()] = body["displayName"]!.GetValue<string>();
      return new(200, JsonSerializer.SerializeToUtf8Bytes(new { deviceId = body["deviceId"]!.GetValue<string>(), displayName = body["displayName"]!.GetValue<string>() }));
    }
    var inner = await Inner.SendAsync(request, ct);
    if (path == "/v1/devices" && request.Method == HttpMethod.Get && inner.Status == 200)
    {
      var list = JsonNode.Parse(inner.Body)!.AsObject();
      foreach (var device in list["devices"]!.AsArray().OfType<JsonObject>())
        if (Names.TryGetValue((device["deviceId"] ?? device["DeviceId"])!.GetValue<string>(), out var name)) device["displayName"] = name;
      return inner with { Body = Encoding.UTF8.GetBytes(list.ToJsonString()) };
    }
    return inner;
  }
}

/// One row per machine (the Mac's CloudMachineIdentityTests, case for case): each PC tells the service a stable machine id
/// (a hash of MachineGuid + account) and its friendly name, at registration and once at launch, and never anything that
/// reveals MachineGuid.
public sealed class CloudMachineIdentityTests : IDisposable
{
  private const string SubjectA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", SubjectB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
  private const string Hardware = "0F3A9C2E-1B44-4C1D-9E77-ABCDEF012345";
  private readonly string folder = Path.Combine(Path.GetTempPath(), "td-cloud-machine-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { if (Directory.Exists(folder)) Directory.Delete(folder, true); }

  private sealed class Box(string name = "Studio PC")
  {
    public string Name = name; public string? Mark; public int Remembers;
    public CloudMachineFacts Facts() => new(() => Hardware, () => Name, () => Mark, m => { Mark = m; Remembers++; });
  }
  private ProtectedCloudSecretStore Store => new(Path.Combine(folder, "cloud", "account.protected"), new XorProtector());
  private CloudAccountClient Make(CloudMachineService http, Box? box) =>
    new(CloudConfiguration.Today("OFFICE-PC", "0.22.0.0"), Store, http, new CountingRandom(), new FakeBrowser()) { Machine = box?.Facts() };
  private async Task<CloudAccountClient> Relaunch(CloudMachineService http, Box box) { var account = Make(http, box); await account.ResumeAsync(); return account; }

  [Fact] public void IdIsStablePerMachineAndAccountAndRevealsNoHardwareId()
  {
    var a = CloudMachineFacts.MachineId(Hardware, SubjectA)!;
    Assert.Equal(32, a.Length); Assert.True(a.All(Uri.IsHexDigit));
    Assert.Equal(a, CloudMachineFacts.MachineId(Hardware.ToLowerInvariant(), SubjectA));
    Assert.NotEqual(a, CloudMachineFacts.MachineId(Hardware, SubjectB));
    Assert.NotEqual(a, CloudMachineFacts.MachineId("11111111-2222-4333-8444-555555555555", SubjectA));
    Assert.NotEqual(a, CloudMachineFacts.MachineId(Hardware, SubjectA, "folder 0123456789abcdef"));
    var plain = Hardware.ToLowerInvariant().Replace("-", "");
    for (var piece = 0; piece < plain.Length - 8; piece += 4) Assert.DoesNotContain(plain.Substring(piece, 8), a);
    var pair = new Box().Facts().PairFor(SubjectA)!;
    var mark = CloudMachineFacts.Mark("d", pair);
    Assert.DoesNotContain(Hardware.Replace("-", ""), mark.ToUpperInvariant()); Assert.DoesNotContain(plain, mark);
  }

  [Fact] public void DataFolderSeparatesCopiesAndTheInstalledAppKeepsItsId()
  {
    var standard = Path.Combine(Path.GetTempPath(), "TerminalDeckStable");
    var installed = CloudMachineFacts.CopyName(standard, standard);
    Assert.Equal("", installed);
    Assert.Equal(CloudMachineFacts.MachineId(Hardware, SubjectA), CloudMachineFacts.MachineId(Hardware, SubjectA, installed));
    var one = CloudMachineFacts.CopyName(Path.Combine(Path.GetTempPath(), "td-proof-1"), standard);
    var two = CloudMachineFacts.CopyName(Path.Combine(Path.GetTempPath(), "td-proof-2"), standard);
    Assert.NotEqual("", one); Assert.NotEqual(one, two); Assert.DoesNotContain("td-proof", one);
    Assert.Equal(one, CloudMachineFacts.CopyName(Path.Combine(Path.GetTempPath(), "td-proof-1"), standard));
    var idOne = CloudMachineFacts.MachineId(Hardware, SubjectA, one); var idTwo = CloudMachineFacts.MachineId(Hardware, SubjectA, two);
    Assert.NotEqual(idOne, idTwo); Assert.NotEqual(CloudMachineFacts.MachineId(Hardware, SubjectA), idOne);
  }

  [Fact] public void FriendlyNameIsTrimmedCutAndFallsBack()
  {
    Assert.Equal("Studio PC", CloudMachineFacts.DisplayName("  Studio PC \n"));
    Assert.Equal(64, CloudMachineFacts.DisplayName(new string('é', 90)).Length);
    Assert.Equal("PC", CloudMachineFacts.DisplayName("   "));
  }

  [Fact] public async Task RegistrationCarriesBothFieldsAndIdSurvivesSignOutAndIn()
  {
    var http = new CloudMachineService { Service = CloudMachineService.Mode.Knows }; var box = new Box();
    using var account = Make(http, box);
    await CloudJoinTests.SignInAsync(account);
    var first = http.Registrations[^1];
    var expected = CloudMachineFacts.MachineId(Hardware, CloudServiceFake.UserId);
    Assert.Equal(expected, first["machineId"]!.GetValue<string>()); Assert.Equal("Studio PC", first["displayName"]!.GetValue<string>());
    Assert.Equal("OFFICE-PC", first["hostName"]!.GetValue<string>());
    Assert.Equal(1, box.Remembers);
    Assert.DoesNotContain(Hardware, first.ToJsonString().ToUpperInvariant());
    // Signed out and in again: a new device id, the same machine id.
    await account.SignOutAsync();
    await CloudJoinTests.SignInAsync(account);
    var second = http.Registrations[^1];
    Assert.NotEqual(first["deviceId"]!.GetValue<string>(), second["deviceId"]!.GetValue<string>());
    Assert.Equal(first["machineId"]!.GetValue<string>(), second["machineId"]!.GetValue<string>());
    Assert.Empty(http.Describes);
  }

  [Fact] public async Task AServiceThatLostTheNameGetsItAgainAtLaunch()
  {
    var http = new CloudMachineService { Service = CloudMachineService.Mode.Knows }; var box = new Box();
    using (var account = Make(http, box)) await CloudJoinTests.SignInAsync(account);
    Assert.Equal(1, box.Remembers);
    http.Names.Clear();
    using var again = await Relaunch(http, box);
    Assert.Single(http.Describes); Assert.Equal(2, box.Remembers);
  }

  [Fact] public async Task AnAlreadyRegisteredPcSendsOnceAtLaunchAndNotAgain()
  {
    var http = new CloudMachineService(); var box = new Box();
    using (var older = Make(http, null)) await CloudJoinTests.SignInAsync(older); // an older app: registered without the fields
    Assert.Null(http.Registrations[^1]["machineId"]);
    http.Service = CloudMachineService.Mode.Knows;
    using (var launch = await Relaunch(http, box))
    {
      var call = Assert.Single(http.Describes);
      Assert.Equal(CloudMachineFacts.MachineId(Hardware, CloudServiceFake.UserId), call["machineId"]!.GetValue<string>());
      Assert.Equal("Studio PC", call["displayName"]!.GetValue<string>()); Assert.Equal("OFFICE-PC", call["label"]!.GetValue<string>());
      Assert.Equal("OFFICE-PC", call["hostName"]!.GetValue<string>()); Assert.Equal(1, box.Remembers);
      await launch.RefreshAsync(); // later status reads in the same run send nothing
    }
    using (var next = await Relaunch(http, box)) Assert.Single(http.Describes); // the next launch: nothing changed, nothing sent
    box.Name = "Studio"; // the name changed: sent once more
    using (var renamed = await Relaunch(http, box)) Assert.Equal(2, http.Describes.Count);
    Assert.Equal("Studio", http.Describes[^1]["displayName"]!.GetValue<string>());
  }

  [Fact] public async Task ARefusingOrIgnoringServiceChangesNothingElse()
  {
    // Refuses unknown fields: sign-in still finishes with a plain registration.
    var http = new CloudMachineService { Service = CloudMachineService.Mode.Refuses }; var box = new Box();
    using (var account = Make(http, box))
    {
      await CloudJoinTests.SignInAsync(account);
      Assert.Equal(CloudPhase.SignedIn, account.Snapshot.Phase);
    }
    Assert.Equal(3, http.Registrations.Count);
    Assert.NotNull(http.Registrations[0]["hostName"]); Assert.NotNull(http.Registrations[1]["machineId"]); Assert.Null(http.Registrations[1]["hostName"]);
    Assert.Null(http.Registrations[2]["machineId"]); Assert.Null(http.Registrations[2]["displayName"]);
    Assert.Equal(0, box.Remembers);
    // Launch: the refused self-description is one quiet failure (with the host name, then without); tried again next launch.
    using (var launch = await Relaunch(http, box)) Assert.Equal(CloudPhase.SignedIn, launch.Snapshot.Phase);
    Assert.Equal(2, http.Describes.Count); Assert.Equal(0, box.Remembers);
    using (await Relaunch(http, box)) { }
    Assert.Equal(4, http.Describes.Count);
    // Ignores the fields: sign-in fine, nothing remembered.
    Directory.Delete(folder, true);
    var ignoring = new CloudMachineService(); var other = new Box();
    using var quiet = Make(ignoring, other);
    await CloudJoinTests.SignInAsync(quiet);
    Assert.Equal(CloudPhase.SignedIn, quiet.Snapshot.Phase); Assert.Equal(0, other.Remembers);
    Assert.Single(ignoring.Registrations);
  }

  [Fact] public async Task TheHostNameIsSentOnceMoreAndARefusalOfItCostsNothing()
  {
    var http = new CloudMachineService(); var box = new Box();
    using (var older = Make(http, null)) await CloudJoinTests.SignInAsync(older);
    http.Service = CloudMachineService.Mode.Knows;
    var deviceId = http.Registrations[^1]["deviceId"]!.GetValue<string>();
    var old = box.Facts().PairFor(CloudServiceFake.UserId)!; // what an earlier build remembered: no host name
    box.Facts().Remember(CloudMachineFacts.Mark(deviceId, old));
    using (await Relaunch(http, box)) { }
    Assert.Equal("OFFICE-PC", Assert.Single(http.Describes)["hostName"]!.GetValue<string>()); Assert.Equal(2, box.Remembers);
    using (await Relaunch(http, box)) { }
    Assert.Single(http.Describes);
    // Refuses the host name: registration falls back to id + name, launch sends id + name.
    Directory.Delete(folder, true);
    var g = new CloudMachineService { Service = CloudMachineService.Mode.NoHost }; var other = new Box();
    using (var account = Make(g, other)) await CloudJoinTests.SignInAsync(account);
    Assert.Equal(2, g.Registrations.Count); Assert.NotNull(g.Registrations[1]["machineId"]); Assert.Null(g.Registrations[1]["hostName"]); Assert.Equal(1, other.Remembers);
    using (await Relaunch(g, other)) { }
    Assert.Equal(2, g.Describes.Count);
    Assert.Equal("OFFICE-PC", g.Describes[0]["hostName"]!.GetValue<string>()); Assert.Null(g.Describes[1]["hostName"]);
    Assert.Equal(g.Registrations[1]["machineId"]!.GetValue<string>(), g.Describes[1]["machineId"]!.GetValue<string>());
  }
}
