using Microsoft.UI.Composition.SystemBackdrops;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.UI.ViewManagement;

namespace TerminalDeck.App.Shell;

// The backdrop belongs to the HWND. Painting Acrylic over it hides the wallpaper
// tint. Only opaque pages and system-policy fallbacks paint over this layer.
internal static class WindowMaterials
{
  internal static void Attach(Window window, Grid root, Grid? title = null, MicaKind kind = MicaKind.BaseAlt)
  {
    var ui = new UISettings();
    var accessibility = new AccessibilitySettings();
    bool HighContrast() { try { return accessibility.HighContrast; } catch (Exception ex) when (ex is System.Runtime.InteropServices.COMException) { return false; } }
    var supported = MicaController.IsSupported();
    if (supported) window.SystemBackdrop = new MicaBackdrop { Kind = kind };
    void Update()
    {
      // Bitmap proofs cannot see the HWND backdrop; they draw the solid fallback so
      // renders show real colours instead of a black or white hole.
      var material = supported && ui.AdvancedEffectsEnabled && !HighContrast() && Environment.GetEnvironmentVariable("TD_UI_CONSISTENCY_PROOF") is null;
      PaintChrome(root, title, material);
    }
    void Effects(UISettings sender, object args) => root.DispatcherQueue.TryEnqueue(() => Update());
    // AccessibilitySettings.HighContrastChanged throws 0x80070490 in a desktop
    // (non-CoreWindow) app and crashed 44023 at launch. A contrast theme switch
    // raises UISettings.ColorValuesChanged, which desktop apps may observe.
    void Colours(UISettings sender, object args) => root.DispatcherQueue.TryEnqueue(() => Update());
    ui.AdvancedEffectsEnabledChanged += Effects;
    ui.ColorValuesChanged += Colours;
    root.ActualThemeChanged += Theme;
    void Theme(FrameworkElement sender, object args) => Update();
    window.Closed += (_, _) =>
    {
      ui.AdvancedEffectsEnabledChanged -= Effects;
      ui.ColorValuesChanged -= Colours;
      root.ActualThemeChanged -= Theme;
    };
    Update();
  }

  internal static void PaintChrome(Grid root, Grid? title, bool material)
  {
    root.Background = (Brush)ShellTheme.Resource(root, material ? "DeckTransparentBrush" : "DeckRailBrush");
    if (title is not null) title.Background = (Brush)ShellTheme.Resource(root, material ? "DeckTransparentBrush" : "DeckTopBarBrush");
  }
}
