using Microsoft.UI.Dispatching;
using TerminalDeck.Core.Remote;
using Windows.ApplicationModel.DataTransfer;

namespace TerminalDeck.App.Integration;

public sealed partial class OtherComputersService
{
  private readonly DispatcherQueue? clipboardQueue = DispatcherQueue.GetForCurrentThread();
  public PhoneClipboardFeatures CreateClipboardFeature() => new(ct => ClipboardUiAsync(async () =>
  {
    var clipboard = Clipboard.GetContent();
    return clipboard.Contains(StandardDataFormats.Text) ? await clipboard.GetTextAsync() : "";
  }, ct), (text, ct) => ClipboardUiAsync(() =>
  {
    var data = new DataPackage(); data.SetText(text); Clipboard.SetContent(data); return Task.FromResult(true);
  }, ct));
  private Task<T> ClipboardUiAsync<T>(Func<Task<T>> action, CancellationToken ct)
  {
    var result = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
    if (clipboardQueue is null || !clipboardQueue.TryEnqueue(async () =>
    {
      try { ct.ThrowIfCancellationRequested(); result.TrySetResult(await action()); }
      catch (Exception ex) when (ex is not OutOfMemoryException) { result.TrySetException(ex); }
    })) result.TrySetException(new InvalidOperationException("The desktop clipboard is not available."));
    return result.Task.WaitAsync(ct);
  }
  public async Task<string> ReadClipboardAsync(string id, CancellationToken ct = default)
  {
    var reply = await RequestAsync(id, "clipboard", "clipboard.read", new(), ["clipboard.reading"], ct);
    var text = Text(reply, "text", ""); if (text.Length > 16000) throw new IOException("The remote clipboard is too large.");
    return text;
  }
  public async Task WriteClipboardAsync(string id, string text, CancellationToken ct = default)
  {
    if (text.Length > 16000) throw new ArgumentException("Copy up to 16,000 characters at once.");
    await RequestAsync(id, "clipboard", "clipboard.write", new() { ["text"] = text }, ["clipboard.written"], ct);
  }
}
