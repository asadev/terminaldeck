using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
namespace TerminalDeck.App.Shell;
internal static class WindowsVoiceTyping
{
  public static bool Start(TextBox composer)
  {
    if (!composer.Focus(FocusState.Programmatic)) return false;
    var inputs = new[] { VoiceKey(0x5B), VoiceKey(0x48), VoiceKey(0x48, true), VoiceKey(0x5B, true) };
    var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<VoiceInput>());
    if (sent != inputs.Length)
    {
      // A partial insertion must not leave a synthetic Windows key held down.
      var release = new[] { VoiceKey(0x48, true), VoiceKey(0x5B, true) };
      SendInput((uint)release.Length, release, Marshal.SizeOf<VoiceInput>());
    }
    return sent == inputs.Length;
  }
  private static VoiceInput VoiceKey(ushort key, bool up = false) => new()
  { Type = 1, Data = new() { Keyboard = new() { Key = key, Flags = up ? 2u : 0u } } };

  [StructLayout(LayoutKind.Sequential)]
  private struct VoiceInput { public uint Type; public VoiceInputData Data; }
  [StructLayout(LayoutKind.Explicit)]
  private struct VoiceInputData
  {
    [FieldOffset(0)] public VoiceKeyboard Keyboard;
    // INPUT's union is sized by MOUSEINPUT, including pointer alignment on ARM64/x64.
    [FieldOffset(0)] public VoiceMouse Mouse;
  }
  [StructLayout(LayoutKind.Sequential)]
  private struct VoiceKeyboard { public ushort Key, Scan; public uint Flags, Time; public nuint ExtraInfo; }
  [StructLayout(LayoutKind.Sequential)]
  private struct VoiceMouse { public int X, Y; public uint Data, Flags, Time; public nuint ExtraInfo; }
  [DllImport("user32.dll", SetLastError = true)]
  private static extern uint SendInput(uint count, [In] VoiceInput[] inputs, int size);
}
