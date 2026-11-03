using Xunit;

namespace TerminalDeck.App.Shell;

public sealed class WorkspaceTabSizingTests
{
  [Theory]
  [InlineData(1, 1400, 220)]
  [InlineData(2, 400, 200)]
  [InlineData(5, 900, 180)]
  [InlineData(20, 900, 45)]
  [InlineData(40, 100, 40)]
  public void EqualTabsShrinkToIconFloorBeforeScrolling(int count, double available, double width)
  {
    Assert.Equal(width, WorkspaceTabSizing.Width(count, available));
    Assert.Equal(available < count * WorkspaceTabSizing.Minimum, WorkspaceTabSizing.Overflows(count, available));
  }
  [Fact] public void EmptyStripHasNoContentWidth() => Assert.Equal(0, WorkspaceTabSizing.Width(0, 900));

  public static IEnumerable<object[]> ShellSizes()
  {
    foreach (var width in new[] { 1280, 1920 })
    foreach (var sidebar in new[] { true, false })
    foreach (var count in new[] { 5, 15, 30 }) yield return [width, sidebar, count];
  }
  [Theory]
  [MemberData(nameof(ShellSizes))]
  public void ShellMatrixReservesChromeAndScrollsOnlyAtMinimum(int window, bool sidebar, int count)
  {
    // Title-bar columns reserve sidebar/toggle, add buttons, drag area and caption.
    var available = window - (sidebar ? 264 : 48) - 60 - 48 - 138 - 16;
    var overflow = WorkspaceTabSizing.Overflows(count, available);
    var viewport = WorkspaceTabSizing.Viewport(count, available);
    var width = WorkspaceTabSizing.Width(count, viewport);
    Assert.InRange(width, WorkspaceTabSizing.Minimum, WorkspaceTabSizing.Maximum);
    Assert.Equal(overflow ? available - 56 : available, viewport);
    if (overflow) Assert.Equal(WorkspaceTabSizing.Minimum, width);
    else Assert.True(width * count <= viewport);
    var details = WorkspaceTabSizing.ForWidth(width);
    Assert.Equal(width >= 72, details.Title);
    Assert.Equal(width >= 112, details.ProjectPicture);
    Assert.Equal(width >= 156, details.Close);
  }
  [Fact]
  public void IconOnlyTabsDoNotRetainTitleOrExtraDecorations()
  {
    var details = WorkspaceTabSizing.ForWidth(WorkspaceTabSizing.Minimum);
    Assert.False(details.Title);
    Assert.False(details.ProjectPicture);
    Assert.False(details.Close);
  }
}
