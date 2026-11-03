using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace TerminalDeck.App.Integration;

// Decode imported pictures through Windows' image codecs and normalize the wire
// to a small PNG. Neither an extension nor a MIME label is trusted as a codec.
public static class PhoneImageCodec
{
  private static readonly System.Collections.Concurrent.ConcurrentDictionary<string, (long Stamp, long Bytes, byte[] Png)> Cache = new(StringComparer.OrdinalIgnoreCase);
  public static async ValueTask<byte[]?> PngAsync(string path, CancellationToken ct)
  {
    try { return await DecodeAsync(path, ct); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException or ArgumentException) { return null; }
  }
  // Screenshots retain useful reading resolution, unlike the tiny project
  // avatars. Re-encode the supplied content and fit Hoot's keeper-pipe budget.
  public static async ValueTask<byte[]> AnnotationPngAsync(byte[] bytes, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested();
    if (bytes.Length is <= 0 or > 32 * 1024 * 1024) throw new InvalidOperationException("Choose a screenshot up to 32 MB.");
    using var input = new InMemoryRandomAccessStream();
    using (var writer = new DataWriter(input)) { writer.WriteBytes(bytes); await writer.StoreAsync(); writer.DetachStream(); }
    ct.ThrowIfCancellationRequested(); input.Seek(0);
    var decoder = await BitmapDecoder.CreateAsync(input);
    if (decoder.PixelWidth == 0 || decoder.PixelHeight == 0 || (ulong)decoder.PixelWidth * decoder.PixelHeight > 80_000_000) throw new InvalidOperationException("Choose a smaller screenshot.");
    foreach (var side in new uint[] { 2048, 1536, 1024, 768, 512 })
    {
      ct.ThrowIfCancellationRequested();
      var scale = Math.Min(1d, side / (double)Math.Max(decoder.PixelWidth, decoder.PixelHeight));
      var width = Math.Max(1u, (uint)(decoder.PixelWidth * scale)); var height = Math.Max(1u, (uint)(decoder.PixelHeight * scale));
      var pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
        new BitmapTransform { ScaledWidth = width, ScaledHeight = height }, ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.ColorManageToSRgb);
      ct.ThrowIfCancellationRequested();
      using var output = new InMemoryRandomAccessStream();
      var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output);
      encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, width, height, 96, 96, pixels.DetachPixelData()); await encoder.FlushAsync();
      ct.ThrowIfCancellationRequested();
      if (output.Size > 4 * 1024 * 1024) continue;
      var png = new byte[(int)output.Size]; output.Seek(0); using var reader = new DataReader(output); await reader.LoadAsync((uint)png.Length); reader.ReadBytes(png);
      ct.ThrowIfCancellationRequested(); return png;
    }
    throw new InvalidOperationException("This screenshot is too large to attach safely.");
  }
  private static async ValueTask<byte[]?> DecodeAsync(string path, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested();
    var info = new FileInfo(path);
    if (!info.Exists || info.Length is <= 0 or > 32 * 1024 * 1024) return null;
    if (Cache.TryGetValue(path, out var known) && known.Stamp == info.LastWriteTimeUtc.Ticks && known.Bytes == info.Length) return known.Png;
    await using var source = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 65536, true);
    using var input = new InMemoryRandomAccessStream();
    var bytes = new byte[source.Length]; await source.ReadExactlyAsync(bytes, ct);
    using (var writer = new DataWriter(input)) { writer.WriteBytes(bytes); await writer.StoreAsync(); writer.DetachStream(); }
    input.Seek(0);
    var decoder = await BitmapDecoder.CreateAsync(input);
    if ((ulong)decoder.PixelWidth * decoder.PixelHeight > 100_000_000) return null;
    // Dense/noisy photos can exceed one relay frame even at 128px. Reduce until
    // the PNG actually fits, rather than discarding an otherwise valid logo.
    foreach (var side in new uint[] { 256, 128, 64, 32 })
    {
      ct.ThrowIfCancellationRequested();
      var scale = Math.Min(1d, side / (double)Math.Max(decoder.PixelWidth, decoder.PixelHeight));
      var width = Math.Max(1u, (uint)(decoder.PixelWidth * scale)); var height = Math.Max(1u, (uint)(decoder.PixelHeight * scale));
      var pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied,
        new BitmapTransform { ScaledWidth = width, ScaledHeight = height }, ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.ColorManageToSRgb);
      using var output = new InMemoryRandomAccessStream();
      var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output);
      encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, width, height, 96, 96, pixels.DetachPixelData()); await encoder.FlushAsync();
      if (output.Size > 44000) continue;
      var png = new byte[(int)output.Size]; output.Seek(0); using var reader = new DataReader(output); await reader.LoadAsync((uint)png.Length); reader.ReadBytes(png);
      if (Cache.Count > 128) Cache.Clear(); Cache[path] = (info.LastWriteTimeUtc.Ticks, info.Length, png); return png;
    }
    return null;
  }
}
