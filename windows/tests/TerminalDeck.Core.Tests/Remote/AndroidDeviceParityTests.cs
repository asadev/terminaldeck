using System.Text;
using System.Text.Json;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class AndroidDeviceParityTests
{
  [Theory]
  [InlineData("android:emulator-5554", "emulator-5554")]
  [InlineData("android:R58M123456", "R58M123456")]
  [InlineData("android:192.0.2.5:5555", "192.0.2.5:5555")]
  [InlineData("android:adb-123._adb-tls-connect._tcp", "adb-123._adb-tls-connect._tcp")]
  public void AuthorisedDeviceSerialFormsAreSafeSingleArguments(string id, string expected) => Assert.Equal(expected, AndroidSdkBridge.Serial(id));
  [Theory]
  [InlineData("android:-s")]
  [InlineData("android:phone; touch /tmp/unowned")]
  [InlineData("android:phone\nother")]
  [InlineData("android:")]
  public void RejectsInvalidDeviceIdentifiers(string id) => Assert.Throws<PhoneRefusal>(() => AndroidSdkBridge.Serial(id));
  [Theory]
  [InlineData("ready", true)]
  [InlineData("unauthorized", false)]
  [InlineData("offline", false)]
  public void PhysicalDevicesAdvertiseOnlyCurrentlyAvailableActions(string state, bool ready)
  {
    var row = AndroidDeviceList.Row("android:synthetic", "Synthetic phone", "physical", state);
    Assert.Equal(ready, row["canWatch"]!.GetValue<bool>());
    Assert.Equal(ready, row["canControl"]!.GetValue<bool>());
    Assert.Equal(ready, row["canRotate"]!.GetValue<bool>());
    Assert.False(row["canStop"]!.GetValue<bool>());
    Assert.False(row["canStart"]!.GetValue<bool>());
  }
  [Fact] public void RotationCyclesAndExplicitOrientationMatchAndroidSettings()
  {
    Assert.Equal(0, AndroidSdkBridge.Rotation(null, 3));
    Assert.Equal(1, AndroidSdkBridge.Rotation("landscape-left", 0));
    Assert.Equal(3, AndroidSdkBridge.Rotation("landscape-right", 0));
    Assert.Equal(2, AndroidSdkBridge.Rotation("portrait-upside-down", 0));
    Assert.IsType<ScreenInput.Rotate>(PhoneScreens.Parse(JsonSerializer.SerializeToElement(new { @do = "rotate" })));
    Assert.Throws<PhoneRefusal>(() => PhoneScreens.Parse(JsonSerializer.SerializeToElement(new { @do = "rotate", orientation = "arbitrary" })));
  }
  [Fact] public void UnicodeUsesOnlyAnAlreadySelectedCompatibleImeAndOneBase64Argument()
  {
    const string text = "مرحبا 你好 😀 ' ; $(not-a-command)";
    var command = AndroidSdkBridge.UnicodeCommand(text, "com.android.adbkeyboard/.AdbIME\n");
    Assert.Equal("ADB_INPUT_B64", command[3]);
    Assert.Equal(text, Encoding.UTF8.GetString(Convert.FromBase64String(command[^1])));
    Assert.Throws<PhoneRefusal>(() => AndroidSdkBridge.UnicodeCommand(text, "com.android.inputmethod.latin/.LatinIME"));
  }
  [Fact] public void HardwareButtonsAndModifiersUseAndroidKeyCodes()
  {
    Assert.Equal(new[] { "input", "keyevent", "187" }, AndroidSdkBridge.InputCommand(new ScreenInput.HardwareButton("overview"), 100, 200));
    Assert.Equal(new[] { "input", "keycombination", "113", "59", "29" }, AndroidSdkBridge.InputCommand(new ScreenInput.Key("a", ["control", "shift"]), 100, 200));
    Assert.Equal(new[] { "input", "motionevent", "UP", "99", "199" }, AndroidSdkBridge.InputCommand(new ScreenInput.Mouse("up", "left", 1, 1, 1), 100, 200));
  }
}
