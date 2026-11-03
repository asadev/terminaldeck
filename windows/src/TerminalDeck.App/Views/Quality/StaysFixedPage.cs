using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Quality;

namespace TerminalDeck.App.Views.Quality;

public sealed partial class StaysFixedPage : Grid
{
  private readonly StaysFixedService service;
  private readonly string folder;
  private readonly StackPanel report = new() { Spacing = 12 };
  private readonly TextBlock notice = new() { FontSize = 12, TextWrapping = TextWrapping.Wrap };
  private readonly ProgressBar progress = new() { IsIndeterminate = true, Visibility = Visibility.Collapsed };
  private readonly Button check = new() { Content = "Run check" }, setup = new() { Content = "Set up…" }, refresh = new() { Content = "Check setup" }, cancel = new() { Content = "Cancel", Visibility = Visibility.Collapsed };
  private CancellationTokenSource? running;
  private ToggleSwitch? agentAccess;
  public StaysFixedPage(StaysFixedService service, string folder, Action reviewChanges, Func<Task>? aiFix = null, Action<string>? openFile = null)
  {
    this.service = service; this.folder = folder;
    RowDefinitions.Add(new() { Height = GridLength.Auto }); RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
    var content = new StackPanel { Spacing = 20, MaxWidth = 880, HorizontalAlignment = HorizontalAlignment.Stretch, Margin = new(32, 24, 32, 24) };
    var top = new StackPanel { Spacing = 12 };
    top.Children.Add(new TextBlock { Text = "Stays Fixed", FontSize = 20, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold });
    top.Children.Add(new TextBlock { Text = "Check that your next change keeps the things that already worked.", FontSize = 13, TextWrapping = TextWrapping.Wrap });
    var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    foreach (var button in new[] { refresh, setup, check, cancel }) actions.Children.Add(button);
    var changes = new Button { Content = "Review changes" }; changes.Click += (_, _) => reviewChanges(); actions.Children.Add(changes);
    top.Children.Add(new ScrollViewer { Content = actions, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled }); AddAdvancedActions(top, aiFix, openFile); top.Children.Add(progress); top.Children.Add(notice); content.Children.Add(top); content.Children.Add(report);
    var scroll = new ScrollViewer { Content = content, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled }; SetRowSpan(scroll, 2); Children.Add(scroll);
    refresh.Click += async (_, _) => await RunAsync("doctor");
    check.Click += async (_, _) => await RunAsync("check"); cancel.Click += (_, _) => running?.Cancel();
    setup.Click += async (_, _) =>
    {
      var preview = await RunAsync("preview"); if (preview is null || !preview.Ok) return;
      var dialog = new ContentDialog { XamlRoot = XamlRoot, RequestedTheme = ActualTheme, Title = "Set up Stays Fixed?", Content = new ScrollViewer { MaxHeight = 420, Content = new TextBlock { Text = preview.Report?.ToString() ?? "The engine will create its project configuration.", TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true } }, PrimaryButtonText = "Set up", CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close };
      if (await dialog.ShowAsync() == ContentDialogResult.Primary) await RunAsync("setup");
    };
    Unloaded += (_, _) => running?.Cancel();
    Loaded += async (_, _) => { if (report.Children.Count == 0) await RunAsync("doctor"); };
  }
  private Task<StaysFixedReport?> RunAsync(string action) => RunAsync(new StaysFixedRequest(action));
  private async Task<StaysFixedReport?> RunAsync(StaysFixedRequest request)
  {
    var action = request.Action;
    if (running is not null) return null;
    using var stop = new CancellationTokenSource(); running = stop;
    refresh.IsEnabled = setup.IsEnabled = check.IsEnabled = false; cancel.Visibility = Visibility.Visible; progress.Visibility = Visibility.Visible; notice.Text = action == "check" ? "Checking the project…" : "Reading project setup…";
    try
    {
      var result = await service.RunAsync(folder, request, stop.Token);
      report.Children.Clear();
      notice.Text = result.Problem ?? (result.Ok ? "Finished · " : "Needs attention · ") + result.ReadAt.ToLocalTime().ToString("g");
      if (result.Report is { } data) RenderResult(data, action);
      return result;
    }
    catch (OperationCanceledException) { notice.Text = "Stopped this check. Earlier results stay visible."; return null; }
    catch (Exception ex) when (ex is not OutOfMemoryException) { notice.Text = ex is ArgumentException or InvalidOperationException or IOException ? ex.Message : "The check could not finish. Try again."; return null; }
    finally { if (agentAccess is not null) agentAccess.IsOn = service.AiSessionsEnabled(folder); running = null; refresh.IsEnabled = setup.IsEnabled = check.IsEnabled = true; cancel.Visibility = Visibility.Collapsed; progress.Visibility = Visibility.Collapsed; }
  }
  private void EvidenceImage(StackPanel host, string? source)
  {
    if (string.IsNullOrWhiteSpace(source)) return;
    try
    {
      var path = Uri.TryCreate(source, UriKind.Absolute, out var uri) && uri.IsFile ? uri.LocalPath : Path.IsPathFullyQualified(source) ? source : Path.Combine(folder, source);
      path = Path.GetFullPath(path); var basePath = Path.GetFullPath(folder).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
      if (!path.StartsWith(basePath, StringComparison.OrdinalIgnoreCase) || !new[] { ".png", ".jpg", ".jpeg" }.Contains(Path.GetExtension(path).ToLowerInvariant()) || !File.Exists(path) || new FileInfo(path).Length > 3 * 1024 * 1024) return;
      for (FileSystemInfo? part = new FileInfo(path); part is not null && part.FullName.StartsWith(basePath, StringComparison.OrdinalIgnoreCase); part = part is FileInfo file ? file.Directory : ((DirectoryInfo)part).Parent) if ((part.Attributes & FileAttributes.ReparsePoint) != 0) return;
      var picture = new Image { Source = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(new Uri(path)), MaxHeight = 420, MaxWidth = 720, Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform, HorizontalAlignment = HorizontalAlignment.Left };
      Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(picture, "Recorded evidence · " + Path.GetFileName(path)); host.Children.Add(picture);
    }
    catch (Exception error) when (error is IOException or ArgumentException or UnauthorizedAccessException) { }
  }
}
