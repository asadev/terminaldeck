using System.Net.NetworkInformation;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.App.Shell;

namespace TerminalDeck.App.Views;

public sealed partial class BrowserPane
{
  private FrameworkElement StartView(BrowserTab tab)
  {
    var content = new StackPanel { Spacing = 14, Margin = new(32, 40, 32, 40), MaxWidth = 520, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Top };
    var heading = new TextBlock { Text = "Open a page", FontSize = 17, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold }; content.Children.Add(heading);
    var failure = new TextBlock { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed }; content.Children.Add(failure);
    var entry = new Grid { ColumnSpacing = 8 }; entry.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); entry.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    var input = new TextBox { PlaceholderText = "localhost:5173, or any address", MinHeight = 28, Height = 28, FontSize = 13, CornerRadius = new(8), Padding = new(8, 3, 8, 3) }; entry.Children.Add(input); content.Children.Add(entry);
    var open = TextAction("Open", async () => await RunForAsync(tab, "navigate", input.Text)); open.IsEnabled = false;
    open.MinHeight = 28; open.Height = 28; open.FontSize = 13; open.Padding = new(12, 3, 12, 3); open.CornerRadius = new(14);
    input.TextChanged += (_, _) => open.IsEnabled = !string.IsNullOrWhiteSpace(input.Text); Grid.SetColumn(open, 1); entry.Children.Add(open);
    input.KeyDown += async (_, args) => { if (args.Key == Windows.System.VirtualKey.Enter && open.IsEnabled) { args.Handled = true; await RunForAsync(tab, "navigate", input.Text); } };
    var retry = TextAction("Try again", async () => await RunForAsync(tab, "reload")); content.Children.Add(retry);
    var ports = new StackPanel { Spacing = 4 }; content.Children.Add(ports);
    var scan = TextAction("Scan Again", () => { }); content.Children.Add(scan);
    async Task Scan()
    {
      scan.IsEnabled = false; ports.Children.Clear(); ports.Children.Add(new TextBlock { Text = "Looking for local servers…" });
      try
      {
        var listeners = await Task.Run(() => IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners().Select(p => p.Port).Where(p => p >= 1024).Distinct().Order().ToArray());
        ports.Children.Clear();
        ports.Children.Add(new TextBlock { Text = listeners.Length == 0 ? "Nothing is listening on this machine. Start a dev server, then scan again — or type an address above." : "Listening on this machine right now:", TextWrapping = TextWrapping.Wrap });
        foreach (var port in listeners)
        {
          var label = new Grid { ColumnSpacing = 12 }; label.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); label.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
          label.Children.Add(new TextBlock { Text = ":" + port.ToString(System.Globalization.CultureInfo.InvariantCulture), FontSize = 13 });
          var arrow = new DeckIcon { Glyph = "\uE8A7", FontSize = 12, Opacity = .45 }; Grid.SetColumn(arrow, 1); label.Children.Add(arrow);
          var row = TextAction($"Open localhost:{port}", async () => await RunForAsync(tab, "navigate", $"http://localhost:{port}"));
          row.Content = label; row.HorizontalAlignment = row.HorizontalContentAlignment = HorizontalAlignment.Stretch; row.MinHeight = 34; row.Height = 34; row.Padding = new(12, 6, 12, 6); row.CornerRadius = new(8);
          row.SetResourceReference(Control.BackgroundProperty, "DeckControlBrush"); ports.Children.Add(row);
        }
      }
      catch (NetworkInformationException) { ports.Children.Clear(); ports.Children.Add(new TextBlock { Text = "Local servers could not be checked. Try Scan Again.", TextWrapping = TextWrapping.Wrap }); }
      finally { scan.IsEnabled = true; }
    }
    scan.Click += async (_, _) => await Scan(); content.Loaded += async (_, _) => await Scan();
    void Refresh()
    {
      heading.Text = tab.Failed ? "This page did not open" : "Open a page";
      failure.Text = tab.Address + "\n" + tab.Status; failure.Visibility = retry.Visibility = tab.Failed ? Visibility.Visible : Visibility.Collapsed;
    }
    tab.View.CoreWebView2.NavigationCompleted += (_, _) => Refresh(); Refresh();
    return new ScrollViewer { Content = content, HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
  }
}
