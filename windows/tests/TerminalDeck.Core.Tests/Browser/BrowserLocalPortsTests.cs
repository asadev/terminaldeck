using TerminalDeck.Core.Browser;

namespace TerminalDeck.Core.Tests.Browser;

public sealed class BrowserLocalPortsTests
{
  [Fact] public void DevServersRankFirstServicesAreHiddenAndOwnPortsStayAtTheEnd()
  {
    BrowserLocalPort[] listeners = [new(5173, 1, "node"), new(3000, 2, "dotnet"), new(5432, 3, "postgres"), new(50000, 4, "svchost"), new(9000, 5, "unknown"), new(8090, 6, "TerminalDeck", true), new(5173, 1, "node")];
    Assert.Equal(new[] { 5173, 3000, 9000, 8090 }, BrowserLocalPorts.Select(listeners).Select(p => p.Port));
  }
}
