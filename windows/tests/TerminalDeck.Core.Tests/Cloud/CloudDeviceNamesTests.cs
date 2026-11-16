using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

/// A machine is called by the friendly name the service holds for it (the Mac's CloudDevice.shownName), on the device
/// rows (this PC's own row too) and on the sessions it runs; without one, its label; never an empty name.
public sealed class CloudDeviceNamesTests : IDisposable
{
  private readonly string folder = Path.Combine(Path.GetTempPath(), "td-cloud-names-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { if (Directory.Exists(folder)) Directory.Delete(folder, true); }

  private static CloudDevice Device(string label, string platform, string? displayName)
  {
    var key = new { kty = "EC", crv = "P-256", x = "x", y = "y" };
    var json = displayName is null
      ? JsonSerializer.Serialize(new { deviceId = "d1", label, platform, appVersion = "0.22.0", status = "active", secretsApproved = false, lastSeenAt = 1L, signPublicJwk = key, wrapPublicJwk = key })
      : JsonSerializer.Serialize(new { deviceId = "d1", label, platform, appVersion = "0.22.0", status = "active", secretsApproved = false, lastSeenAt = 1L, signPublicJwk = key, wrapPublicJwk = key, displayName });
    return CloudWire.Decode<CloudDevice>(Encoding.UTF8.GetBytes(json));
  }

  [Fact] public void ADeviceWithANameWithoutOneAndWithAnEmptyOne()
  {
    Assert.Equal("Mac mini", Device("imatch-mac-mini", "macos", " Mac mini ").DisplayName);
    Assert.Equal("imatch-mac-mini", Device("imatch-mac-mini", "macos", null).DisplayName);
    Assert.Equal("imatch-mac-mini", Device("imatch-mac-mini", "macos", "  ").DisplayName);
    Assert.Equal("Mac", Device("", "macos", "").DisplayName);
    Assert.Equal("PC", Device(" ", "windows", null).DisplayName);
    Assert.Equal("iPhone", Device("", "ios", null).DisplayName);
  }

  [Fact] public async Task DeviceRowsThisPcIncludedShowTheFriendlyName()
  {
    var http = new CloudMachineService { Service = CloudMachineService.Mode.Knows };
    using var account = new CloudAccountClient(CloudConfiguration.Today("OFFICE-PC", "0.22.0.0"),
      new ProtectedCloudSecretStore(Path.Combine(folder, "cloud", "account.protected"), new XorProtector()), http, new CountingRandom(), new FakeBrowser())
    { Machine = new CloudMachineFacts(() => "0F3A9C2E-1B44-4C1D-9E77-ABCDEF012345", () => "Studio PC", () => null, _ => { }) };
    await CloudJoinTests.SignInAsync(account);
    var rows = account.Snapshot.Devices!;
    Assert.Equal("Studio PC", Assert.Single(rows, r => r.ThisDevice).Name);
    Assert.Equal("Studio PC", account.Snapshot.ThisDeviceName);
    // The Mac in the shared fake has no friendly name: its label, on one line.
    Assert.Equal("Asad's Mac mini", Assert.Single(rows, r => !r.ThisDevice).Name);
  }

  [Fact] public void ASessionSaysTheMachineItRunsOn()
  {
    var machines = new Dictionary<string, CloudSessionsRead.Machine>
    {
      ["m1"] = new("m1", "Mac mini", true, true, "macos"), ["m2"] = new("m2", null, false, true, "macos"), ["m3"] = new("m3", " ", true, true, "windows")
    };
    Assert.Equal("Mac mini", machines["m1"].DisplayName); Assert.Equal("Mac", machines["m2"].DisplayName); Assert.Equal("PC", machines["m3"].DisplayName);
    Assert.Equal("Mac mini", CloudSessionsRead.RunsOn(new("r1", Machine: "m1", MachineName: "old name"), machines));
    Assert.Equal("Mac", CloudSessionsRead.RunsOn(new("r2", Machine: "m2"), machines));
    Assert.Equal("MacBook Air", CloudSessionsRead.RunsOn(new("r3", Machine: "m2", MachineName: "MacBook Air"), machines));
    Assert.Equal("another computer", CloudSessionsRead.RunsOn(new("r4", Machine: "gone", MachineName: "")));
    // The list as the service sends it: the machine's platform is read.
    var page = JsonSerializer.Deserialize<CloudSessionsRead.Page>("""{"machines":[{"ref":"m9","name":"","platform":"windows","on":true}],"sessions":[]}""",
      new JsonSerializerOptions(JsonSerializerDefaults.Web))!;
    Assert.Equal("PC", page.Machines![0].DisplayName);
  }
}
