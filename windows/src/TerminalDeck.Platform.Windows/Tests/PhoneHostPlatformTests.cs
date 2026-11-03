using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using TerminalDeck.Core.Remote;
using TerminalDeck.Platform.Windows.Phone;

namespace TerminalDeck.Platform.Windows.Tests;

// windows-phone-features (1 Nov 2026): the Activity page's readings and This PC's screen, read on Windows itself.
public sealed class PhoneHostPlatformTests
{
  private static double Num(System.Text.Json.Nodes.JsonNode? node) => double.Parse(node!.ToJsonString(), System.Globalization.CultureInfo.InvariantCulture);

  [Fact]
  public void ActivityReadsThisPcInTheMacsShape()
  {
    using var self = Process.GetCurrentProcess();
    var roots = new[] { new ActivitySessionRoot(self.Id, self.StartTime.ToUniversalTime().Ticks, "Phone test session") };
    var reader = new WindowsSystemActivity(() => roots, Path.GetTempPath());
    _ = reader.Sample(true);
    Thread.Sleep(400);
    var sample = reader.Sample(true);
    var cpu = sample["cpu"]!.AsObject();
    var count = (int)Num(cpu["count"]);
    Assert.True(count > 0);
    Assert.Equal(count, cpu["cores"]!.AsArray().Count);
    Assert.InRange(Num(cpu["total"]), 0, 100);
    var memory = sample["memory"]!.AsObject();
    Assert.True(Num(memory["total"]) > 0);
    Assert.InRange(Num(memory["used"]), 1, Num(memory["total"]));
    Assert.Contains(memory["pressure"]!.GetValue<string>(), new[] { "normal", "warn", "critical" });
    Assert.True(Num(sample["disk"]!["total"]) > 0);
    Assert.True(sample.ContainsKey("net") && sample.ContainsKey("busy"));
    var top = sample["topMemory"]!.AsArray();
    Assert.InRange(top.Count, 1, 6);
    Assert.All(top, row => Assert.Contains(row!["kind"]!.GetValue<string>(), new[] { "session", "app", "process" }));
    Assert.False(reader.Sample(false).ContainsKey("topCPU"));
  }

  [Fact]
  public void InputIsTheSizeWindowsExpects()
  {
    var input = typeof(WindowsScreenHost).GetNestedType("Input", BindingFlags.NonPublic)!;
    Assert.Equal(IntPtr.Size == 8 ? 40 : 28, Marshal.SizeOf(input));
  }

  [Fact]
  public void ThisPcsScreenIsReadOrSaysPlainlyWhyNot()
  {
    var host = new WindowsScreenHost();
    var still = host.EncodePng(new ScreenStill(new byte[2 * 2 * 4], 2, 2));
    Assert.Equal(0x89, still[0]); Assert.Equal((byte)'P', still[1]);
    var jpeg = host.EncodeJpeg(new ScreenStill(Enumerable.Repeat((byte)200, 64 * 32 * 4).ToArray(), 64, 32), 32, 60, out var width, out var height);
    Assert.Equal(0xFF, jpeg[0]); Assert.Equal(0xD8, jpeg[1]); Assert.Equal((32, 16), (width, height));
    // A service session (SSH) has no desktop to read; the signed-in desktop does.
    using var self = Process.GetCurrentProcess();
    if (self.SessionId == 0) return;
    var displays = host.Displays();
    Assert.NotEmpty(displays);
    Assert.All(displays, d => Assert.Matches("^mac:[0-9]+$", d.Id));
    var picture = host.Capture(displays[0].Id, 1280, 60, false, null, out var problem);
    if (picture is null) { Assert.False(string.IsNullOrWhiteSpace(problem)); return; }
    Assert.Equal(0xFF, picture.Jpeg[0]); Assert.InRange(Math.Max(picture.Width, picture.Height), 2, 1280);
    var same = host.Capture(displays[0].Id, 1280, 60, false, picture.Hash, out _);
    Assert.NotNull(same);
    Assert.NotNull(host.Pointer(displays[0].Id, -1));
  }
}
