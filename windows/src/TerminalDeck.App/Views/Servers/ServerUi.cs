using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Markup;
using TerminalDeck.Core.Servers;
using Windows.Storage.Pickers;

namespace TerminalDeck.App.Views.Servers;

public sealed record ServerProjectChoice(string Id, string Name);
public sealed record ServerAiAppChoice(string Id, string Name);
public interface IServerPageHost
{
  nint WindowHandle { get; }
  IReadOnlyList<ServerAiAppChoice> AiApps { get; }
  IReadOnlyList<ServerProjectChoice> Projects => [];
  void OpenSession(string id);
}
internal static class ServerUi
{
  public static string CallerName(string id) => id.StartsWith("hoot:", StringComparison.Ordinal) ? "Hoot" : id;
  public static StackPanel Stack(double gap = 12) => new() { Spacing = gap, HorizontalAlignment = HorizontalAlignment.Stretch };
  public static TextBlock Words(string text, double size = 14, bool muted = false) => new() { Text = text, FontSize = size, TextWrapping = TextWrapping.Wrap, Opacity = muted ? 0.68 : 1 };
  public static Style Canvas() => (Style)XamlReader.Load("""
    <Style xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" TargetType="Grid"><Setter Property="Background" Value="{ThemeResource DeckCanvasBrush}" /></Style>
    """);
  public static Border Card(UIElement child) => new() { Child = child, Padding = new Thickness(20), Style = (Style)Application.Current.Resources["SurfaceCardStyle"] };
  public static Button Button(string title, Func<Task> clicked, bool primary = false)
  {
    var button = new Button { Content = title, MinHeight = 40 };
    if (primary) button.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
    AutomationProperties.SetName(button, title);
    button.Click += async (_, _) =>
    {
      button.IsEnabled = false;
      try { await clicked(); }
      catch (OperationCanceledException) { }
      catch (Exception ex) when (ex is not OutOfMemoryException)
      {
        // Native pickers can also fail before the view model starts a request.
        // Keep those failures visible and away from async event dispatch.
        if (button.XamlRoot is { } root)
          try { await Dialog(root, "Request could not finish", Words("Check the connection, folder and server tools, then try again."), "OK").ShowAsync(); }
          catch (Exception showError) when (showError is not OutOfMemoryException) { }
      }
      finally { button.IsEnabled = true; }
    }; return button;
  }
  public static StackPanel Horizontal(params UIElement[] children)
  {
    var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
    foreach (var child in children) row.Children.Add(child);
    return row;
  }
  public static DeckIcon Icon(string glyph) => new() { Glyph = glyph, FontSize = 16, FontFamily = TerminalDeck.App.Views.DeckFonts.Icons, VerticalAlignment = VerticalAlignment.Center };
  public static Button IconButton(string glyph, string name, Func<Task> clicked)
  {
    var button = Button(name, clicked); button.Content = Icon(glyph);
    button.MinWidth = 36; button.MinHeight = 36; button.Padding = new Thickness(8);
    ToolTipService.SetToolTip(button, name); return button;
  }
  public static Grid Header(FrameworkElement title, FrameworkElement actions)
  {
    var grid = new Grid { ColumnSpacing = 16 };
    grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
    grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
    grid.Children.Add(title); Grid.SetColumn(actions, 1); grid.Children.Add(actions);
    if (actions is FrameworkElement element) element.VerticalAlignment = VerticalAlignment.Center;
    return grid;
  }
  public static Grid DataRow(params FrameworkElement[] children)
  {
    var grid = new Grid { ColumnSpacing = 12, Padding = new Thickness(0, 10, 0, 10), HorizontalAlignment = HorizontalAlignment.Stretch };
    for (var i = 0; i < children.Length; i++)
    {
      grid.ColumnDefinitions.Add(new ColumnDefinition { Width = i == 1 ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
      Grid.SetColumn(children[i], i); grid.Children.Add(children[i]);
      if (children[i] is FrameworkElement element)
      {
        element.VerticalAlignment = VerticalAlignment.Center;
        if (i >= 2 && element is TextBlock) element.MaxWidth = 180;
      }
    }
    return grid;
  }
  public static void AddMenu(MenuFlyout menu, string label, Func<Task> action, bool enabled = true)
  {
    var item = new MenuFlyoutItem { Text = label, IsEnabled = enabled };
    item.Click += async (_, _) =>
    {
      item.IsEnabled = false;
      try { await action(); }
      catch (OperationCanceledException) { }
      catch (Exception ex) when (ex is not OutOfMemoryException)
      {
        if (item.XamlRoot is { } root)
          try { await Dialog(root, "Request could not finish", Words("Check the connection, folder and server tools, then try again."), "OK").ShowAsync(); }
          catch (Exception showError) when (showError is not OutOfMemoryException) { }
      }
      finally { item.IsEnabled = enabled; }
    };
    menu.Items.Add(item);
  }
  public static string Size(long bytes) => bytes < 1024 ? bytes + " B" : bytes < 1048576 ? (bytes / 1024d).ToString("0.#") + " KB" : (bytes / 1048576d).ToString("0.#") + " MB";
  public static TextBox Field(string label, string value = "", bool multiline = false) => new()
  { Header = label, Text = value, MaxLength = 4096, AcceptsReturn = multiline, TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap, MinHeight = multiline ? 100 : 36 };
  public static ScrollViewer Scroll(StackPanel body)
  {
    var scroll = new ScrollViewer { Content = body, HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, HorizontalScrollMode = ScrollMode.Disabled };
    void Fit() => body.Width = Math.Max(0, Math.Min(1040, scroll.ActualWidth - 48));
    scroll.SizeChanged += (_, _) => Fit(); scroll.Loaded += (_, _) => Fit(); return scroll;
  }
  public static ContentDialog Dialog(XamlRoot root, string title, UIElement content, string action = "Save") => new()
  {
    XamlRoot = root, RequestedTheme = (root.Content as FrameworkElement)?.ActualTheme ?? ElementTheme.Default,
    Title = title, Content = new ScrollViewer { Content = content, MaxHeight = 520, HorizontalScrollMode = ScrollMode.Disabled },
    PrimaryButtonText = action, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Close
  };
  public static async Task<string?> PickFileAsync(nint window)
  {
    var picker = new FileOpenPicker(); picker.FileTypeFilter.Add("*"); WinRT.Interop.InitializeWithWindow.Initialize(picker, window);
    return (await picker.PickSingleFileAsync())?.Path;
  }
  public static async Task<IReadOnlyList<string>> PickFilesAsync(nint window)
  {
    var picker = new FileOpenPicker(); picker.FileTypeFilter.Add("*"); WinRT.Interop.InitializeWithWindow.Initialize(picker, window);
    return (await picker.PickMultipleFilesAsync()).Select(file => file.Path).ToArray();
  }
  public static async Task<string?> SaveFileAsync(nint window, string name)
  {
    var picker = new FolderPicker(); picker.FileTypeFilter.Add("*"); WinRT.Interop.InitializeWithWindow.Initialize(picker, window);
    var folder = await picker.PickSingleFolderAsync();
    return folder is null ? null : Path.Combine(folder.Path, name);
  }
  public static StackPanel Actions(params UIElement[] buttons)
  {
    // A vertical action stack stays reachable in narrow windows, without a page
    // that can drift sideways when container names or paths get long.
    var actions = Stack(8); foreach (var b in buttons) actions.Children.Add(b); return actions;
  }
}
public sealed class ServerDialogAuthorizer(Func<XamlRoot?> root, Microsoft.UI.Dispatching.DispatcherQueue dispatcher) : IServerAuthorizer
{
  public async ValueTask<bool> ApproveAsync(ServerCaller caller, ServerAction action, CancellationToken ct)
  {
    var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
    if (!dispatcher.TryEnqueueHandled(async () =>
    {
      if (ct.IsCancellationRequested || root() is not { } view) { completion.TrySetResult(false); return; }
      try
      {
        var dialog = ServerUi.Dialog(view, action.Operation,
          ServerUi.Words(action.Name + "\n\n" + action.Target + "\n\nRequested by " + ServerUi.CallerName(caller.Id) + "."), "Approve");
        using var cancel = ct.Register(() => dispatcher.TryEnqueueHandled(dialog.Hide));
        completion.TrySetResult(await dialog.ShowAsync() == ContentDialogResult.Primary && !ct.IsCancellationRequested);
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { completion.TrySetResult(false); }
    })) return false;
    return await completion.Task.WaitAsync(ct);
  }
}

public sealed class ServerPersonKeyPicker(Func<nint> window, Microsoft.UI.Dispatching.DispatcherQueue dispatcher) : IServerKeyPicker
{
  public async ValueTask<string?> PickAsync(CancellationToken ct)
  {
    var completion = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
    if (!dispatcher.TryEnqueueHandled(async () =>
    {
      try
      {
        ct.ThrowIfCancellationRequested();
        var picked = await ServerUi.PickFileAsync(window());
        ct.ThrowIfCancellationRequested();
        completion.TrySetResult(picked);
      }
      catch (OperationCanceledException) { completion.TrySetCanceled(ct); }
      catch (Exception ex) when (ex is not OutOfMemoryException) { completion.TrySetException(new IOException("The SSH key picker could not open. Try again from the server page.")); }
    })) throw new IOException("The server window is not available for choosing a key file.");
    return await completion.Task.WaitAsync(ct);
  }
}
