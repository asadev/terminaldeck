using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TerminalDeck.App.Views;

public sealed partial class ShellWindow
{
  private bool browserVisibilityQueued;
  private void QueueVisibleBrowserViews()
  {
    if (browserVisibilityQueued || closingShell) return;
    browserVisibilityQueued = true;
    DispatcherQueue.TryEnqueueHandled(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, () =>
    {
      browserVisibilityQueued = false;
      // Browser selection is global; visual ownership is per pane/window. A
      // background retained browser must not disappear when another is selected.
      foreach (var surface in new[] { mainSurface }.Concat(detached.Values.Select(child => child.Surface)))
        foreach (var view in ProofTree(surface).OfType<WebView2>()) view.Visibility = Visibility.Visible;
    });
  }
  private async Task SelectBrowserForShellAsync(string id)
  {
    try { await browser.SelectShellWindowAsync(id); QueueVisibleBrowserViews(); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { Model.Notice = "This browser window could not be selected. Its page was kept."; }
  }
}
