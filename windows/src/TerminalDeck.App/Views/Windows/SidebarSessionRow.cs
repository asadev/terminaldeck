using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.Shell;

namespace TerminalDeck.App.Views;

// Child controls have their own default foregrounds. Follow the actual list
// selection so the title, subtitle, dot and menu all remain legible on blue.
public sealed class SidebarSessionRow : Grid
{
  private static readonly Dictionary<string, Style> textStyles = [];
  private static Style TextStyle(string key)
  {
    if (!textStyles.TryGetValue(key, out var style))
    {
      style = (Style)Microsoft.UI.Xaml.Markup.XamlReader.Load("<Style xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" TargetType=\"TextBlock\">" + DeckFonts.TextSetter + "<Setter Property=\"Foreground\" Value=\"{ThemeResource " + key + "}\"/></Style>");
      textStyles[key] = style;
    }
    return style;
  }
  private ListViewItem? container;
  private long selectionToken;
  private bool hovering;
  private bool pressed;
  public SidebarSessionRow()
  {
    CornerRadius = new CornerRadius(8); Padding = new Thickness(8, 3, 8, 3);
    Loaded += (_, _) => { Attach(); WindowActivity.Changed -= Apply; WindowActivity.Changed += Apply; };
    Unloaded += (_, _) => { Detach(); WindowActivity.Changed -= Apply; };
    ActualThemeChanged += (_, _) => Apply();
    PointerEntered += (_, _) => { hovering = true; Apply(); };
    PointerExited += (_, _) => { hovering = false; pressed = false; Apply(); };
    PointerPressed += (_, _) => { pressed = true; Apply(); };
    PointerReleased += (_, _) => { pressed = false; Apply(); };
    PointerCaptureLost += (_, _) => { pressed = false; Apply(); };
    GotFocus += (_, _) => Apply(); LostFocus += (_, _) => Apply();
  }
  private void Attach()
  {
    Detach();
    DependencyObject? parent = this;
    while (parent is not null && parent is not ListViewItem) parent = VisualTreeHelper.GetParent(parent);
    container = parent as ListViewItem;
    if (container is not null) { container.Padding = new Thickness(0); container.Margin = new Thickness(0, 2, 0, 2); }
    if (container is not null) selectionToken = container.RegisterPropertyChangedCallback(ListViewItem.IsSelectedProperty, (_, _) => Apply());
    Apply();
  }
  private void Detach()
  {
    if (container is not null) container.UnregisterPropertyChangedCallback(ListViewItem.IsSelectedProperty, selectionToken);
    container = null;
  }
  private static bool InsidePicture(DependencyObject child)
  {
    for (var parent = VisualTreeHelper.GetParent(child); parent is not null; parent = VisualTreeHelper.GetParent(parent))
      if (parent is SessionPicture) return true;
    return false;
  }
  private void Apply()
  {
    var selected = container?.IsSelected == true;
    // Selected wins over pressed (a click that moves focus away never leaves the
    // row grey with white text). In an inactive window the selection is a soft
    // grey with normal text, like the Mac; blue with white only while active.
    var active = WindowActivity.IsActive(XamlRoot) || new global::Windows.UI.ViewManagement.AccessibilitySettings().HighContrast;
    var onAccent = selected && active;
    Background = (Brush)ShellTheme.Resource(this, selected ? (active ? "DeckSidebarSelectionBrush" : "DeckSidebarSelectionInactiveBrush") : pressed ? "DeckPressedBrush" : hovering ? "DeckHoverBrush" : "DeckTransparentBrush");
    var ink = (Brush)ShellTheme.Resource(this, onAccent ? "DeckSidebarSelectionInkBrush" : "DeckInkBrush");
    foreach (var child in WorkspaceVisuals.Tree(this))
    {
      if (child is SessionPicture picture) { picture.OnAccent = onAccent; picture.RowSurface(hovering ? "DeckHoverBrush" : "DeckRailBrush"); }
      if (InsidePicture(child)) continue;
      // Keep W14's live theme binding without recolouring avatar descendants.
      if (child is TextBlock text)
      {
        text.ClearValue(TextBlock.ForegroundProperty);
        text.Style = TextStyle(onAccent ? "DeckSidebarSelectionInkBrush" : text.Tag as string == "SessionSubtitle" ? "DeckSecondaryInkBrush" : "DeckInkBrush");
      }

      if (child is SessionStatusMark status) status.OnAccent = onAccent;
      if (child is Button menu)
      {
        menu.Foreground = ink;
        menu.Opacity = selected || hovering || menu.FocusState != FocusState.Unfocused ? 1 : 0;
      }
    }
  }
}
