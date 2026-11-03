using System.Text.Json;
using System.Text.Json.Nodes;
using TerminalDeck.Core.Remote;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace TerminalDeck.App.Views;

public sealed partial class BrowserPane
{
  public (bool Recording, bool Loading) PhoneBrowserStatus(string id)
  {
    var tab = tabs.FirstOrDefault(t => t.Id == id);
    return (tab?.Recording == true, tab?.Loading == true);
  }

  // Call on WinUI's thread. CaptureAsync already masks secret fields in an
  // isolated world and verifies its privacy fingerprint before returning pixels.
  public async ValueTask<JsonObject> CapturePhoneFrameAsync(string id, int maxWidth, int quality, CancellationToken ct)
  {
    ct.ThrowIfCancellationRequested();
    var tab = tabs.FirstOrDefault(t => t.Id == id) ?? throw new PhoneRefusal("unavailable", "That browser window closed.");
    var geometry = await tab.Model.CommandAsync("Runtime.evaluate", new { expression = "({dw:innerWidth,dh:innerHeight,x:scrollX,y:scrollY})", returnByValue = true });
    var viewport = geometry.GetProperty("result").GetProperty("value");
    var dw = Math.Max(1, viewport.GetProperty("dw").GetInt32()); var dh = Math.Max(1, viewport.GetProperty("dh").GetInt32());
    var png = await CaptureAsync(tab); ct.ThrowIfCancellationRequested();
    using var source = new InMemoryRandomAccessStream();
    using (var writer = new DataWriter(source.GetOutputStreamAt(0))) { writer.WriteBytes(png); await writer.StoreAsync(); await writer.FlushAsync(); }
    var decoder = await BitmapDecoder.CreateAsync(source);
    using var bitmap = await decoder.GetSoftwareBitmapAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore);
    var width = (uint)Math.Min(Math.Clamp(maxWidth, 160, 1920), bitmap.PixelWidth);
    var height = (uint)Math.Max(1, Math.Round(bitmap.PixelHeight * (double)width / bitmap.PixelWidth));
    byte[] jpeg = [];
    for (var attempt = 0; attempt < 4; attempt++)
    {
      using var target = new InMemoryRandomAccessStream();
      var options = new BitmapPropertySet { { "ImageQuality", new BitmapTypedValue(Math.Clamp(quality - attempt * 15, 10, 95) / 100f, global::Windows.Foundation.PropertyType.Single) } };
      var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, target, options); encoder.SetSoftwareBitmap(bitmap);
      encoder.BitmapTransform.ScaledWidth = width; encoder.BitmapTransform.ScaledHeight = height; encoder.BitmapTransform.InterpolationMode = BitmapInterpolationMode.Fant;
      await encoder.FlushAsync();
      if (target.Size <= 44000)
      {
        jpeg = new byte[(int)target.Size]; using var reader = new DataReader(target.GetInputStreamAt(0)); await reader.LoadAsync((uint)jpeg.Length); reader.ReadBytes(jpeg); break;
      }
      width = Math.Max(160, width * 3 / 4); height = (uint)Math.Max(1, Math.Round(bitmap.PixelHeight * (double)width / bitmap.PixelWidth));
    }
    if (jpeg.Length == 0) throw new PhoneRefusal("unavailable", "This browser preview is too large to send safely.");
    return new JsonObject { ["w"] = (int)width, ["h"] = (int)height, ["dw"] = dw, ["dh"] = dh, ["scale"] = (double)width / dw,
      ["offsetTop"] = 0, ["pageScale"] = 1, ["scrollX"] = viewport.GetProperty("x").GetDouble(), ["scrollY"] = viewport.GetProperty("y").GetDouble(), ["data"] = Convert.ToBase64String(jpeg) };
  }
}
