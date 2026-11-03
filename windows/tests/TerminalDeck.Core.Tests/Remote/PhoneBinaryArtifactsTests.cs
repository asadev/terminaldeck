using System.Net;
using System.Net.Http.Headers;
using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Remote;
using TerminalDeck.Core.Storage;

namespace TerminalDeck.Core.Tests.Remote;

public sealed class PhoneBinaryArtifactsTests : IDisposable
{
  private readonly string directory = Path.Combine(OperatingSystem.IsMacOS() ? "/private/tmp" : Path.GetTempPath(), "td-phone-output-" + Guid.NewGuid().ToString("N"));
  [Fact] public async Task BinaryPreviewUsesPhoneTokenPathSupportsRangesAndRetiresOnGrantRemoval()
  {
    var folder = Directory.CreateDirectory(Path.Combine(directory, "project")).FullName;
    var root = AppDataRoot.Explicit(Path.Combine(directory, "data"));
    var payload = Enumerable.Range(0, 100000).Select(i => (byte)(i % 251)).ToArray();
    await File.WriteAllBytesAsync(Path.Combine(folder, "movie.mp4"), payload);
    var artifacts = new ReceiverArtifacts(new JsonStateStore<ReceiverArtifactState>(root, "artifacts"), _ => "project",
      (_, _) => ValueTask.CompletedTask, (_, _, _) => ValueTask.CompletedTask);
    artifacts.Record(folder, "movie.mp4", "session", DateTimeOffset.UtcNow);
    var allowed = true;
    using var server = new PhoneArtifactServer(artifacts, (device, cwd) => allowed && device == "phone" && cwd == folder);
    var handle = server.Serve("phone", folder, "movie.mp4");
    Assert.Equal(100000, handle.Bytes); Assert.Equal("media", handle.Kind);
    var address = $"http://127.0.0.1:{handle.Port}/{handle.Secret}/~/{Uri.EscapeDataString(handle.Token)}";
    using var http = new HttpClient(); using var request = new HttpRequestMessage(HttpMethod.Get, address); request.Headers.Range = new RangeHeaderValue(256, 511);
    using var response = await http.SendAsync(request); Assert.Equal(HttpStatusCode.PartialContent, response.StatusCode);
    Assert.Equal(payload[256..512], await response.Content.ReadAsByteArrayAsync());
    Assert.Equal(payload, await http.GetByteArrayAsync(address));
    allowed = false; using var denied = await http.GetAsync(address); Assert.Equal(HttpStatusCode.NotFound, denied.StatusCode);
    allowed = true; server.Forget("phone"); using var retired = await http.GetAsync(address); Assert.Equal(HttpStatusCode.NotFound, retired.StatusCode);
  }
  [Fact] public async Task ServingRejectsUnindexedFilesAndCancelledClientDoesNotBreakNextRead()
  {
    var folder = Directory.CreateDirectory(Path.Combine(directory, "project")).FullName;
    var root = AppDataRoot.Explicit(Path.Combine(directory, "data")); await File.WriteAllTextAsync(Path.Combine(folder, "page.html"), "<h1>Output</h1>");
    var artifacts = new ReceiverArtifacts(new JsonStateStore<ReceiverArtifactState>(root, "artifacts"), _ => "project", (_, _) => ValueTask.CompletedTask, (_, _, _) => ValueTask.CompletedTask);
    using var server = new PhoneArtifactServer(artifacts, (_, _) => true);
    Assert.Throws<ArgumentException>(() => server.Serve("phone", folder, "page.html"));
    artifacts.Record(folder, "page.html", "session", DateTimeOffset.UtcNow); var handle = server.Serve("phone", folder, "page.html");
    using var http = new HttpClient(); using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
    var address = $"http://127.0.0.1:{handle.Port}/{handle.Secret}/~/{Uri.EscapeDataString(handle.Token)}";
    await Assert.ThrowsAnyAsync<OperationCanceledException>(() => http.GetAsync(address, cancelled.Token));
    Assert.Equal("<h1>Output</h1>", await http.GetStringAsync(address));
  }
  public void Dispose() { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
}
