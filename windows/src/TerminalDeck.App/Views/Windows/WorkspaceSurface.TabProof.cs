using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace TerminalDeck.App.Shell;

internal sealed partial class WorkspaceSurface
{
  internal FrameworkElement? UmerPaneForProof(string id) => paneFrames.GetValueOrDefault(id);
  internal Button UmerTabForProof(string id) => tabButtons[id];
  internal void UmerSlideForProof(string id, double offset) { Slide(id, offset); EndSlide(id, true); }
  internal object TabProofSnapshot(FrameworkElement root)
  {
    double Left(FrameworkElement element) => element.TransformToVisual(root).TransformPoint(new(0, 0)).X;
    var tabs = tabFrames.Values.ToArray();
    var widths = tabs.Select(tab => tab.ActualWidth).ToArray();
    var left = Left(stripViewport);
    return new
    {
      Count = tabs.Length,
      Widths = widths,
      EqualWidths = widths.Length == 0 || widths.Max() - widths.Min() < 1,
      MinimumRespected = widths.All(width => width >= WorkspaceTabSizing.Minimum - 0.5),
      ViewportLeft = left,
      ViewportRight = left + stripViewport.ActualWidth,
      HeaderLeft = Left(Header),
      HeaderRight = Left(Header) + Header.ActualWidth,
      Arrows = previousTabs.Visibility == Visibility.Visible,
      ArrowsOnlyAfterMinimum = (previousTabs.Visibility == Visibility.Visible) == WorkspaceTabSizing.Overflows(tabs.Length, stripHost.ActualWidth),
      TitlesMatchWidth = tabFrames.All(pair => (tabTitles[pair.Key].Visibility == Visibility.Visible) == WorkspaceTabSizing.ForWidth(pair.Value.ActualWidth).Title),
      ViewportClearOfNewTabButtons = left + stripViewport.ActualWidth <= Left(Header.Children.OfType<StackPanel>().Single()) + 0.5,
      ViewportInsideHeader = left >= Left(Header) - 0.5,
      ContentWidth = strip.ActualWidth,
      ViewportWidth = stripViewport.ActualWidth,
      NoOverflowWithoutArrows = previousTabs.Visibility == Visibility.Visible || strip.ActualWidth <= stripViewport.ActualWidth + 1
    };
  }
}
