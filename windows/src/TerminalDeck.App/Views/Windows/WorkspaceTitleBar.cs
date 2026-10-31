using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace TerminalDeck.App.Shell;

// Only the empty region is a drag surface. Tabs and toolbar controls keep
// normal input; Windows keeps its caption buttons, Snap and double-click zoom.
internal sealed class WorkspaceTitleBar
{
  private readonly Window window;
  private readonly FrameworkElement root;
  private readonly FrameworkElement captionSpace;
  public WorkspaceTitleBar(Window window, FrameworkElement root, FrameworkElement drag, FrameworkElement captionSpace)
  {
    this.window = window; this.root = root; this.captionSpace = captionSpace;
    window.ExtendsContentIntoTitleBar = true;
    window.AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Standard;
    window.SetTitleBar(drag);
    WindowActivity.Track(window, root);
    if (Environment.GetEnvironmentVariable("TD_SHELL_PROOF") is not null || Environment.GetEnvironmentVariable("TD_W12_SHELL_PROOF") is not null)
      window.Activated += (_, _) => ShellProofNative.Behind(window);
    root.Loaded += (_, _) => Update();
    root.SizeChanged += (_, _) => Update();
    root.ActualThemeChanged += (_, _) => Update();
    window.AppWindow.Changed += (_, _) => Update();
    Update();
  }
  private void Update()
  {
    var bar = window.AppWindow.TitleBar;
    var scale = root.XamlRoot?.RasterizationScale ?? 1;
    captionSpace.Width = Math.Max(138, bar.RightInset / scale);
    var ink = (SolidColorBrush)ShellTheme.Resource(root, "DeckInkBrush");
    bar.ButtonBackgroundColor = Microsoft.UI.Colors.Transparent;
    bar.ButtonInactiveBackgroundColor = Microsoft.UI.Colors.Transparent;
    bar.ButtonForegroundColor = ink.Color;
    bar.ButtonInactiveForegroundColor = ink.Color;
    bar.ButtonHoverBackgroundColor = ((SolidColorBrush)ShellTheme.Resource(root, "DeckHoverBrush")).Color;
    bar.BackgroundColor = Microsoft.UI.Colors.Transparent;
    bar.InactiveBackgroundColor = Microsoft.UI.Colors.Transparent;
    bar.ForegroundColor = ink.Color;
  }
}
