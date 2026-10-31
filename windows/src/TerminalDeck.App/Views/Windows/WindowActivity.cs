using System.Runtime.CompilerServices;
using Microsoft.UI.Xaml;

namespace TerminalDeck.App.Shell;

// Which windows are active, by XamlRoot, so a selected row can drop to the soft
// grey "window inactive" selection with normal text, like the Mac.
internal static class WindowActivity
{
  private static readonly ConditionalWeakTable<XamlRoot, StrongBox<bool>> inactive = new();
  public static event Action? Changed;
  public static void Track(Window window, FrameworkElement root) =>
    window.Activated += (_, e) =>
    {
      if (root.XamlRoot is not { } xamlRoot) return;
      inactive.AddOrUpdate(xamlRoot, new(e.WindowActivationState == WindowActivationState.Deactivated));
      Changed?.Invoke();
    };
  public static bool IsActive(XamlRoot? root) => root is null || !inactive.TryGetValue(root, out var box) || !box.Value;
}
