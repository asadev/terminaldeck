using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class ScreenParityTests
{
  private static ScreenStill Pixels(int width = 100, int height = 80) => new(new byte[width * height * 4], width, height);
  private static JsonElement Message(object value) => JsonSerializer.SerializeToElement(value);

  [Fact]
  public void AndroidCommandsClampCoordinatesQuoteDeviceShellTextAndValidateSerials()
  {
    Assert.Equal(["input", "tap", "99", "0"], AndroidSdkBridge.InputCommand(new ScreenInput.Tap(2, -1, null), 100, 80));
    Assert.Equal(["input", "keyevent", "4"], AndroidSdkBridge.InputCommand(new ScreenInput.Key("back", []), 100, 80));
    var command = AndroidSdkBridge.InputCommand(new ScreenInput.TypeText("it's ; $(echo x)"), 100, 80);
    Assert.Equal("'it'\\''s%s;%s$(echo%sx)'", command[2]);
    Assert.Equal("phone-123", AndroidSdkBridge.Serial("android:phone-123"));
    Assert.Throws<PhoneRefusal>(() => AndroidSdkBridge.Serial("android:emulator-5554;touch"));
    Assert.Throws<PhoneRefusal>(() => AndroidSdkBridge.InputCommand(new ScreenInput.TypeText("مرحبا"), 100, 80));
  }

  [Fact]
  public void AbsoluteMouseSharesMacWireAndRejectsUnknownButtons()
  {
    var input = Assert.IsType<ScreenInput.Mouse>(PhoneScreens.Parse(Message(new { @do = "mouse", phase = "drag", button = "right", x = 1.5, y = -1, clicks = 9 })));
    Assert.Equal("drag", input.Phase); Assert.Equal("right", input.Button);
    Assert.Equal(1, input.X); Assert.Equal(0, input.Y); Assert.Equal(3, input.Clicks);
    Assert.Throws<PhoneRefusal>(() => PhoneScreens.Parse(Message(new { @do = "mouse", phase = "down", button = "extra", x = 0.5, y = 0.5 })));
  }

  [Fact]
  public void AndroidInspectionClipsToScreenAndOmitsPasswordAndOffscreenNodes()
  {
    const string xml = "<hierarchy><node text='Sign in' class='Button' resource-id='login' package='demo.app' bounds='[-10,60][110,100]' clickable='true'/><node text='Secret' password='true' bounds='[0,0][50,20]'/><node text='Outside' bounds='[120,0][150,20]'/></hierarchy>";
    var inspection = AndroidSdkBridge.ParseInspection(xml, 100, 80);
    var element = Assert.Single(inspection.Elements);
    Assert.Equal("Sign in", element.Name); Assert.Equal("demo.app", inspection.App);
    Assert.Equal(0, element.X); Assert.Equal(0.75, element.Y); Assert.Equal(1, element.Width); Assert.Equal(0.25, element.Height);
    Assert.Throws<System.Xml.XmlException>(() => AndroidSdkBridge.ParseInspection("<!DOCTYPE x [<!ENTITY y SYSTEM 'file:///not-read'>]><hierarchy>&y;</hierarchy>", 100, 80));
  }

  private sealed class Host : IScreenHost, IExtendedScreenHost
  {
    public readonly List<string> Steps = [];
    public IReadOnlyList<ScreenDisplay> Displays() => [new("mac:1", "Synthetic PC", 100, 80, true)];
    public ScreenDisplay? Device(string id) => id == "android:emulator-5554" ? new(id, "Synthetic emulator", 100, 80, false) : null;
    public ScreenPicture? Capture(string id, int maxSide, int quality, bool cursor, ulong? last, out string? problem) { problem = null; return new([], 100, 80, 1); }
    public ScreenStill? Still(string id, out string? problem) { problem = null; return Pixels(); }
    public byte[] EncodePng(ScreenStill still) => still.Bgra;
    public byte[] EncodeJpeg(ScreenStill still, int maxSide, int quality, out int width, out int height) { width = still.Width; height = still.Height; return [1]; }
    public string? Post(string id, ScreenInput input) => null;
    public ScreenPointer? Pointer(string id, int knownShape) => null;
    public bool? TextFocus() => null;
    public ScreenInspection Inspect(string id) => new([new("button", "Sign in", "login", 0.1, 0.2, 0.5, 0.1)], "Synthetic App", "Login");
    public ValueTask PowerAsync(string id, bool on, CancellationToken ct) { Steps.Add("power"); return ValueTask.CompletedTask; }
    public bool CanRecord => true;
    public ValueTask RecordStartAsync(string id, string lease, CancellationToken ct) { Steps.Add("start"); return ValueTask.CompletedTask; }
    public ValueTask<byte[]> RecordStopAsync(string id, string lease, CancellationToken ct) { Steps.Add("stop"); return ValueTask.FromResult<byte[]>([1]); }
    public ValueTask RecordCancelAsync(string id, string lease) { Steps.Add("cancel"); return ValueTask.CompletedTask; }
  }
  private static readonly ApprovedDevice Full = new("synthetic-phone", "Synthetic phone", "ios", PhoneAccess.Full);
  private static readonly ApprovedDevice Work = Full with { Access = PhoneAccess.Work };

  [Fact]
  public async Task RecordAndPowerRequireFullAndUnwatchDiscardsAnOwnedRecording()
  {
    var host = new Host();
    using var screens = new PhoneScreens(host, () => true, "Off", () => [], (_, _, _, _, _) => ValueTask.FromResult("sent")) { DeliverRecording = (_, _, _, _, _) => ValueTask.FromResult("sent"), Video = new FakeScreenVideo(), HasLink = _ => true };
    await Assert.ThrowsAsync<PhoneRefusal>(() => screens.HandleAsync("one", Work, "sims.power", Message(new { id = "avd:demo", on = true }), "p", default).AsTask());
    await Assert.ThrowsAsync<PhoneRefusal>(() => screens.HandleAsync("one", Work, "sims.record", Message(new { id = "android:emulator-5554", @do = "start" }), "r", default).AsTask());
    Assert.Empty(host.Steps);
    await screens.HandleAsync("one", Full, "sims.watch", Message(new { id = "android:emulator-5554", video = new[] { "h264" } }), null, default);
    var response = await screens.HandleAsync("one", Full, "sims.record", Message(new { id = "android:emulator-5554", @do = "start" }), "r", default);
    Assert.Equal("recording", Assert.Single(response)["state"]!.GetValue<string>());
    await Assert.ThrowsAsync<PhoneRefusal>(() => screens.HandleAsync("two", Full, "sims.record", Message(new { id = "android:emulator-5554", @do = "stop", to = "hoot" }), "r2", default).AsTask());
    await screens.HandleAsync("one", Full, "sims.unwatch", Message(new { id = "android:emulator-5554" }), null, default);
    Assert.Equal(["start", "cancel"], host.Steps);
  }

  [Fact]
  public async Task PcScreenSwitchStopsOnlyPcAndLeavesEmulatorWatchAndRecordingUsable()
  {
    var host = new Host(); var allowed = true;
    using var screens = new PhoneScreens(host, () => allowed, "Off", () => [], (_, _, _, _, _) => ValueTask.FromResult("sent")) { DeliverRecording = (_, _, _, _, _) => ValueTask.FromResult("sent"), Video = new FakeScreenVideo(), HasLink = _ => true };
    await screens.HandleAsync("one", Full, "sims.watch", Message(new { id = "mac:1", video = new[] { "h264" } }), null, default);
    await screens.HandleAsync("one", Full, "sims.watch", Message(new { id = "android:emulator-5554", video = new[] { "h264" } }), null, default);
    allowed = false; await screens.StopPcAsync("Off");
    var viewer = Assert.Single(screens.Viewers()); Assert.Equal("Synthetic emulator", viewer.Display);
    var started = await screens.HandleAsync("one", Full, "sims.record", Message(new { id = "android:emulator-5554", @do = "start" }), "r", default);
    Assert.Equal("recording", Assert.Single(started)["state"]!.GetValue<string>());
    await screens.HandleAsync("one", Full, "sims.shot", Message(new { id = "android:emulator-5554" }), "s", default);
    await Assert.ThrowsAsync<PhoneRefusal>(() => screens.HandleAsync("one", Full, "sims.watch", Message(new { id = "mac:1", video = new[] { "h264" } }), null, default).AsTask());
    await screens.StopAllAsync("test end");
  }

  [Fact]
  public async Task PicksUseTheKeptInspectionAndScreenshotTokensCannotCrossPhones()
  {
    var host = new Host(); string delivered = "";
    using var screens = new PhoneScreens(host, () => true, "Off", () => [], (_, note, _, _, _) => { delivered = note; return ValueTask.FromResult("sent"); });
    var inspected = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
    screens.Bind((_, bytes) => { using var doc = JsonDocument.Parse(bytes); if (doc.RootElement.GetProperty("t").GetString() == "sims.elements") inspected.TrySetResult(doc.RootElement.Clone()); return ValueTask.CompletedTask; }, _ => Full);
    var shot = await screens.HandleAsync("one", Full, "sims.shot", Message(new { id = "mac:1", inspect = true }), "s", default);
    var elements = await inspected.Task.WaitAsync(TimeSpan.FromSeconds(2));
    Assert.Equal("Sign in", elements.GetProperty("elements")[0].GetProperty("n").GetString());
    var token = shot[0]["shot"]!.GetValue<string>();
    var annotation = Message(new { id = "mac:1", shot = token, to = "hoot", note = "Fix this", marks = Array.Empty<object>(), picks = new[] { 0 } });
    await Assert.ThrowsAsync<PhoneRefusal>(() => screens.HandleAsync("two", Full, "sims.annotate", annotation, "a", default).AsTask());
    await screens.HandleAsync("one", Full, "sims.annotate", annotation, "a", default);
    Assert.Contains("#1: button · Sign in (login)", delivered);
    await Assert.ThrowsAsync<PhoneRefusal>(() => screens.HandleAsync("one", Full, "sims.annotate", Message(new { id = "mac:1", shot = token, to = "hoot", picks = new[] { 5 } }), "bad", default).AsTask());
  }
}
