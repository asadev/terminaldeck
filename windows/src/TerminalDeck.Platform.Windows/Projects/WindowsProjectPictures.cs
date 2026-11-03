using System.Text.RegularExpressions;
using TerminalDeck.Core.Projects;
using TerminalDeck.Core.Storage;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace TerminalDeck.Platform.Windows.Projects;

// Decode first, then save a small PNG owned by the data root. A source file is
// never retained as a project path and is never overwritten or deleted.
public sealed class WindowsProjectPictures(AppDataRoot root) : IProjectPictures
{
  private readonly string directory = Path.Combine(root.DirectoryPath, "project-logos");
  public string Adopt(string projectId, string source)
  {
    if (!ProjectIdentity.ValidId(projectId) || !Path.IsPathFullyQualified(source) || !File.Exists(source) || new FileInfo(source).Length is <= 0 or > 10 * 1024 * 1024)
      throw new ArgumentException("Choose an image file below 10 MB.");
    try { return Task.Run(() => AdoptAsync(projectId, source)).GetAwaiter().GetResult(); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { throw new ArgumentException("That picture could not be opened. Choose a PNG, JPEG or another supported image below 10 MB."); }
  }
  private async Task<string> AdoptAsync(string id, string source)
  {
    using var input = new InMemoryRandomAccessStream();
    using (var writer = new DataWriter(input.GetOutputStreamAt(0)))
    {
      writer.WriteBytes(await File.ReadAllBytesAsync(source)); await writer.StoreAsync(); await writer.FlushAsync(); writer.DetachStream();
    }
    var decoder = await BitmapDecoder.CreateAsync(input);
    if (decoder.PixelWidth is 0 or > 8192 || decoder.PixelHeight is 0 or > 8192) throw new ArgumentException("Choose an image up to 8192 pixels across.");
    var factor = Math.Min(1, 256.0 / Math.Max(decoder.OrientedPixelWidth, decoder.OrientedPixelHeight));
    var width = (uint)Math.Max(1, Math.Round(decoder.OrientedPixelWidth * factor));
    var height = (uint)Math.Max(1, Math.Round(decoder.OrientedPixelHeight * factor));
    var pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight,
      new BitmapTransform { ScaledWidth = width, ScaledHeight = height, InterpolationMode = BitmapInterpolationMode.Fant },
      ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);
    using var output = new InMemoryRandomAccessStream();
    var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output);
    encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight, width, height, 96, 96, pixels.DetachPixelData());
    await encoder.FlushAsync();
    using var reader = new DataReader(output.GetInputStreamAt(0));
    await reader.LoadAsync((uint)output.Size); var bytes = new byte[checked((int)output.Size)]; reader.ReadBytes(bytes);
    Directory.CreateDirectory(directory);
    if (new DirectoryInfo(directory).LinkTarget is not null) throw new IOException("The picture folder must be inside the app data folder.");
    var name = id + "-" + Guid.NewGuid().ToString("N") + ".png";
    using var file = new FileStream(Path.Combine(directory, name), FileMode.CreateNew, FileAccess.Write, FileShare.Read);
    await file.WriteAsync(bytes); file.Flush(true); return name;
  }
  public string? PathFor(string name) => Safe(name) && File.Exists(Path.Combine(directory, name)) ? Path.Combine(directory, name) : null;
  public void Discard(string name) { if (Safe(name)) File.Delete(Path.Combine(directory, name)); }
  private static bool Safe(string name) => Regex.IsMatch(name, "^[a-z0-9-]{1,170}\\.png$", RegexOptions.CultureInvariant);
}
