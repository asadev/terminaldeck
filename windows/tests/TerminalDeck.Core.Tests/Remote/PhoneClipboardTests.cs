using System.Text.Json;
using TerminalDeck.Core.Remote;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class PhoneClipboardTests
{
  [Fact] public async Task OnlyFullExplicitRequestsCanReadOrReplaceText()
  {
    var content = "synthetic clipboard"; var reads = 0; var writes = 0;
    var feature = new PhoneClipboardFeatures(_ => { reads++; return Task.FromResult(content); }, (text, _) => { writes++; content = text; return Task.CompletedTask; });
    var full = new ApprovedDevice("synthetic", "Synthetic computer", "win32", PhoneAccess.Full);
    using var request = JsonDocument.Parse("{\"text\":\"مرحبا 😀\"}");
    var reading = Assert.Single(await feature.HandleAsync("synthetic-channel", full, "clipboard.read", request.RootElement, "request-1", default));
    Assert.Equal("synthetic clipboard", reading["text"]!.GetValue<string>());
    await feature.HandleAsync("synthetic-channel", full, "clipboard.write", request.RootElement, "request-2", default);
    Assert.Equal("مرحبا 😀", content); Assert.Equal(1, reads); Assert.Equal(1, writes);
    await Assert.ThrowsAsync<PhoneRefusal>(async () => await feature.HandleAsync("synthetic-channel", full with { Access = PhoneAccess.Work }, "clipboard.read", request.RootElement, "request-3", default));
    Assert.Equal(1, reads);
  }
  [Fact] public async Task OversizeAndUncorrelatedWritesNeverTouchTheClipboard()
  {
    var writes = 0;
    var feature = new PhoneClipboardFeatures(_ => Task.FromResult(""), (_, _) => { writes++; return Task.CompletedTask; });
    var device = new ApprovedDevice("synthetic", "Synthetic computer", "win32", PhoneAccess.Full);
    var large = JsonSerializer.SerializeToElement(new { text = new string('x', 16001) });
    await Assert.ThrowsAsync<PhoneRefusal>(async () => await feature.HandleAsync("synthetic-channel", device, "clipboard.write", large, "request", default));
    var small = JsonSerializer.SerializeToElement(new { text = "hello" });
    await Assert.ThrowsAsync<PhoneRefusal>(async () => await feature.HandleAsync("synthetic-channel", device, "clipboard.write", small, null, default));
    Assert.Equal(0, writes);
  }
}
