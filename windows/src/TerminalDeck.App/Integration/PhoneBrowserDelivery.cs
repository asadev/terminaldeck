using TerminalDeck.Core.Remote;

namespace TerminalDeck.App.Integration;

public sealed partial class AppRuntime
{
  public ValueTask<string> DeliverPhoneBrowserScreenshotAsync(byte[] png, string note, string session, ApprovedDevice device, CancellationToken ct) => DeliverAnnotationAsync(png, note, session, device, ct);
}
