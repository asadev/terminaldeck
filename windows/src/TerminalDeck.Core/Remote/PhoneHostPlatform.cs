using System.Text.Json.Nodes;

namespace TerminalDeck.Core.Remote;

// What the phone features need from Windows itself. Core speaks the phone's
// wire (the same messages a Mac host sends); Platform.Windows reads the machine.

// Activity page (capability `activity`): one reading in the phone's
// activity.sample shape, without "t": at (ms since 1970), cpu {total, cores,
// count}, memory {used, total, pressure, swapUsed, swapTotal} (bytes),
// load (null on Windows), disk {free, total}, net {in, out} (bytes a second,
// null on the first reading), busy, and topCPU/topMemory (each at most 6 rows
// {name, kind: session|app|process, cpu %, memory bytes, processes}) when top.
public interface ISystemActivityReader
{
  JsonObject Sample(bool top);
}

// A Terminal Deck session's worker process: the processes under it are counted
// as that session ("Deck Dev · build") on the Activity page.
public sealed record ActivitySessionRoot(int ProcessId, long StartedUtcTicks, string Label);

// "This PC" on the phone's Devices page: the same `mac:<n>` rows and
// sims.frame / sims.input wire the phone uses for "This Mac".
public sealed record ScreenDisplay(string Id, string Name, int PixelWidth, int PixelHeight, bool Main);
// Jpeg is empty when the picture is unchanged (Hash equals the hash asked about).
public sealed record ScreenPicture(byte[] Jpeg, int Width, int Height, ulong Hash)
{
  public int? X { get; init; }
  public int? Y { get; init; }
  public int FullWidth { get; init; }
  public int FullHeight { get; init; }
}
// A full-size still (top-down BGRA, 4 bytes a pixel) kept for Annotate.
public sealed record ScreenStill(byte[] Bgra, int Width, int Height);
// The pointer's shape: Width/Height and the hot spot as shares of the display (Width, Height)
// and of the picture (HotX, HotY); Token changes when the shape changes.
public sealed record ScreenCursor(int Token, byte[] Png, double HotX, double HotY, double Width, double Height);
// Where the pointer is, 0..1 across and down the display; Shape only when it is not `knownShape`.
public sealed record ScreenPointer(double X, double Y, bool OnDisplay, ScreenCursor? Shape);

// Positions are 0..1 across and down the display; deltas are shares of it (-1..1).
public abstract record ScreenInput
{
  public sealed record Mouse(string Phase, string Button, double X, double Y, int Clicks) : ScreenInput;
  public sealed record Tap(double X, double Y, double? HoldMilliseconds) : ScreenInput;
  public sealed record RightTap(double X, double Y) : ScreenInput;
  public sealed record Scroll(double X, double Y, double Dx, double Dy) : ScreenInput;
  public sealed record Swipe(double X, double Y, double X2, double Y2, double Milliseconds) : ScreenInput;
  public sealed record Rotate(string? Orientation = null) : ScreenInput;
  public sealed record HardwareButton(string Name) : ScreenInput;
  public sealed record TypeText(string Text) : ScreenInput;
  // Name: return, enter, tab, escape, delete (Backspace), forward-delete, space, arrow-*,
  // home, end, page-up, page-down, f1..f12, select-all, or one letter/digit.
  // Modifiers: command (Ctrl on Windows), control, option (Alt), shift.
  public sealed record Key(string Name, IReadOnlyList<string> Modifiers) : ScreenInput;
  // The trackpad: move the pointer by a share of the display from where it is; Held keeps the left button down (drag).
  public sealed record Pointer(double Dx, double Dy, bool Held) : ScreenInput;
  // A click where the pointer is: left, right or middle; Phase "down"/"up" for a drag, null for a whole click.
  public sealed record Click(string Button, string? Phase) : ScreenInput;
  // Scroll where the pointer is, by a share of the display (a finger moving the content down scrolls up).
  public sealed record Wheel(double Dx, double Dy) : ScreenInput;
}

public interface IScreenHost
{
  IReadOnlyList<ScreenDisplay> Displays();
  // The display scaled so its longest side is at most maxSide, as a JPEG at quality (10..95).
  // drawCursor: include the pointer in the picture (a phone that draws it itself says no).
  // Null with a problem when the screen cannot be read now (locked, a secure desktop).
  ScreenPicture? Capture(string displayId, int maxSide, int quality, bool drawCursor, ulong? unlessHash, out string? problem);
  ScreenStill? Still(string displayId, out string? problem);
  byte[] EncodePng(ScreenStill still);
  byte[] EncodeJpeg(ScreenStill still, int maxSide, int quality, out int width, out int height);
  // Applies one input now, on the caller's thread; answers a refusal in words, or null.
  string? Post(string displayId, ScreenInput input);
  ScreenPointer? Pointer(string displayId, int knownShape);
  // True while a text field has the keyboard focus, false when not, null when it cannot be told.
  bool? TextFocus();
  // Why the screen cannot be read right now (disconnected session, locked), or null. Said on the row before a tap.
  string? Blocked() => null;
  // The same in two or three words for the row ("Remote Desktop disconnected", "Locked").
  string? BlockedStatus() => Blocked() is null ? null : "Not available";
}
