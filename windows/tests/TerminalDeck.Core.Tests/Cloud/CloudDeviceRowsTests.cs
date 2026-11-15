using System.Text.RegularExpressions;
using TerminalDeck.Core.Cloud;

namespace TerminalDeck.Core.Tests.Cloud;

/// Owner, 13 Nov: a device row is ONLY its name, the date added and last seen ("This PC" marked). No device codes,
/// fingerprints, ids or hashes on any page, notice or tool text; removed devices leave the list; Cloud is second.
public sealed partial class CloudDeviceRowsTests : IDisposable
{
  private readonly string folder = Path.Combine(Path.GetTempPath(), "td-cloud-rows-" + Guid.NewGuid().ToString("N"));
  public void Dispose() { if (Directory.Exists(folder)) Directory.Delete(folder, true); }

  [GeneratedRegex("[0-9A-F]{4} [0-9A-F]{4}|[0-9a-f]{8}-[0-9a-f]{4}|[0-9a-fA-F]{16,}|[A-Za-z0-9_-]{40,}")]
  private static partial Regex CodeLike();

  [Theory, InlineData("account"), InlineData("ask")]
  public async Task RowsCarryOnlyNameAndDatesEverywhere(string mode)
  {
    var http = new CloudServiceFake();
    http.Others.Add((CloudDeviceKeys.Fresh().Registration("Old tablet", "0.21.0", "macos"), "revoked", 1_760_000_000_000L));
    http.Others.Add((CloudDeviceKeys.Fresh().Registration("Home laptop", "0.22.0", "windows"), "active", 1_762_500_000_000L));
    var list = new Slot(); var modeSlot = new Slot { Bytes = System.Text.Encoding.UTF8.GetBytes(mode) };
    using var account = new CloudAccountClient(CloudConfiguration.Today("OFFICE-PC", "0.22.0.0"),
      new ProtectedCloudSecretStore(Path.Combine(folder, "account.protected"), new XorProtector()), http, new CountingRandom(), new FakeBrowser(),
      trust: new CloudTrustPorts((_, _) => list, modeSlot, () => false));
    await CloudJoinTests.SignInAsync(account);
    var s = account.Snapshot;
    // Removed devices leave the list; this PC first, then by name.
    Assert.Equal(["OFFICE-PC", "Asad's Mac mini", "Home laptop"], s.DeviceRows.Select(d => d.Name));
    var page = CloudPageText.For(s, d => d.UtcDateTime.ToString("d MMM yyyy", System.Globalization.CultureInfo.InvariantCulture));
    Assert.Equal(["This PC · Added 13 Nov 2025 · Last seen 13 Nov 2025", "Added 20 Oct 2025 · Last seen 1 Nov 2025", "Added 7 Nov 2025 · Last seen 1 Nov 2025"],
      page.Devices.Select(d => d.Details));
    var drawn = page.Devices.SelectMany(d => new[] { d.Name, d.Details }).Concat(page.Notices!.Select(n => n.Text + " " + n.Button))
      .Append(page.Line).Append(page.Problem ?? "").Append(page.ThisDevice ?? "").ToArray();
    var tool = CloudTools.Status(s).GetRawText();
    foreach (var text in drawn.Append(tool))
    {
      Assert.DoesNotMatch(CodeLike(), text);
      foreach (var row in s.DeviceRows) Assert.DoesNotContain(row.DeviceId, text);
    }
    var device = CloudTools.Status(s).GetProperty("devices")[1];
    Assert.Equal(["name", "thisDevice", "added", "lastSeen"], device.EnumerateObject().Select(p => p.Name));
    Assert.DoesNotContain("platform", tool); Assert.DoesNotContain("code", tool);
  }

  [Fact] public void CloudIsTheSecondEntryInSettings() =>
    Assert.Equal(["general", "cloud"], TerminalDeck.App.Views.Settings.SettingsNavigation.Categories.Skip(2).Take(2).Select(c => c.Id));

  private sealed class Slot : ICloudTrustSlot
  {
    public byte[]? Bytes;
    public byte[]? Read() => Bytes?.ToArray();
    public void Write(byte[] bytes) => Bytes = bytes.ToArray();
  }
}
