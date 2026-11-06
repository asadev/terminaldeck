using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Agents;

namespace TerminalDeck.App.Views;

// The photo and its fallback travel together, including an image that fails
// asynchronously after WinUI has already created the row.
internal static class AgentProfileAvatar
{
  internal static Border Create(string name, string? photoPath, double size)
  {
    var tile = new Border { Width = size, Height = size, CornerRadius = new(size * 0.28) };
    tile.SetResourceReference(Border.BackgroundProperty, "DeckSessionAvatarBrush");
    var initials = new TextBlock { Text = AgentPictures.Initials(name), FontSize = size * 0.40,
      FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
      HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    initials.SetResourceReference(TextBlock.ForegroundProperty, "DeckSecondaryInkBrush");
    tile.Child = initials;
    if (photoPath is not null && Path.IsPathFullyQualified(photoPath) && File.Exists(photoPath))
    {
      try
      {
        var image = new Image { Stretch = Stretch.UniformToFill };
        image.ImageFailed += (_, _) => tile.Child = initials;
        tile.Child = image;
        image.Source = new BitmapImage(new Uri(photoPath));
      }
      catch (Exception ex) when (ex is ArgumentException or IOException or System.Runtime.InteropServices.COMException) { tile.Child = initials; }
    }
    AutomationProperties.SetName(tile, name);
    return tile;
  }
}
