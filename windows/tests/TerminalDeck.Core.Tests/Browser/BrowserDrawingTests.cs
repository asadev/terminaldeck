using TerminalDeck.Core.Browser;

namespace TerminalDeck.Core.Tests.Browser;

public sealed class BrowserDrawingTests
{
  [Fact] public void UndoAndClearKeepTheOriginalPictureAndIndependentMarkData()
  {
    var drawing = new BrowserDrawing(); var points = new[] { new BrowserDrawPoint(0.1, 0.2), new BrowserDrawPoint(0.8, 0.9) };
    foreach (var tool in Enum.GetValues<BrowserDrawTool>()) drawing.Add(new(tool, points, tool == BrowserDrawTool.Text ? "Move this" : ""));
    points[0] = new(0.9, 0.9); Assert.All(drawing.Marks, mark => Assert.Equal(0.1, mark.Points[0].X));
    var copy = drawing.Marks[0]; copy.Points[0] = new(0, 0); Assert.Equal(0.1, drawing.Marks[0].Points[0].X);
    drawing.Undo(); Assert.Equal(3, drawing.Marks.Count); drawing.Clear(); drawing.Undo(); Assert.Empty(drawing.Marks);
  }
  [Theory] [InlineData(double.NaN, 0)] [InlineData(double.PositiveInfinity, 0)] [InlineData(-0.1, 0)] [InlineData(0, 1.1)]
  public void InvalidCoordinatesCannotEnterTheDraft(double x, double y) => Assert.Throws<ArgumentException>(() => new BrowserDrawing().Add(new(BrowserDrawTool.Box, [new(x, y)])));
  [Fact] public void EmptyTextCannotCreateAnInvisibleMark() => Assert.Throws<ArgumentException>(() => new BrowserDrawing().Add(new(BrowserDrawTool.Text, [new(0.5, 0.5)], " ")));
}
