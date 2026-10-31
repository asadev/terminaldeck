using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Browser;

namespace TerminalDeck.App.Views;

public sealed partial class BrowserPane
{
  private const string PhoneUserAgent = "Mozilla/5.0 (Linux; Android 15; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Mobile Safari/537.36";
  private async Task ApplyViewportAsync(BrowserTab tab)
  {
    var size = tab.Viewport;
    if (size.Width == 0) await tab.Model.CommandAsync("Emulation.clearDeviceMetricsOverride", new { });
    else await tab.Model.CommandAsync("Emulation.setDeviceMetricsOverride", new { width = size.Width, height = size.Height, deviceScaleFactor = 1, mobile = tab.PhoneAgent, screenWidth = size.Width, screenHeight = size.Height });
    await tab.Model.CommandAsync("Network.setUserAgentOverride", new { userAgent = tab.PhoneAgent ? PhoneUserAgent : "" });
    SetTabStatus(tab, size.Width == 0 ? "Viewport fills the window." : $"Viewport · {size.Width} × {size.Height}");
    RefreshShellViews();
  }
  private MenuFlyout SizeMenu(BrowserTab tab)
  {
    var menu = new MenuFlyout();
    menu.Opening += (_, _) =>
    {
      menu.Items.Clear();
      foreach (var size in BrowserViewport.Presets)
      {
        var item = new ToggleMenuFlyoutItem { Text = size.Width == 0 ? size.Name : $"{size.Name} — {size.Width} × {size.Height}", IsChecked = tab.Viewport.Width == size.Width && tab.Viewport.Height == size.Height };
        item.Click += async (_, _) => await GuardAsync(async () => { tab.Viewport = size; await ApplyViewportAsync(tab); }, tab); menu.Items.Add(item);
      }
      menu.Items.Add(MenuAction("Custom…", tab, () => { tab.SizeEditing = true; RefreshShellViews(); return Task.CompletedTask; }));
      var landscape = new ToggleMenuFlyoutItem { Text = "Landscape", IsChecked = tab.Viewport.Width > tab.Viewport.Height, IsEnabled = tab.Viewport.Width != 0 };
      landscape.Click += async (_, _) => await GuardAsync(async () => { tab.Viewport = tab.Viewport.Landscape(); await ApplyViewportAsync(tab); }, tab); menu.Items.Add(landscape);
      var phone = new ToggleMenuFlyoutItem { Text = "Phone user agent", IsChecked = tab.PhoneAgent };
      phone.Click += async (_, _) => await GuardAsync(async () => { tab.PhoneAgent = phone.IsChecked; await ApplyViewportAsync(tab); }, tab); menu.Items.Add(phone);
    };
    return menu;
  }
  private async Task ShowSizeAsync(BrowserTab tab)
  {
    var width = new NumberBox { Header = "Width", Minimum = 240, Maximum = 3840, Value = tab.Viewport.Width == 0 ? 1024 : tab.Viewport.Width };
    var height = new NumberBox { Header = "Height", Minimum = 240, Maximum = 3840, Value = tab.Viewport.Height == 0 ? 768 : tab.Viewport.Height };
    var dimensions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 }; dimensions.Children.Add(width); dimensions.Children.Add(height);
    if (await new ContentDialog { XamlRoot = RootFor(tab), RequestedTheme = tab.View.ActualTheme, Title = "Custom size", Content = dimensions, PrimaryButtonText = "Apply", CloseButtonText = "Cancel" }.ShowAsync() == ContentDialogResult.Primary)
    {
      if (!double.IsFinite(width.Value) || !double.IsFinite(height.Value)) throw new ArgumentException("Enter a width and height.");
      tab.Viewport = BrowserViewport.Custom((int)width.Value, (int)height.Value); await ApplyViewportAsync(tab);
    }
  }
}
