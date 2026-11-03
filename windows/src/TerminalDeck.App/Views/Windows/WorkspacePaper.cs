using TerminalDeck.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace TerminalDeck.App.Shell;

// The frame remains fixed. Only terminal/browser content and its selected tab
// share the terminal paper; chats and project pages use the page surface.
internal static class WorkspacePaper
{
  internal const string Terminal = "DeckPaperBrush";
  internal const string Ink = "DeckTerminalInkBrush";
  internal static void ApplyInk(FrameworkElement root)
  {
    TerminalAppearanceBridge.EnsureInkResources();
    void Apply()
    {
      var ink = (Brush)ShellTheme.Resource(root, Ink);
      var primary = ShellTheme.Resource(root, "DeckInkBrush");
      var secondary = ShellTheme.Resource(root, "DeckSecondaryInkBrush");
      // Template defaults follow the terminal palette without replacing an
      // explicit status, accent, link or destructive foreground on a control.
      root.Resources["TextFillColorPrimaryBrush"] = ink;
      root.Resources["TextFillColorSecondaryBrush"] = ink;
      foreach (var item in WorkspaceVisuals.Tree(root).OfType<FrameworkElement>())
      {
        var property = item is TextBlock ? TextBlock.ForegroundProperty : item is IconElement ? IconElement.ForegroundProperty : item is Control ? Control.ForegroundProperty : null;
        if (property is null || item.ReadLocalValue(property) == DependencyProperty.UnsetValue) continue;
        var foreground = item.GetValue(property);
        if (ReferenceEquals(foreground, primary) || ReferenceEquals(foreground, secondary)) item.SetResourceReference(property, Ink);
      }
    }
    root.Loaded += (_, _) => Apply();
    root.ActualThemeChanged += (_, _) => Apply();
    Apply();
  }

  internal const string Page = "DeckCanvasBrush";
  internal static string For(WorkspaceTab tab, SessionDraft? session) => tab.Kind == "browser" || tab.Kind == "terminal" && session?.Presentation != SessionPresentation.Chat ? Terminal : Page;
}
