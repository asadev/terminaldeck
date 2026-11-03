using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using TerminalDeck.Core.Computers;
using TerminalDeck.App.Integration;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace TerminalDeck.App.Views.Computers;

public sealed partial class ComputerScreenWindow
{
  // Contract §11.7: the screen arrives as H.264 on the direct link (sims.video). The bounded queue, the viewer rules and
  // the decoder (Media Foundation) run off the UI thread in ComputerVideoPipeline; the newest picture is drawn here.
  private ComputerVideoPipeline pipeline = null!;
  private int pictureWidth, pictureHeight;
  private readonly SemaphoreSlim receiveGate = new(1, 1);
  private readonly Grid imageSurface = new() { HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
  private readonly Canvas pointerLayer = new() { IsHitTestVisible = false };
  private readonly Image remoteCursor = new() { IsHitTestVisible = false, Visibility = Visibility.Collapsed };
  private WriteableBitmap? canvas;
  private bool actualSize;
  private int screenEpoch;
  private long pointerNumber = -1;
  private (double X, double Y, double HotX, double HotY, double Width, double Height)? remotePointer;
  private void ResetScreenEpoch()
  {
    Interlocked.Increment(ref screenEpoch); canvas = null; picture.Source = null; pictureWidth = pictureHeight = 0;
    remoteCursor.Visibility = Visibility.Collapsed; remotePointer = null; pointerNumber = -1; 
  }
  private double ActualPixelScale() => 1 / Math.Max(0.25, picture.XamlRoot?.RasterizationScale ?? 1);
  private void UpdatePictureLayout()
  {
    var width = actualSize && pictureWidth > 0 ? pictureWidth * ActualPixelScale() : Math.Max(1, scroll.ViewportWidth > 0 ? scroll.ViewportWidth : scroll.ActualWidth);
    var height = actualSize && pictureHeight > 0 ? pictureHeight * ActualPixelScale() : Math.Max(1, scroll.ViewportHeight > 0 ? scroll.ViewportHeight : scroll.ActualHeight);
    picture.Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform;
    imageSurface.Width = picture.Width = width; imageSurface.Height = picture.Height = height;
    pointerLayer.Width = width; pointerLayer.Height = height; DrawRemoteCursor();
  }
  private void FollowPointer(double x, double y)
  {
    if (!actualSize || pictureWidth == 0) return;
    var next = ComputerViewport.Follow(x, y, picture.Width, picture.Height, scroll.ViewportWidth, scroll.ViewportHeight, scroll.HorizontalOffset, scroll.VerticalOffset);
    if (Math.Abs(next.X - scroll.HorizontalOffset) > 0.5 || Math.Abs(next.Y - scroll.VerticalOffset) > 0.5) scroll.ChangeView(next.X, next.Y, null, true);
  }
  private void DrawRemoteCursor()
  {
    if (remotePointer is not { } pointer || pictureWidth == 0 || remoteCursor.Source is null) { remoteCursor.Visibility = Visibility.Collapsed; return; }
    var scale = actualSize ? ActualPixelScale() : Math.Min(picture.Width / pictureWidth, picture.Height / pictureHeight);
    var width = pointer.Width * pictureWidth * scale; var height = pointer.Height * pictureHeight * scale;
    remoteCursor.Width = Math.Max(1, width); remoteCursor.Height = Math.Max(1, height);
    Canvas.SetLeft(remoteCursor, (picture.Width - pictureWidth * scale) / 2 + pointer.X * pictureWidth * scale - pointer.HotX * width);
    Canvas.SetTop(remoteCursor, (picture.Height - pictureHeight * scale) / 2 + pointer.Y * pictureHeight * scale - pointer.HotY * height);
    remoteCursor.Visibility = Visibility.Visible;
  }
  private void Received(string machine, JsonElement frame)
  {
    if (machine != computer.Id || closed) return;
    var epoch = Volatile.Read(ref screenEpoch);
    window.DispatcherQueue.TryEnqueue(async () =>
    {
      await receiveGate.WaitAsync();
      try
      {
        if (closed || paused || epoch != Volatile.Read(ref screenEpoch)) return;
        var type = frame.GetProperty("t").GetString();
        if (type == "sims.rows" && recovering)
        {
          var current = service.List().FirstOrDefault(c => c.Id == computer.Id);
          if (current?.Displays.Any(d => OtherComputersService.Text(d, "id", "") == display) == true) { recovering = false; await WatchAsync(); }
          else status.Text = "This display is no longer shared. Choose a currently shared display in Other computers.";
          return;
        }
        if (OtherComputersService.Text(frame, "id", "") == display && type == "sims.state" && OtherComputersService.Text(frame, "state", "") == "ended")
        { status.Text = OtherComputersService.Text(frame, "note", "The screen stopped."); return; }
        if (OtherComputersService.Text(frame, "id", "") == display && type == "sims.pointer") { await ApplyPointerAsync(frame, epoch); return; }
        if (type == "sims.state" && OtherComputersService.Text(frame, "id", "") == display) status.Text = OtherComputersService.Text(frame, "note", OtherComputersService.Text(frame, "state", ""));
        else if (type == "error") status.Text = OtherComputersService.Text(frame, "message", "That computer refused the action.");
      }
      catch (Exception ex) when (ex is not OutOfMemoryException)
      { if (!closed && epoch == Volatile.Read(ref screenEpoch)) { status.Text = "Recovering the complete screen…"; await SendAsync(new { t = "sims.key", id = display }); } }
      finally { receiveGate.Release(); }
    });
  }
  // A sims.video for this display: into the pipeline's bounded queue (a full queue makes it catch up), never decoded on
  // the UI thread.
  private void ReceivedVideo(JsonElement frame)
  {
    if (OtherComputersService.Text(frame, "id", "") != display || closed || paused) return;
    pipeline.Offer(frame, Volatile.Read(ref screenEpoch));
  }

  // From the decoding loop (not the UI thread): a failed send only shows on the next picture or state.
  private async Task QuietSendAsync(object message)
  {
    try { await service.SendAsync(computer.Id, message); }
    catch (Exception ex) when (ex is not OutOfMemoryException) { }
  }

  private void Show(ComputerVideoPicture shown, int epoch)
  {
    if (closed || paused || epoch != Volatile.Read(ref screenEpoch)) return;
    pictureWidth = shown.Width; pictureHeight = shown.Height;
    if (canvas is null || canvas.PixelWidth != shown.Width || canvas.PixelHeight != shown.Height) canvas = new(shown.Width, shown.Height);
    using (var target = canvas.PixelBuffer.AsStream()) { target.Position = 0; target.Write(shown.Bgra); }
    canvas.Invalidate(); picture.Source = canvas; UpdatePictureLayout();
    status.Text = "Live · " + computer.Name + (service.LinkRoute(computer.Id) is { } route ? " · " + (route == "turn" ? "via Cloudflare" : "direct") : "");
  }

  private async Task ApplyPointerAsync(JsonElement frame, int epoch)
  {
    static double Unit(JsonElement root, string key, double fallback = 0) => root.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetDouble(out var n) && double.IsFinite(n) ? Math.Clamp(n, 0, 1) : fallback;
    var n = frame.TryGetProperty("n", out var number) && number.ValueKind == JsonValueKind.Number && number.TryGetInt64(out var sequence) ? sequence : 0;
    if (n < pointerNumber) return; pointerNumber = n;
    if (frame.TryGetProperty("off", out var off) && off.ValueKind == JsonValueKind.True) { remotePointer = null; remoteCursor.Visibility = Visibility.Collapsed; return; }
    var previous = remotePointer;
    remotePointer = (Unit(frame, "x"), Unit(frame, "y"), Unit(frame, "hx", previous?.HotX ?? 0), Unit(frame, "hy", previous?.HotY ?? 0),
      Unit(frame, "cw", previous?.Width ?? 0.01), Unit(frame, "ch", previous?.Height ?? 0.02));
    if (frame.TryGetProperty("img", out var image) && image.ValueKind == JsonValueKind.String && image.GetString() is { Length: > 0 and <= 400000 } encoded)
    {
      using var source = await PictureStreamAsync(Convert.FromBase64String(encoded));
      var geometry = await BitmapDecoder.CreateAsync(source); if (geometry.PixelWidth is < 1 or > 512 || geometry.PixelHeight is < 1 or > 512) throw new InvalidOperationException("The remote cursor is outside its bounds.");
      source.Seek(0); var cursor = new BitmapImage(); await cursor.SetSourceAsync(source);
      if (closed || epoch != Volatile.Read(ref screenEpoch)) return; remoteCursor.Source = cursor;
    }
    DrawRemoteCursor(); if (remotePointer is { } at) FollowPointer(at.X, at.Y);
  }
  private static async Task<InMemoryRandomAccessStream> PictureStreamAsync(byte[] bytes)
  {
    var stream = new InMemoryRandomAccessStream();
    try { using (var writer = new DataWriter(stream)) { writer.WriteBytes(bytes); await writer.StoreAsync(); writer.DetachStream(); } stream.Seek(0); return stream; }
    catch { stream.Dispose(); throw; }
  }
}
