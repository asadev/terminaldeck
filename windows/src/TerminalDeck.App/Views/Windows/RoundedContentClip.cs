using System.Numerics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Hosting;

namespace TerminalDeck.App.Shell;

internal static class RoundedContentClip
{
  internal static void Attach(FrameworkElement element, bool topLeftOnly = false, double radius = 12)
  {
    var visual = ElementCompositionPreview.GetElementVisual(element);
    var geometry = visual.Compositor.CreateRoundedRectangleGeometry();
    geometry.CornerRadius = new((float)radius, (float)radius);
    visual.Clip = visual.Compositor.CreateGeometricClip(geometry);
    void Resize() => geometry.Size = new Vector2((float)element.ActualWidth + (topLeftOnly ? (float)radius : 0), (float)element.ActualHeight + (topLeftOnly ? (float)radius : 0));
    element.SizeChanged += (_, _) => Resize(); element.Loaded += (_, _) => Resize();
  }
}
