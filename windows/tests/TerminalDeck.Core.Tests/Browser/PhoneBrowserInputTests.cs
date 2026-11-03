using System.Text.Json;
using TerminalDeck.Core.Browser;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Browser;

public sealed class PhoneBrowserInputTests
{
  private static JsonElement Message(object value) => JsonSerializer.SerializeToElement(value);
  [Fact] public void ClickUsesTheExactDisplayedFramesScale()
  {
    var adjusted = PhoneBrowserInput.ForFrame(Message(new { seq = 7, mouse = new { type = "down", x = 240, y = 120, button = "left" } }), 0.5);
    var command = PhoneBrowserInput.Command(adjusted);
    Assert.Equal("Input.dispatchMouseEvent", command.Method);
    Assert.Equal(480, command.Arguments["x"]!.GetValue<double>());
    Assert.Equal(240, command.Arguments["y"]!.GetValue<double>());
    Assert.Equal("mousePressed", command.Arguments["type"]!.GetValue<string>());
  }
  [Fact] public void TouchAndWheelCoordinatesScaleButTextIsData()
  {
    var touch = PhoneBrowserInput.ForFrame(Message(new { touch = new { type = "move", points = new[] { new { x = 25, y = 50 } } } }), 0.25);
    var command = PhoneBrowserInput.Command(touch);
    Assert.Equal(100, command.Arguments["touchPoints"]![0]!["x"]!.GetValue<double>());
    var paste = PhoneBrowserInput.Command(Message(new { paste = "مرحبا 😀\n\t' ; $(nothing)\u0000" }));
    Assert.Equal("Input.insertText", paste.Method);
    Assert.Equal("مرحبا 😀\n\t' ; $(nothing)", paste.Arguments["text"]!.GetValue<string>());
  }
  [Fact] public void MultipleEventsMissingCoordinatesAndInvalidScalesNeverDispatch()
  {
    Assert.Throws<PhoneRefusal>(() => PhoneBrowserInput.Command(Message(new { mouse = new { type = "down", x = 1, y = 1 }, paste = "text" })));
    Assert.Throws<PhoneRefusal>(() => PhoneBrowserInput.Command(Message(new { mouse = new { type = "down", x = 1 } })));
    Assert.Throws<PhoneRefusal>(() => PhoneBrowserInput.Command(Message(new { mouse = new { type = "down", x = "bad", y = 1 } })));
    Assert.Throws<PhoneRefusal>(() => PhoneBrowserInput.ForFrame(Message(new { paste = "text" }), 0));
  }
  [Fact] public void PickQuotesCoordinatesAndBoundsParentTraversal()
  {
    Assert.Throws<PhoneRefusal>(() => PhoneBrowserPick.Script(Message(new { x = "script", y = 1 })));
    var script = PhoneBrowserPick.Script(Message(new { x = 1, y = 2, up = 100 }));
    Assert.Contains("\"up\":30", script);
    Assert.Contains("e.shadowRoot", script); Assert.Contains("e.contentDocument", script);
  }
}
