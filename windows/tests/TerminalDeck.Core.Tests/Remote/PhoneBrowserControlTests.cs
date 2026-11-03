using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class PhoneBrowserControlTests
{
  [Fact] public async Task InputRequiresAnActualFrameAndUsesItsCapturedScale()
  {
    var device = new ApprovedDevice("synthetic", "Synthetic phone", "ios", PhoneAccess.Full);
    var frames = Channel.CreateUnbounded<JsonObject>(); JsonElement dispatched = default;
    using var host = new PhoneBrowserWatchFeatures((_, _) => true,
      (_, _, _, _) => ValueTask.FromResult(new JsonObject { ["data"] = "AA==", ["w"] = 320, ["h"] = 200, ["dw"] = 640, ["dh"] = 400, ["scale"] = 0.5 }), _ => [],
      (_, _, type, message, _) => { if (type == "browser.input") dispatched = message.Clone(); return ValueTask.FromResult(new JsonObject()); });
    host.Bind((_, frame, _) => { frames.Writer.TryWrite(frame); return ValueTask.CompletedTask; }, _ => device);
    var input = JsonSerializer.SerializeToElement(new { window = "synthetic-window", seq = 1, mouse = new { type = "down", x = 160, y = 100, button = "left" } });
    await Assert.ThrowsAsync<PhoneRefusal>(async () => await host.HandleAsync("synthetic-channel", device, "browser.input", input, null, default));
    await host.HandleAsync("synthetic-channel", device, "browser.watch", JsonSerializer.SerializeToElement(new { window = "synthetic-window", maxWidth = 320, quality = 70 }), null, default);
    await frames.Reader.ReadAsync().AsTask().WaitAsync(TimeSpan.FromSeconds(5));
    await host.HandleAsync("synthetic-channel", device, "browser.input", input, null, default);
    Assert.Equal(320, dispatched.GetProperty("mouse").GetProperty("x").GetDouble());
    Assert.Equal(200, dispatched.GetProperty("mouse").GetProperty("y").GetDouble());
    var stale = JsonSerializer.SerializeToElement(new { window = "synthetic-window", seq = 99, paste = "text" });
    await Assert.ThrowsAsync<PhoneRefusal>(async () => await host.HandleAsync("synthetic-channel", device, "browser.input", stale, null, default));
    await host.DisconnectedAsync("synthetic-channel");
  }
}
