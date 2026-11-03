using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class PhoneBrowserWatchFeaturesTests
{
  private static readonly ApprovedDevice Device = new("device", "Phone", "ios", PhoneAccess.Full);
  private static JsonElement Message(object value) => JsonSerializer.SerializeToElement(value);
  [Fact]
  public async Task OnlyExactFrameAckBuysOneNextCapture()
  {
    var captures = 0; var frames = Channel.CreateUnbounded<JsonObject>();
    using var watch = new PhoneBrowserWatchFeatures((_, window) => window == "one", (_, _, _, _) =>
      { Interlocked.Increment(ref captures); return ValueTask.FromResult(Frame()); }, _ => [("one", "https://example.com", "Example")]);
    watch.Bind((_, frame, _) => { frames.Writer.TryWrite(frame); return ValueTask.CompletedTask; }, _ => Device);
    await watch.HandleAsync("phone", Device, "browser.watch", Message(new { window = "one", maxWidth = 600, quality = 70 }), null, default);
    var first = await frames.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
    Assert.Equal(1, first["seq"]!.GetValue<int>()); Assert.Equal(1, captures);
    await watch.HandleAsync("phone", Device, "browser.frame.ack", Message(new { window = "one", seq = 5 }), null, default);
    Assert.Equal(1, captures);
    await watch.HandleAsync("phone", Device, "browser.frame.ack", Message(new { window = "one", seq = 1 }), null, default);
    await watch.HandleAsync("phone", Device, "browser.frame.ack", Message(new { window = "one", seq = 1 }), null, default);
    var second = await frames.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
    Assert.Equal(2, second["seq"]!.GetValue<int>()); Assert.Equal(2, captures);
    await watch.DisconnectedAsync("phone");
  }
  [Fact]
  public async Task MissingCurrentDeviceAndLookCannotCapturePixels()
  {
    var captures = 0;
    using var watch = new PhoneBrowserWatchFeatures((_, _) => true, (_, _, _, _) => { captures++; return ValueTask.FromResult(Frame()); }, _ => []);
    watch.Bind((_, _, _) => throw new InvalidOperationException("No frame may be published."), _ => null);
    await watch.HandleAsync("phone", Device, "browser.watch", Message(new { window = "one", maxWidth = 600, quality = 70 }), null, default);
    Assert.Equal(0, captures);
    await Assert.ThrowsAsync<PhoneRefusal>(async () => await watch.HandleAsync("look", Device with { Access = PhoneAccess.Look }, "browser.watch", Message(new { window = "one", maxWidth = 600, quality = 70 }), null, default));
    Assert.Equal(0, captures);
  }
  private static JsonObject Frame() => new() { ["data"] = "AA==", ["w"] = 1, ["h"] = 1, ["dw"] = 1, ["dh"] = 1, ["scale"] = 1, ["offsetTop"] = 0, ["pageScale"] = 1, ["scrollX"] = 0, ["scrollY"] = 0 };
}
