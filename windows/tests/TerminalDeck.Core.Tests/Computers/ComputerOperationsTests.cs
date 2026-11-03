using System.Text.Json.Nodes;
using TerminalDeck.Core.Computers;

namespace TerminalDeck.Core.Tests.Computers;

public sealed class ComputerOperationsTests
{
  [Theory]
  [InlineData("controls-read", "controls.read", "controls", "controls.reading", "{\"id\":\"session-1\"}")]
  [InlineData("account-switch", "account.switch", "account", "account.switched", "{\"id\":\"session-1\",\"accountId\":\"login-2\"}")]
  [InlineData("sign-in", "logins.signin", "logins", "logins.signedin", "{\"accountId\":\"login-2\"}")]
  [InlineData("host-restart", "host.restart", "host.control", "host.state", "{}")]
  [InlineData("github-connect", "github.connect", "github", "github.state", "{}")]
  public void MatchesSharedHostWireContract(string action, string tag, string capability, string reply, string json)
  {
    var operation = ComputerOperations.Validate(action, JsonNode.Parse(json)!.AsObject());
    Assert.Equal(tag, operation.Tag); Assert.Equal(capability, operation.Capability); Assert.Equal(reply, operation.Reply);
  }
  [Theory]
  [InlineData("host-restart", "{\"t\":\"host.stop\"}")]
  [InlineData("github-connect", "{\"rid\":\"other-request\"}")]
  [InlineData("account-switch", "{\"id\":\"s\"}")]
  [InlineData("controls-set", "{\"id\":\"s\",\"control\":\"sandboxEscape\",\"value\":\"yes\"}")]
  [InlineData("usage", "{\"id\":\"s\",\"want\":\"credentials\"}")]
  [InlineData("host-read", "{\"token\":\"private\"}")]
  public void RejectsMalformedOrCrossOperationFields(string action, string json) => Assert.Throws<ArgumentException>(() => ComputerOperations.Validate(action, JsonNode.Parse(json)!.AsObject()));
  [Fact] public void KeysPreserveControlCharactersAndSupplementaryUnicode()
  {
    Assert.Equal("\r\u001b[A\u0003😀", ComputerSessionKeys.Encode(["enter", "up", "ctrl-c", "😀"]));
  }
  [Fact] public void KeysRejectRawControlAndUnboundedInput()
  {
    Assert.Throws<ArgumentException>(() => ComputerSessionKeys.Encode(["\u001b"]));
    Assert.Throws<ArgumentException>(() => ComputerSessionKeys.Encode(Enumerable.Repeat("a", 65)));
  }
}
