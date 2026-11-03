using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
namespace TerminalDeck.App.Shell;

internal static class WorkspaceVisuals
{
  internal static IEnumerable<DependencyObject> Tree(DependencyObject node)
  {
    yield return node;
    for (var index = 0; index < VisualTreeHelper.GetChildrenCount(node); index++)
      foreach (var child in Tree(VisualTreeHelper.GetChild(node, index))) yield return child;
  }
}
