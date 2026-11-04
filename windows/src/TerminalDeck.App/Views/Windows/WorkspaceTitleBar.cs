using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Windows.Foundation;
using Windows.Graphics;

namespace TerminalDeck.App.Shell;

// The whole title-bar row is the drag surface, as in a native title bar: empty
// space (beside the sidebar toggle, around and after the tabs) moves the window,
// double-click zooms and Snap works. Buttons and inputs in the row are cut out as
// passthrough regions, so tabs and toolbar controls keep normal input; Windows
// keeps its caption buttons.
internal sealed class WorkspaceTitleBar
{
  private readonly Window window;
  private readonly FrameworkElement root;
  private readonly FrameworkElement row;
  private readonly FrameworkElement captionSpace;
  private readonly InputNonClientPointerSource input;
  private readonly HashSet<Popup> popups = [];
  private bool closed;
  public WorkspaceTitleBar(Window window, FrameworkElement root, FrameworkElement row, FrameworkElement captionSpace)
  {
    this.window = window; this.root = root; this.row = row; this.captionSpace = captionSpace;
    window.ExtendsContentIntoTitleBar = true;
    window.AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Standard;
    window.SetTitleBar(row);
    input = InputNonClientPointerSource.GetForWindowId(window.AppWindow.Id);
    WindowActivity.Track(window, root);
    if (Environment.GetEnvironmentVariable("TD_SHELL_PROOF") is not null || Environment.GetEnvironmentVariable("TD_W12_SHELL_PROOF") is not null)
      window.Activated += (_, _) => ShellProofNative.Behind(window);
    root.Loaded += (_, _) => Update();
    root.SizeChanged += (_, _) => Update();
    root.ActualThemeChanged += (_, _) => Update();
    window.AppWindow.Changed += (_, _) => Update();
    // Tabs open, close, resize and the sidebar toggles without the row itself
    // changing size, so recheck after every layout pass; Windows is only told
    // when a region actually moved.
    row.LayoutUpdated += RowLayoutUpdated;
    window.Closed += (_, _) =>
    {
      closed = true;
      row.LayoutUpdated -= RowLayoutUpdated;
      foreach (var popup in popups) popup.Closed -= PopupClosed;
      popups.Clear();
    };
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
  private void RowLayoutUpdated(object? sender, object args) => UpdatePassthrough();
  private void UpdatePassthrough()
  {
    if (closed || row.XamlRoot is not { } xamlRoot || row.ActualWidth <= 0) return;
    var scale = xamlRoot.RasterizationScale;
    var area = Bounds(row);
    var rects = new List<RectInt32>();
    Interactive(row, area, scale, rects);
    // An open menu or flyout drawn over the row (a tab's context menu opens at
    // the pointer) must take clicks, not start a window drag.
    foreach (var popup in VisualTreeHelper.GetOpenPopupsForXamlRoot(xamlRoot))
    {
      if (popup.Child is not FrameworkElement { ActualWidth: > 0, ActualHeight: > 0, IsHitTestVisible: true } child || child is ToolTip) continue;
      Add(rects, Bounds(child), area, scale);
      if (popups.Add(popup)) popup.Closed += PopupClosed;
    }
    // Compare with what Windows holds (null until first set), not a cached copy.
    if (rects.SequenceEqual(input.GetRegionRects(NonClientRegionKind.Passthrough) ?? [])) return;
    input.SetRegionRects(NonClientRegionKind.Passthrough, [.. rects]);
  }
  // Closing a menu need not cause a layout pass; give its area back to dragging.
  private void PopupClosed(object? sender, object e)
  {
    if (sender is Popup popup && popups.Remove(popup)) popup.Closed -= PopupClosed;
    UpdatePassthrough();
  }
  private static void Interactive(DependencyObject parent, Rect clip, double scale, List<RectInt32> rects)
  {
    for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
    {
      if (VisualTreeHelper.GetChild(parent, i) is not FrameworkElement child || child.Visibility != Visibility.Visible || !child.IsHitTestVisible || child.ActualWidth <= 0 || child.ActualHeight <= 0) continue;
      if (child is ButtonBase or TextBox or PasswordBox or AutoSuggestBox or ComboBox) { Add(rects, Bounds(child), clip, scale); continue; }
      // Tabs scrolled out of the strip are not under the pointer.
      Interactive(child, child is ScrollViewer ? Intersect(clip, Bounds(child)) : clip, scale, rects);
    }
  }
  private static void Add(List<RectInt32> rects, Rect box, Rect clip, double scale)
  {
    box = Intersect(box, clip);
    if (box.Width <= 0 || box.Height <= 0) return;
    var left = (int)Math.Floor(box.X * scale); var top = (int)Math.Floor(box.Y * scale);
    rects.Add(new(left, top, (int)Math.Ceiling((box.X + box.Width) * scale) - left, (int)Math.Ceiling((box.Y + box.Height) * scale) - top));
  }
  private static Rect Intersect(Rect a, Rect b)
  {
    var left = Math.Max(a.X, b.X); var top = Math.Max(a.Y, b.Y);
    var right = Math.Min(a.X + a.Width, b.X + b.Width); var bottom = Math.Min(a.Y + a.Height, b.Y + b.Height);
    return right > left && bottom > top ? new(left, top, right - left, bottom - top) : new(left, top, 0, 0);
  }
  private static Rect Bounds(FrameworkElement element) => element.TransformToVisual(null).TransformBounds(new(0, 0, element.ActualWidth, element.ActualHeight));
}
