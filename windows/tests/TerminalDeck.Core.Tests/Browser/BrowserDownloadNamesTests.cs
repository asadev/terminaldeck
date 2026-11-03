using TerminalDeck.Core.Browser;

namespace TerminalDeck.Core.Tests.Browser;

public sealed class BrowserDownloadNamesTests
{
  [Theory]
  [InlineData(@"C:\Users\person\Downloads\report.pdf", "report.pdf")]
  [InlineData("../../report.pdf", "report.pdf")]
  [InlineData(".. ", "download")]
  [InlineData("bad:name.exe", "download")]
  [InlineData("CON.txt", "download-CON.txt")]
  [InlineData("report 1.txt", "report 1.txt")]
  public void NamesRemainSingleWindowsFileNames(string suggested, string expected) => Assert.Equal(expected, BrowserDownloadNames.FileName(suggested));
}
