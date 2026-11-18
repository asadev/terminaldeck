using Xunit;

namespace TerminalDeck.App.Shell;

public sealed class WorkspaceTabSizingTests
{
  [Fact] public void EmptyStripHasNoContentWidth() => Assert.Empty(WorkspaceTabSizing.Widths(0, 900, -1));
  [Fact] public void SeventeenTabsUseTheWholeHeaderAndKeepTheSelectedTitleReadable()
  {
    var widths = WorkspaceTabSizing.Widths(17, 1600, 14);
    Assert.Equal(120, widths[14]); Assert.All(widths, width => Assert.InRange(width, 36, 220));
    Assert.Equal(1600, widths.Sum() + 16 * WorkspaceTabSizing.Gap, 6);
    Assert.False(WorkspaceTabSizing.Overflows(17, 1600));
  }
  public static IEnumerable<object[]> ShellSizes()
  {
    foreach (var width in new[] { 1280, 1920 })
    foreach (var sidebar in new[] { true, false })
    foreach (var count in new[] { 5, 15, 30, 64 }) yield return [width, sidebar, count];
  }
  [Theory] [MemberData(nameof(ShellSizes))]
  public void ShellMatrixKeepsTheNewTabControlReachableAndScrollsAtTheFloor(int window, bool sidebar, int count)
  {
    var available = window - (sidebar ? 264 : 48) - 30 - 138 - 16;
    var overflow = WorkspaceTabSizing.Overflows(count, available); var viewport = WorkspaceTabSizing.Viewport(count, available);
    var widths = WorkspaceTabSizing.Widths(count, viewport, 2);
    Assert.All(widths, width => Assert.InRange(width, WorkspaceTabSizing.Minimum, WorkspaceTabSizing.Maximum));
    Assert.True(widths[2] >= WorkspaceTabSizing.SelectedMinimum);
    Assert.Equal(overflow ? available - 56 : available, viewport);
    var total = widths.Sum() + (count - 1) * WorkspaceTabSizing.Gap;
    if (!overflow) Assert.True(total <= viewport + .01);
    else Assert.True(total > viewport);
  }
  [Fact] public void SmallTabShowsOnlyItsIcon()
  {
    var detail = WorkspaceTabSizing.ForWidth(36); Assert.False(detail.Title); Assert.False(detail.ProjectPicture); Assert.False(detail.Close);
    Assert.True(WorkspaceTabSizing.ForWidth(120).Title);
  }
  [Fact] public void DraggingAcrossTheWiderSelectedTabUsesItsActualEdges()
  {
    double[] widths = [40, 120, 40, 40];
    Assert.Equal(1, WorkspaceTabSizing.Reorder(widths, 0, 65));
    Assert.Equal(0, WorkspaceTabSizing.Reorder(widths, 1, -25));
    Assert.Equal(2, WorkspaceTabSizing.Reorder(widths, 1, 25));
    Assert.Equal(1, WorkspaceTabSizing.Reorder(widths, 2, -65));
  }
}
