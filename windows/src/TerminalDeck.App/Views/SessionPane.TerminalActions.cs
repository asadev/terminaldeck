using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TerminalDeck.Core.Sessions;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
namespace TerminalDeck.App.Views;
public sealed partial class SessionPane
{
  private readonly StackPanel terminalFind = new() { Spacing = 4, Margin = new Thickness(8), Visibility = Visibility.Collapsed };
  private readonly TextBox terminalQuery = new() { PlaceholderText = "Find in terminal", MinWidth = 160, MaxWidth = 280 };
  private readonly TextBlock terminalMatches = new() { VerticalAlignment = VerticalAlignment.Center };
  private void ApplyCopyOnSelect()
  { Post(new { type = "copyOnSelect", enabled = runtime?.General.Read().CopyOnSelect ?? false }); }
  private void BuildTerminalActions(Grid area)
  {
    if (runtime is not null) runtime.General.Changed += ApplyCopyOnSelect;
    area.RowDefinitions.Add(new() { Height = GridLength.Auto }); area.RowDefinitions.Add(new() { Height = new GridLength(1, GridUnitType.Star) });
    var queryLine = new Grid { ColumnSpacing = 8 };
    queryLine.ColumnDefinitions.Add(new() { Width = new GridLength(1, GridUnitType.Star) }); queryLine.ColumnDefinitions.Add(new() { Width = GridLength.Auto });
    queryLine.Children.Add(terminalQuery); SetColumn(terminalMatches, 1); queryLine.Children.Add(terminalMatches); terminalFind.Children.Add(queryLine);
    var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; terminalFind.Children.Add(actions);
    Button Action(string title, Action run) { var button = new Button { Content = title, MinHeight = 28 }; button.Click += (_, _) => run(); return button; }
    actions.Children.Add(Action("Previous", () => FindTerminal(true))); actions.Children.Add(Action("Next", () => FindTerminal(false)));
    void CloseFind() { terminalFind.Visibility = Visibility.Collapsed; Post(new { type = "find", query = "" }); Post(new { type = "focus" }); }
    actions.Children.Add(Action("Done", CloseFind)); area.Children.Add(terminalFind); SetRow(terminal!, 1);
    terminalQuery.TextChanged += (_, _) => FindTerminal(false);
    terminalQuery.KeyDown += (_, e) =>
    {
      if (e.Key == Windows.System.VirtualKey.Enter) { FindTerminal((Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Shift) & Windows.UI.Core.CoreVirtualKeyStates.Down) != 0); e.Handled = true; }
      else if (e.Key == Windows.System.VirtualKey.Escape) { CloseFind(); e.Handled = true; }
    };
    terminal!.AllowDrop = true;
    terminal.DragOver += (_, e) => e.AcceptedOperation = e.DataView.Contains(StandardDataFormats.StorageItems) || e.DataView.Contains(StandardDataFormats.Text) || e.DataView.Contains(StandardDataFormats.WebLink) ? DataPackageOperation.Copy : DataPackageOperation.None;
    terminal.Drop += async (_, e) =>
    {
      var deferral = e.GetDeferral();
      try { await PasteDataAsync(e.DataView); }
      catch (Exception ex) when (ex is IOException or ArgumentException or InvalidOperationException or System.Runtime.InteropServices.COMException) { notice("This drop could not be added: " + ex.Message); }
      finally { e.Handled = true; deferral.Complete(); }
    };
  }
  private void OpenTerminalFind() { terminalFind.Visibility = Visibility.Visible; terminalQuery.Focus(FocusState.Programmatic); terminalQuery.SelectAll(); }
  private void FindTerminal(bool previous) { if (terminalFind.Visibility != Visibility.Visible) OpenTerminalFind(); Post(new { type = "find", query = terminalQuery.Text, direction = previous ? "previous" : "next" }); }
  private void TerminalFindResult(JsonElement message)
  { var count = message.GetProperty("count").GetInt32(); var index = message.GetProperty("index").GetInt32(); terminalMatches.Text = count > 0 ? (index + 1) + " of " + count : "0 matches"; }
  private void ShowTerminalMenu()
  {
    if (terminal is null) return;
    var menu = new MenuFlyout();
    var copy = new MenuFlyoutItem { Text = "Copy", KeyboardAcceleratorTextOverride = "Ctrl+Shift+C" }; copy.Click += (_, _) => Post(new { type = "copy" }); menu.Items.Add(copy);
    var paste = new MenuFlyoutItem { Text = "Paste", KeyboardAcceleratorTextOverride = "Ctrl+Shift+V" }; paste.Click += async (_, _) => await PasteClipboardAsync(); menu.Items.Add(paste);
    var find = new MenuFlyoutItem { Text = "Find…", KeyboardAcceleratorTextOverride = "Ctrl+F" }; find.Click += (_, _) => OpenTerminalFind(); menu.Items.Add(find);
    var next = new MenuFlyoutItem { Text = "Find next", KeyboardAcceleratorTextOverride = "Ctrl+G" }; next.Click += (_, _) => FindTerminal(false); menu.Items.Add(next);
    var previous = new MenuFlyoutItem { Text = "Find previous", KeyboardAcceleratorTextOverride = "Ctrl+Shift+G" }; previous.Click += (_, _) => FindTerminal(true); menu.Items.Add(previous);
    menu.ShowAt(terminal);
  }
  private void CopyTerminalSelection(string text)
  { if (text.Length == 0) return; var package = new DataPackage(); package.SetText(text); Clipboard.SetContent(package); }
  private async Task PasteClipboardAsync()
  {
    try { await PasteDataAsync(Clipboard.GetContent()); }
    catch (Exception ex) when (ex is IOException or ArgumentException or InvalidOperationException or System.Runtime.InteropServices.COMException) { notice("This clipboard content could not be pasted: " + ex.Message); }
  }
  private bool RemoteTerminal => runtime?.Sessions.FirstOrDefault(s => s.Definition.Id == draft.Id)?.Definition.ServerId is not null;
  private async Task PasteDataAsync(DataPackageView data)
  {
    if (disposed || !draft.IsLive) { notice("Open a running terminal before pasting."); return; }
    string text;
    if (data.Contains(StandardDataFormats.StorageItems))
    {
      if (RemoteTerminal) { notice("These files are on this PC. Transfer them to the server before pasting a server path."); return; }
      text = TerminalPaste.Paths((await data.GetStorageItemsAsync()).Select(i => i.Path), draft.Provider == "shell");
    }
    else if (data.Contains(StandardDataFormats.Bitmap))
    {
      if (RemoteTerminal) { notice("This image is on this PC. Transfer it to the server before pasting a server path."); return; }
      using var source = await (await data.GetBitmapAsync()).OpenReadAsync(); var decoder = await BitmapDecoder.CreateAsync(source);
      if (decoder.PixelWidth > 16384 || decoder.PixelHeight > 16384 || (ulong)decoder.PixelWidth * decoder.PixelHeight > 16_000_000) throw new ArgumentException("Choose an image up to 16 megapixels.");
      var pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, new BitmapTransform(), ExifOrientationMode.RespectExifOrientation, ColorManagementMode.DoNotColorManage);
      using var encoded = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, encoded);
      encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, decoder.OrientedPixelWidth, decoder.OrientedPixelHeight, 96, 96, pixels.DetachPixelData()); await encoder.FlushAsync();
      if (encoded.Size > 8 * 1024 * 1024) throw new ArgumentException("Choose an image up to 8 MB.");
      var folder = Path.Combine(root.DirectoryPath, "attachments", draft.Id); Directory.CreateDirectory(folder); var path = Path.Combine(folder, Guid.NewGuid().ToString("N") + ".png");
      encoded.Seek(0); using (var input = encoded.AsStreamForRead()) using (var file = File.Create(path)) await input.CopyToAsync(file); text = TerminalPaste.Paths([path], draft.Provider == "shell");
    }
    else if (data.Contains(StandardDataFormats.WebLink)) text = (await data.GetWebLinkAsync()).AbsoluteUri;
    else if (data.Contains(StandardDataFormats.Text)) text = await data.GetTextAsync();
    else { notice("Paste text, files or an image into this terminal."); return; }
    if (System.Text.Encoding.UTF8.GetByteCount(text) > 60_000) throw new ArgumentException("Paste at most 60000 UTF-8 bytes at once.");
    Post(new { type = "paste", text });
  }
}
