using TerminalDeck.App.Shell;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media.Imaging;
using TerminalDeck.App.Integration;
using TerminalDeck.Core.Computers;
using Windows.Storage.Streams;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;

namespace TerminalDeck.App.Views.Computers;

// Only a person's Open press creates or activates this window. Receiving a
// frame updates its pixels without touching the main shell selection or focus.
public sealed partial class ComputerScreenWindow
{
  private static readonly Dictionary<string, ComputerScreenWindow> windows = [];
  private readonly Window window = new();
  private readonly OtherComputersService service;
  private readonly ComputerConnection computer;
  private readonly string display;
  private readonly bool control;
  private readonly Image picture = new() { Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform };
  private readonly TextBlock status = new() { Text = "Opening…", TextWrapping = TextWrapping.Wrap };
  private readonly ScrollViewer scroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
  private bool closed;
  private bool recovering;
  private bool paused;
  private bool pointerInside;
  private readonly HashSet<string> buttonsDown = [];
  private (double X, double Y) lastAt;
  private long lastMove;
  public static void Open(OtherComputersService service, ComputerConnection computer, JsonElement display, ElementTheme theme)
  {
    var id = display.GetProperty("id").GetString()!; var key = computer.Id + "|" + id;
    if (windows.TryGetValue(key, out var existing)) { existing.window.Activate(); return; }
    var viewer = new ComputerScreenWindow(service, computer, display, theme); windows[key] = viewer;
    viewer.window.Closed += (_, _) => windows.Remove(key);
    viewer.window.Activate(); _ = viewer.WatchAsync();
  }
  private ComputerScreenWindow(OtherComputersService service, ComputerConnection computer, JsonElement screen, ElementTheme theme)
  {
    this.service = service; this.computer = computer; display = screen.GetProperty("id").GetString()!;
    pipeline = new(display, () => new TerminalDeck.Platform.Windows.Phone.WindowsH264Decoder(), QuietSendAsync,
      (shown, epoch) => window.DispatcherQueue.TryEnqueue(() => Show(shown, epoch)), () => Volatile.Read(ref screenEpoch));
    _ = Task.Run(pipeline.RunAsync);
    control = !screen.TryGetProperty("canControl", out var allowed) || allowed.ValueKind == JsonValueKind.True;
    window.Title = computer.Name + " · " + OtherComputersService.Text(screen, "name", display);
    var root = new Grid { RequestedTheme = theme, RowSpacing = 8, Padding = new(12) };
    root.SetResourceReference(Grid.BackgroundProperty, "DeckCanvasBrush");
    root.RowDefinitions.Add(new() { Height = GridLength.Auto }); root.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) }); root.RowDefinitions.Add(new() { Height = GridLength.Auto });
    var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    var size = new ToggleButton { Content = "Actual size" };
    size.Checked += (_, _) => { actualSize = true; UpdatePictureLayout(); };
    size.Unchecked += (_, _) => { actualSize = false; UpdatePictureLayout(); };
    scroll.SizeChanged += (_, _) => UpdatePictureLayout();
    var retry = new Button { Content = "Try again" }; retry.Click += async (_, _) => await WatchAsync();
    var stop = new Button { Content = "Stop" }; stop.Click += (_, _) => window.Close();
    bar.Children.Add(new TextBlock { Text = control ? "Controls the app in front on " + computer.Name : "Watch only", VerticalAlignment = VerticalAlignment.Center });
    var commandShortcuts = new ToggleButton { Content = "Use Command shortcuts", IsChecked = computer.Platform is "darwin" or "mac", IsEnabled = control };
    bar.Children.Add(commandShortcuts);
    var shortcuts = new Button { Content = "Shortcuts", IsEnabled = control };
    var shortcutMenu = new MenuFlyout();
    foreach (var shortcut in new[] { ("Switch app", "tab", computer.Platform is "darwin" or "mac" ? "command" : "option"), ("Close window", computer.Platform is "darwin" or "mac" ? "w" : "f4", computer.Platform is "darwin" or "mac" ? "command" : "option"), ("Copy", "c", "command"), ("Paste", "v", "command"), ("Select all", "a", "command") })
    {
      var item = new MenuFlyoutItem { Text = shortcut.Item1 };
      item.Click += async (_, _) => await SendAsync(new { t = "sims.input", id = display, @do = "key", key = shortcut.Item2, mods = new[] { shortcut.Item3 } });
      shortcutMenu.Items.Add(item);
    }
    shortcuts.Flyout = shortcutMenu; bar.Children.Add(shortcuts);
    bar.Children.Add(size); bar.Children.Add(retry); bar.Children.Add(stop); root.Children.Add(new ScrollViewer { Content = bar, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled, MaxHeight = 72 });
    imageSurface.Children.Add(picture); pointerLayer.Children.Add(remoteCursor); imageSurface.Children.Add(pointerLayer);
    scroll.Content = imageSurface; Grid.SetRow(scroll, 1); root.Children.Add(scroll);
    var bottom = new StackPanel { Spacing = 6 }; bottom.Children.Add(status);
    if (control)
    {
      var text = new TextBox { PlaceholderText = "Text to type on " + computer.Name, AcceptsReturn = true, MaxLength = 2000 };
      var send = new Button { Content = "Type on computer" };
      send.Click += async (_, _) => { if (text.Text.Length == 0) return; if (await SendAsync(new { t = "sims.input", id = display, @do = "type", text = text.Text })) text.Text = ""; };
      bottom.Children.Add(text); bottom.Children.Add(send);
      picture.PointerPressed += async (_, e) =>
      {
        if (PointAt(e.GetCurrentPoint(picture).Position, false) is not { } at) return;
        var properties = e.GetCurrentPoint(picture).Properties;
        var button = properties.PointerUpdateKind switch
        {
          Microsoft.UI.Input.PointerUpdateKind.LeftButtonPressed => "left",
          Microsoft.UI.Input.PointerUpdateKind.RightButtonPressed => "right",
          Microsoft.UI.Input.PointerUpdateKind.MiddleButtonPressed => "middle",
          _ => null
        };
        if (button is null) return;
        buttonsDown.Add(button); lastAt = at; picture.CapturePointer(e.Pointer); scroll.Focus(FocusState.Pointer); e.Handled = true;
        await MouseAsync("down", button, at);
      };
      picture.PointerReleased += async (_, e) =>
      {
        var at = PointAt(e.GetCurrentPoint(picture).Position, true) ?? lastAt;
        var button = e.GetCurrentPoint(picture).Properties.PointerUpdateKind switch
        {
          Microsoft.UI.Input.PointerUpdateKind.LeftButtonReleased => "left",
          Microsoft.UI.Input.PointerUpdateKind.RightButtonReleased => "right",
          Microsoft.UI.Input.PointerUpdateKind.MiddleButtonReleased => "middle",
          _ => null
        };
        if (button is not null && buttonsDown.Remove(button)) await MouseAsync("up", button, at);
        if (buttonsDown.Count == 0) picture.ReleasePointerCapture(e.Pointer); e.Handled = true;
      };
      picture.PointerMoved += async (_, e) =>
      {
        if (PointAt(e.GetCurrentPoint(picture).Position, buttonsDown.Count > 0) is not { } at) return;
        lastAt = at; FollowPointer(at.X, at.Y);
        var now = Environment.TickCount64; if (now - lastMove < 16) return; lastMove = now;
        await MouseAsync(buttonsDown.Count > 0 ? "drag" : "move", buttonsDown.FirstOrDefault() ?? "left", at);
      };
      picture.PointerCaptureLost += async (_, _) => await ReleaseAsync();
      picture.PointerExited += async (_, _) => await ReleaseAsync();
      picture.PointerWheelChanged += async (_, e) =>
      {
        if (PointAt(e.GetCurrentPoint(picture).Position, false) is not { } at) return;
        var properties = e.GetCurrentPoint(picture).Properties;
        var delta = Math.Clamp(properties.MouseWheelDelta / 1200.0, -1, 1); e.Handled = true;
        await SendAsync(new { t = "sims.input", id = display, @do = "scroll", x = at.X, y = at.Y, dx = properties.IsHorizontalMouseWheel ? delta : 0, dy = properties.IsHorizontalMouseWheel ? 0 : delta });
      };
    }
    Grid.SetRow(bottom, 2); root.Children.Add(bottom); window.Content = root;
    scroll.PointerEntered += (_, _) => pointerInside = true;
    scroll.PointerExited += (_, _) => pointerInside = false;
    scroll.PointerPressed += (_, _) => scroll.Focus(FocusState.Pointer);
    scroll.KeyDown += async (_, e) =>
    {
      if (!control || !pointerInside) return;
      var mods = new List<string>();
      bool Down(VirtualKey key) => (Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(key) & Windows.UI.Core.CoreVirtualKeyStates.Down) != 0;
      if (Down(VirtualKey.Control)) mods.Add(commandShortcuts.IsChecked == true ? "command" : "control");
      if (Down(VirtualKey.Menu)) mods.Add("option");
      if (Down(VirtualKey.Shift)) mods.Add("shift");
      var key = e.Key switch
      {
        VirtualKey.Enter => "return", VirtualKey.Tab => "tab", VirtualKey.Escape => "escape", VirtualKey.Back => "delete", VirtualKey.Delete => "forward-delete",
        VirtualKey.Left => "arrow-left", VirtualKey.Right => "arrow-right", VirtualKey.Up => "arrow-up", VirtualKey.Down => "arrow-down",
        VirtualKey.Home => "home", VirtualKey.End => "end", VirtualKey.PageUp => "page-up", VirtualKey.PageDown => "page-down",
        >= VirtualKey.F1 and <= VirtualKey.F12 => "f" + ((int)e.Key - (int)VirtualKey.F1 + 1),
        >= VirtualKey.A and <= VirtualKey.Z when mods.Contains("control") || mods.Contains("command") || mods.Contains("option") => e.Key.ToString().ToLowerInvariant(),
        _ => null
      };
      if (key is null) return;
      e.Handled = true; await SendAsync(new { t = "sims.input", id = display, @do = "key", key, mods });
    };
    char? pendingHighSurrogate = null;
    scroll.CharacterReceived += async (_, e) =>
    {
      if (!control || !pointerInside || char.IsControl(e.Character)) return;
      if ((Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control) & Windows.UI.Core.CoreVirtualKeyStates.Down) != 0) return;
      e.Handled = true;
      var character = e.Character;
      if (char.IsHighSurrogate(character)) { pendingHighSurrogate = character; return; }
      var text = char.IsLowSurrogate(character) ? pendingHighSurrogate is { } high ? new string([high, character]) : "" : character.ToString();
      pendingHighSurrogate = null;
      if (text.Length > 0) await SendAsync(new { t = "sims.input", id = display, @do = "type", text });
    };
    var paste = new Button { Content = "Paste text", IsEnabled = control };
    paste.Click += async (_, _) =>
    {
      try
      {
        var clipboard = Clipboard.GetContent();
        if (!clipboard.Contains(StandardDataFormats.Text)) { status.Text = "The clipboard has no text."; return; }
        var text = await clipboard.GetTextAsync();
        if (text.Length > 2000) { status.Text = "Paste up to 2,000 characters at once."; return; }
        if (text.Length > 0) await SendAsync(new { t = "sims.input", id = display, @do = "type", text });
      }
      catch (Exception ex) when (ex is not OutOfMemoryException) { status.Text = "Clipboard text could not be read. Try the text field below."; }
    };
    if (computer.Capabilities.Contains("clipboard"))
    {
      var getClipboard = new Button { Content = "Copy from computer" };
      getClipboard.Click += async (_, _) =>
      {
        try { var data = new DataPackage(); data.SetText(await service.ReadClipboardAsync(computer.Id)); Clipboard.SetContent(data); status.Text = "Copied this computer's clipboard text here."; }
        catch (Exception ex) when (ex is not OutOfMemoryException) { status.Text = ex.Message; }
      };
      var putClipboard = new Button { Content = "Copy to computer", IsEnabled = control };
      putClipboard.Click += async (_, _) =>
      {
        try { var data = Clipboard.GetContent(); if (!data.Contains(StandardDataFormats.Text)) throw new InvalidOperationException("Copy some text here first."); await service.WriteClipboardAsync(computer.Id, await data.GetTextAsync()); status.Text = "Copied text to this computer's clipboard. Use its Paste shortcut to insert it."; }
        catch (Exception ex) when (ex is not OutOfMemoryException) { status.Text = ex.Message; }
      };
      bottom.Children.Add(getClipboard); bottom.Children.Add(putClipboard);
    }
    bar.Children.Insert(bar.Children.Count - 1, paste);
    window.AppWindow.Changed += async (_, _) =>
    {
      var hidden = !window.AppWindow.IsVisible || window.AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter { State: Microsoft.UI.Windowing.OverlappedPresenterState.Minimized };
      if (closed || hidden == paused) return; paused = hidden;
      if (hidden) { await ReleaseAsync(); await SendAsync(new { t = "sims.unwatch", id = display }); }
      else await WatchAsync();
    };
    service.Frame += Received;
    service.Frame += VideoFrame;
    service.Changed += ConnectionChanged;
    window.Activated += async (_, args) => { if (args.WindowActivationState == WindowActivationState.Deactivated) await ReleaseAsync(); };
    window.Closed += async (_, _) =>
    {
      await ReleaseAsync(); closed = true; service.Frame -= Received; service.Frame -= VideoFrame; service.Changed -= ConnectionChanged; pipeline.Complete();
      try { await service.SendAsync(computer.Id, new { t = "sims.unwatch", id = display }); } catch (Exception ex) when (ex is not OutOfMemoryException) { }
    };
  }
  private (double X, double Y)? PointAt(Windows.Foundation.Point point, bool clamp)
  {
    if (pictureWidth <= 0 || pictureHeight <= 0) return null;
    var scale = actualSize ? ActualPixelScale() : Math.Min(picture.ActualWidth / pictureWidth, picture.ActualHeight / pictureHeight);
    var width = pictureWidth * scale; var height = pictureHeight * scale;
    if (width <= 0 || height <= 0) return null;
    var x = (point.X - (picture.ActualWidth - width) / 2) / width; var y = (point.Y - (picture.ActualHeight - height) / 2) / height;
    if (!clamp && (x is < 0 or > 1 || y is < 0 or > 1)) return null;
    return (Math.Clamp(x, 0, 1), Math.Clamp(y, 0, 1));
  }
  private Task<bool> MouseAsync(string phase, string button, (double X, double Y) at) => SendAsync(new { t = "sims.input", id = display, @do = "mouse", phase, button, x = at.X, y = at.Y, clicks = 1 });
  private async Task ReleaseAsync()
  {
    foreach (var button in buttonsDown.ToArray()) { buttonsDown.Remove(button); await MouseAsync("up", button, lastAt); }
  }
  private void ConnectionChanged() => window.DispatcherQueue.TryEnqueue(() =>
  {
    if (closed) return;
    var online = service.List().Any(c => c.Id == computer.Id && c.State == "Online");
    if (!online) { recovering = true; buttonsDown.Clear(); ResetScreenEpoch(); status.Text = "Reconnecting… Waiting for fresh screen access."; }
  });
  // Contract §11.7: H.264 on the direct link (the other computer refuses a watch that has no link).
  // H.264 on the link at 15 fps (what the software decoder keeps up with; review #27 item 5).
  private async Task WatchAsync() { ResetScreenEpoch(); status.Text = "Opening…"; await SendAsync(ComputerVideoPipeline.Watch(display, "computers-watch", cursor: true)); }
  private void VideoFrame(string machine, JsonElement frame)
  {
    if (machine == computer.Id && frame.TryGetProperty("t", out var t) && t.GetString() == "sims.video") ReceivedVideo(frame);
  }
  private async Task<bool> SendAsync(object message)
  {
    try { await service.SendAsync(computer.Id, message); return true; }
    catch (Exception ex) when (ex is not OutOfMemoryException) { status.Text = "That computer is disconnected or refused this action. Reconnect in Other computers."; return false; }
  }
}
