using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;

namespace TerminalDeck.App.Views.Chat;

public sealed record PreparedChatImage(string Name, string MimeType, byte[] Bytes, int Width, int Height);
public static class ChatImageScaler
{
  public static async Task<PreparedChatImage> PrepareAsync(StorageFile file)
  {
    var properties = await file.GetBasicPropertiesAsync();
    if (file.FileType.Equals(".pdf", StringComparison.OrdinalIgnoreCase))
    {
      if (properties.Size is < 5 or > 500000) throw new InvalidOperationException("Choose a PDF up to 500 KB.");
      using var pdf = await file.OpenReadAsync(); if (pdf.Size is < 5 or > 500000) throw new InvalidOperationException("The PDF changed size. Choose a PDF up to 500 KB."); using var pdfReader = new DataReader(pdf.GetInputStreamAt(0)); await pdfReader.LoadAsync((uint)pdf.Size); var pdfBytes = new byte[(int)pdf.Size]; pdfReader.ReadBytes(pdfBytes);
      if (!pdfBytes.AsSpan(0, 5).SequenceEqual("%PDF-"u8)) throw new InvalidOperationException("This file is not a readable PDF.");
      return new(file.Name, "application/pdf", pdfBytes, 0, 0);
    }
    if (properties.Size > 32 * 1024 * 1024) throw new InvalidOperationException("Choose an image smaller than 32 MB.");
    using var input = await file.OpenReadAsync(); var decoder = await BitmapDecoder.CreateAsync(input);
    if ((long)decoder.PixelWidth * decoder.PixelHeight > 80_000_000) throw new InvalidOperationException("Choose a smaller image.");
    if (!decoder.DecoderInformation.FileExtensions.Any(e => new[] { ".png", ".jpg", ".jpeg", ".gif", ".webp" }.Contains(e, StringComparer.OrdinalIgnoreCase))) throw new InvalidOperationException("Choose a PNG, JPEG, GIF or WebP image supported by Windows.");
    var scale = Math.Min(1d, 2048d / Math.Max(decoder.PixelWidth, decoder.PixelHeight));
    var width = Math.Max(1, (uint)Math.Round(decoder.PixelWidth * scale)); var height = Math.Max(1, (uint)Math.Round(decoder.PixelHeight * scale));
    var pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, new BitmapTransform { ScaledWidth = width, ScaledHeight = height }, ExifOrientationMode.RespectExifOrientation, ColorManagementMode.DoNotColorManage);
    if (decoder.OrientedPixelWidth != decoder.PixelWidth) (width, height) = (height, width);
    using var output = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output);
    encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, width, height, 96, 96, pixels.DetachPixelData()); await encoder.FlushAsync();
    if (output.Size > 8 * 1024 * 1024) throw new InvalidOperationException("This image is still larger than 8 MB after resizing. Choose a smaller image.");
    output.Seek(0); using var reader = new DataReader(output.GetInputStreamAt(0)); var count = (uint)output.Size;
    await reader.LoadAsync(count); var bytes = new byte[count]; reader.ReadBytes(bytes);
    return new(file.Name, "image/png", bytes, (int)width, (int)height);
  }
  public static async Task<PreparedChatImage> PrepareClipboardAsync(RandomAccessStreamReference reference)
  {
    using var input = await reference.OpenReadAsync();
    if (input.Size > 32 * 1024 * 1024) throw new InvalidOperationException("Choose an image smaller than 32 MB.");
    var decoder = await BitmapDecoder.CreateAsync(input);
    if ((long)decoder.PixelWidth * decoder.PixelHeight > 80_000_000) throw new InvalidOperationException("Choose a smaller image.");
    var scale = Math.Min(1d, 2048d / Math.Max(decoder.PixelWidth, decoder.PixelHeight));
    var width = Math.Max(1, (uint)Math.Round(decoder.PixelWidth * scale)); var height = Math.Max(1, (uint)Math.Round(decoder.PixelHeight * scale));
    var transform = new BitmapTransform { ScaledWidth = width, ScaledHeight = height };
    var pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, transform, ExifOrientationMode.RespectExifOrientation, ColorManagementMode.DoNotColorManage);
    if (decoder.OrientedPixelWidth != decoder.PixelWidth) (width, height) = (height, width);
    using var output = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output);
    encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, width, height, 96, 96, pixels.DetachPixelData()); await encoder.FlushAsync();
    if (output.Size > 8 * 1024 * 1024) throw new InvalidOperationException("This image is still larger than 8 MB after resizing. Choose a smaller image.");
    output.Seek(0); using var reader = new DataReader(output.GetInputStreamAt(0)); await reader.LoadAsync((uint)output.Size); var bytes = new byte[(int)output.Size]; reader.ReadBytes(bytes);
    return new("Pasted image.png", "image/png", bytes, (int)width, (int)height);
  }

}
