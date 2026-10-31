using System.Collections.Immutable;
using TerminalDeck.Core.Receiver;
using Windows.ApplicationModel.DataTransfer;
using Windows.ApplicationModel.DataTransfer.ShareTarget;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;

namespace TerminalDeck.Platform.Windows.Receiver;

public sealed class WindowsReceiverData(IReceiver receiver, ReceiverFiles files)
{
  private readonly SemaphoreSlim intake = new(1, 1);
  public async Task<ReceiverItem> ReadAsync(DataPackageView data, string sourceId, string title, CancellationToken ct = default)
  {
    await intake.WaitAsync(ct);
    try
    {
      // Reclaim dismissed copies and interrupted imports before accepting new
      // files. Serialize the whole intake so another share's pending copy is
      // never mistaken for an abandoned import. Originals are never removed.
      files.RemoveUnreferenced(receiver.Items(limit: 1000).Where(i => i.Status != InboxStatus.Ignored));
      return await ReadCoreAsync(data, sourceId, title, ct);
    }
    finally { intake.Release(); }
  }
  private async Task<ReceiverItem> ReadCoreAsync(DataPackageView data, string sourceId, string title, CancellationToken ct)
  {
    var attachments = ImmutableArray.CreateBuilder<ReceiverFile>();
    var text = data.Contains(StandardDataFormats.Text) ? await data.GetTextAsync() : "";
    string? url = data.Contains(StandardDataFormats.WebLink) ? (await data.GetWebLinkAsync()).AbsoluteUri : null;
    if (data.Contains(StandardDataFormats.StorageItems))
    {
      var items = await data.GetStorageItemsAsync();
      if (items.Count > 16 || items.Any(i => i is not StorageFile)) throw new ArgumentException("Share up to 16 files. Folders cannot be added to the inbox.");
      foreach (var item in items.Cast<StorageFile>())
      {
        ct.ThrowIfCancellationRequested();
        using var stream = await item.OpenStreamForReadAsync(); attachments.Add(await files.ImportAsync(stream, item.Name, item.ContentType, ct));
      }
    }
    else if (data.Contains(StandardDataFormats.Bitmap))
    {
      using var bitmap = await (await data.GetBitmapAsync()).OpenReadAsync();
      var decoder = await BitmapDecoder.CreateAsync(bitmap);
      if ((long)decoder.PixelWidth * decoder.PixelHeight > 40_000_000) throw new IOException("This screenshot is too large to receive.");
      using var pixels = await decoder.GetSoftwareBitmapAsync();
      using var encoded = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, encoded);
      encoder.SetSoftwareBitmap(pixels); await encoder.FlushAsync(); encoded.Seek(0);
      using var stream = encoded.AsStreamForRead(); attachments.Add(await files.ImportAsync(stream, "Screenshot.png", "image/png", ct));
    }
    if (text.Length == 0 && url is null && attachments.Count == 0) throw new ArgumentException("Share text, a link, a screenshot or files.");
    return receiver.Receive(new(sourceId, string.IsNullOrWhiteSpace(data.Properties.Title) ? title : data.Properties.Title, text, url, attachments.ToImmutable()));
  }
  public async Task<ReceiverItem?> ShareAsync(ShareOperation share, string sourceId, CancellationToken ct = default)
  {
    share.ReportStarted();
    try { var item = await ReadAsync(share.Data, sourceId, "Shared to " + TerminalDeck.Core.Brand.Name, ct); share.ReportCompleted(); return item; }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      share.ReportError("The item could not be saved. Open Receiver and check its source and inbox limits."); return null;
    }
  }
}
