using TerminalDeck.Core.Remote;

namespace TerminalDeck.Platform.Windows.Phone;

public sealed partial class WindowsScreenHost
{
  private static string? AbsoluteMouse(Monitor monitor, ScreenInput.Mouse mouse)
  {
    var moved = Send([MoveTo(monitor, mouse.X, mouse.Y)]);
    if (moved is not null || mouse.Phase is "move" or "drag") return moved;
    return Click(mouse.Button, mouse.Phase);
  }
}
