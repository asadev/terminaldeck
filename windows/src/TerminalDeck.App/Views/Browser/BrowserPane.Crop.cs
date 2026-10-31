using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace TerminalDeck.App.Views;

public sealed partial class BrowserPane
{
  private async Task<string?> CropAsync(BrowserTab tab, string original)
  {
    var bytes = await File.ReadAllBytesAsync(original);
    using var input = new InMemoryRandomAccessStream();
    using (var writer = new DataWriter(input.GetOutputStreamAt(0))) { writer.WriteBytes(bytes); await writer.StoreAsync(); }
    input.Seek(0); var decoder = await BitmapDecoder.CreateAsync(input);
    var content = new StackPanel { Spacing = 12 };
    var left = new NumberBox { Header = "Left", Minimum = 0, Maximum = decoder.PixelWidth - 1, Value = 0 };
    var top = new NumberBox { Header = "Top", Minimum = 0, Maximum = decoder.PixelHeight - 1, Value = 0 };
    var width = new NumberBox { Header = "Width", Minimum = 1, Maximum = decoder.PixelWidth, Value = decoder.PixelWidth };
    var height = new NumberBox { Header = "Height", Minimum = 1, Maximum = decoder.PixelHeight, Value = decoder.PixelHeight };
    foreach (var field in new[] { left, top, width, height }) content.Children.Add(field);
    var dimensions = new TextBlock { Text = $"{decoder.PixelWidth} × {decoder.PixelHeight}" }; content.Children.Add(dimensions);
    content.Children.Add(TextAction("Full image", () => { left.Value = top.Value = 0; width.Value = decoder.PixelWidth; height.Value = decoder.PixelHeight; }));
    var dialog = new ContentDialog { XamlRoot = RootFor(tab), RequestedTheme = tab.View.ActualTheme, Title = "Crop picture", Content = content, PrimaryButtonText = "Done", CloseButtonText = "Cancel" };
    void Validate()
    {
      var valid = new[] { left.Value, top.Value, width.Value, height.Value }.All(double.IsFinite) && left.Value >= 0 && top.Value >= 0 && width.Value >= 1 && height.Value >= 1 && left.Value + width.Value <= decoder.PixelWidth && top.Value + height.Value <= decoder.PixelHeight;
      dialog.IsPrimaryButtonEnabled = valid; dimensions.Text = valid ? $"{(int)width.Value} × {(int)height.Value}" : "Keep the crop inside the picture.";
    }
    foreach (var field in new[] { left, top, width, height }) field.ValueChanged += (_, _) => Validate();
    string? result = null;
    dialog.PrimaryButtonClick += async (_, args) =>
    {
      var pending = args.GetDeferral();
      try
      {
        Validate(); if (!dialog.IsPrimaryButtonEnabled) { args.Cancel = true; return; }
        var transform = new BitmapTransform { Bounds = new BitmapBounds { X = (uint)left.Value, Y = (uint)top.Value, Width = (uint)width.Value, Height = (uint)height.Value } };
        var pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, transform, ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
        using var output = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output);
        encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)width.Value, (uint)height.Value, 96, 96, pixels.DetachPixelData()); await encoder.FlushAsync();
        var encoded = new byte[checked((int)output.Size)]; using (var reader = new DataReader(output.GetInputStreamAt(0))) { await reader.LoadAsync((uint)output.Size); reader.ReadBytes(encoded); }
        result = Path.Combine(Path.GetDirectoryName(original)!, "crop-" + DateTimeOffset.UtcNow.ToString("yyyyMMddTHHmmssfff") + ".png"); await File.WriteAllBytesAsync(result, encoded);
      }
      catch (Exception error) when (error is not OutOfMemoryException) { args.Cancel = true; dimensions.Text = "The crop could not be saved. Your original picture is kept."; }
      finally { pending.Complete(); }
    };
    return await dialog.ShowAsync() == ContentDialogResult.Primary ? result : null;
  }
}
