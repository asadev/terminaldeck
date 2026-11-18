using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Animation;
using Microsoft.UI.Xaml.Markup;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Cloud;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.Storage.Streams;
using System.Runtime.InteropServices.WindowsRuntime;

namespace TerminalDeck.App.Views.Settings;

public sealed partial class ProfilePage
{
  private FrameworkElement PhotoButton(PersonPicture picture, CloudProfile profile)
  {
    var grid = new Grid { Width = 96, Height = 96 };
    grid.Children.Add(picture);
    var hint = new Grid { Width = 96, Height = 96, Opacity = 0 };
    var band = (Microsoft.UI.Xaml.Shapes.Path)XamlReader.Load("<Path xmlns=\"http://schemas.microsoft.com/winfx/2006/xaml/presentation\" Data=\"M2.75,64 L93.25,64 A48,48 0 0 1 2.75,64 Z\" Fill=\"{ThemeResource DeckPhotoChangeBrush}\"/>");
    hint.Children.Add(band);
    var cue = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Margin = new(0, 0, 0, 9) };
    var camera = new DeckIcon { Glyph = "\uE722", FontSize = 10, VerticalAlignment = VerticalAlignment.Center };
    camera.SetResourceReference(Control.ForegroundProperty, "DeckBadgeInkBrush"); cue.Children.Add(camera);
    var change = new TextBlock { Text = "Change", FontSize = 11, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
    change.SetResourceReference(TextBlock.ForegroundProperty, "DeckBadgeInkBrush"); cue.Children.Add(change);
    hint.Children.Add(cue); grid.Children.Add(hint);
    void ShowHint(bool visible)
    {
      var animation = new DoubleAnimation { To = visible ? 1 : 0, Duration = new Duration(TimeSpan.FromMilliseconds(120)) };
      Storyboard.SetTarget(animation, hint); Storyboard.SetTargetProperty(animation, "Opacity");
      var storyboard = new Storyboard(); storyboard.Children.Add(animation); storyboard.Begin();
    }
    var button = new Button { Content = grid, Width = 96, Height = 96, Padding = new(0), BorderThickness = new(0), CornerRadius = new(48), IsEnabled = !working, AllowDrop = true };
    button.Style = (Style)Application.Current.Resources["DeckNavigationButtonStyle"];
    AutomationProperties.SetName(button, "Change your picture");
    AutomationProperties.SetAutomationId(button, "settings.profile.picture.change");
    button.PointerEntered += (_, _) => ShowHint(true);
    button.PointerExited += (_, _) => ShowHint(false);
    button.GotFocus += (_, _) => ShowHint(true);
    button.LostFocus += (_, _) => ShowHint(false);
    if (profile.PictureSource == "uploaded" && profile.Picture is not null)
    {
      var menu = DeckMenu.CreateFor(this);
      var choose = new MenuFlyoutItem { Text = "Choose picture…" };
      choose.Click += async (_, _) => await ChoosePictureAsync();
      menu.Items.Add(choose);
      var remove = new MenuFlyoutItem { Text = "Remove picture" };
      remove.Click += async (_, _) => await PressAsync(async () => read = await account.RemoveProfilePictureAsync());
      menu.Items.Add(remove);
      button.Flyout = menu;
    }
    else button.Click += async (_, _) => await ChoosePictureAsync();
    button.DragOver += (_, args) => { if (args.DataView.Contains(StandardDataFormats.StorageItems)) { args.AcceptedOperation = DataPackageOperation.Copy; ShowHint(true); } };
    button.DragLeave += (_, _) => ShowHint(false);
    button.Drop += async (_, args) =>
    {
      ShowHint(false);
      if (!args.DataView.Contains(StandardDataFormats.StorageItems)) return;
      try
      {
        var files = await args.DataView.GetStorageItemsAsync();
        if (files.OfType<StorageFile>().FirstOrDefault() is { } file) await SavePictureAsync(file);
      }
      catch (Exception error) when (error is not OutOfMemoryException) { pressProblem = "Could not read that picture. Try a PNG or JPEG."; Render(); }
    };
    return button;
  }

  private async Task ChoosePictureAsync()
  {
    try
    {
      var picker = new FileOpenPicker();
      foreach (var extension in new[] { ".png", ".jpg", ".jpeg", ".webp", ".bmp" }) picker.FileTypeFilter.Add(extension);
      WinRT.Interop.InitializeWithWindow.Initialize(picker, Win32Interop.GetWindowFromWindowId(XamlRoot.ContentIslandEnvironment.AppWindowId));
      if (await picker.PickSingleFileAsync() is { } file) await SavePictureAsync(file);
    }
    catch (Exception error) when (error is not OutOfMemoryException) { pressProblem = "Could not open that picture. Try a PNG or JPEG."; Render(); }
  }

  private async Task SavePictureAsync(StorageFile file) => await PressAsync(async () =>
  {
    if ((await file.GetBasicPropertiesAsync()).Size > 64 * 1024 * 1024) throw new CloudProfileRefusal("Choose a picture smaller than 64 MB.");
    using var input = await file.OpenReadAsync();
    var decoder = await BitmapDecoder.CreateAsync(input);
    if (decoder.OrientedPixelWidth == 0 || decoder.OrientedPixelHeight == 0 || (ulong)decoder.OrientedPixelWidth * decoder.OrientedPixelHeight > 100_000_000) throw new CloudProfileRefusal("That picture is too large to read. Choose a smaller picture.");
    var scale = 512.0 / Math.Min(decoder.OrientedPixelWidth, decoder.OrientedPixelHeight);
    var width = (uint)Math.Ceiling(decoder.OrientedPixelWidth * scale);
    var height = (uint)Math.Ceiling(decoder.OrientedPixelHeight * scale);
    var transform = new BitmapTransform { ScaledWidth = width, ScaledHeight = height, Bounds = new BitmapBounds { X = (width - 512) / 2, Y = (height - 512) / 2, Width = 512, Height = 512 }, InterpolationMode = BitmapInterpolationMode.Fant };
    var pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, transform, ExifOrientationMode.RespectExifOrientation, ColorManagementMode.ColorManageToSRgb);
    using var output = new InMemoryRandomAccessStream();
    var options = new BitmapPropertySet { ["ImageQuality"] = new BitmapTypedValue(0.85f, Windows.Foundation.PropertyType.Single) };
    var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, output, options);
    encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, 512, 512, 96, 96, pixels.DetachPixelData());
    await encoder.FlushAsync();
    output.Seek(0);
    using var stream = output.AsStreamForRead();
    using var bytes = new MemoryStream();
    await stream.CopyToAsync(bytes);
    read = await account.SaveProfilePictureAsync(bytes.ToArray());
  });
}
