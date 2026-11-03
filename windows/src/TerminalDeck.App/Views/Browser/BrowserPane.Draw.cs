using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Path = System.IO.Path;
using TerminalDeck.App.Shell;
using TerminalDeck.Core.Browser;
using Windows.Foundation;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace TerminalDeck.App.Views;

public sealed partial class BrowserPane
{
  private async Task DrawAsync(BrowserTab tab)
  {
    if (tab.DrawingImage is null) tab.DrawingImage = await CaptureAsync(tab);
    var source = new BitmapImage();
    using (var stream = new InMemoryRandomAccessStream())
    {
      using (var writer = new DataWriter(stream.GetOutputStreamAt(0))) { writer.WriteBytes(tab.DrawingImage); await writer.StoreAsync(); }
      stream.Seek(0); await source.SetSourceAsync(stream);
    }
    var width = Math.Min(680, source.PixelWidth); var height = width * source.PixelHeight / (double)source.PixelWidth;
    var canvas = new Canvas { Width = width, Height = height, IsTabStop = true };
    var content = new StackPanel { Spacing = 12 }; var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    var tools = new ComboBox { ItemsSource = Enum.GetNames<BrowserDrawTool>(), SelectedIndex = 0 };
    var text = new TextBox { PlaceholderText = "Text", MaxLength = 1000, Visibility = Visibility.Collapsed, MinWidth = 200 };
    tools.SelectionChanged += (_, _) => text.Visibility = tools.SelectedIndex == 3 ? Visibility.Visible : Visibility.Collapsed;
    actions.Children.Add(tools); actions.Children.Add(text);
    var undo = TextAction("Undo", () => { tab.Drawing.Undo(); }); var clear = TextAction("Clear", () => tab.Drawing.Clear()); actions.Children.Add(undo); actions.Children.Add(clear); content.Children.Add(actions);
    content.Children.Add(new ScrollViewer { Content = canvas, MaxHeight = 440, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto });
    var hint = new TextBlock { Text = "Draw on this frozen picture. Your marks are kept until you send or discard them.", TextWrapping = TextWrapping.Wrap }; content.Children.Add(hint);
    var pending = new List<BrowserDrawPoint>(); bool drawing = false;
    Brush Ink() => (Brush)ShellTheme.Resource(canvas, "AccentFillColorDefaultBrush");
    void Render()
    {
      canvas.Children.Clear(); canvas.Children.Add(new Image { Source = source, Width = width, Height = height });
      foreach (var mark in tab.Drawing.Marks.Concat(drawing && pending.Count > 0 ? new[] { new BrowserDrawMark((BrowserDrawTool)tools.SelectedIndex, pending.ToArray(), text.Text) } : []))
      {
        var points = mark.Points.Select(p => new Point(p.X * width, p.Y * height)).ToArray();
        var first = points[0]; var last = points[^1];
        if (mark.Tool == BrowserDrawTool.Draw)
        {
          var line = new Polyline { Stroke = Ink(), StrokeThickness = 3, StrokeLineJoin = PenLineJoin.Round };
          foreach (var point in points) line.Points.Add(point); canvas.Children.Add(line);
        }
        else if (mark.Tool == BrowserDrawTool.Box)
        {
          var box = new Rectangle { Width = Math.Abs(last.X - first.X), Height = Math.Abs(last.Y - first.Y), Stroke = Ink(), StrokeThickness = 3 };
          Canvas.SetLeft(box, Math.Min(first.X, last.X)); Canvas.SetTop(box, Math.Min(first.Y, last.Y)); canvas.Children.Add(box);
        }
        else if (mark.Tool == BrowserDrawTool.Arrow)
        {
          canvas.Children.Add(new Line { X1 = first.X, Y1 = first.Y, X2 = last.X, Y2 = last.Y, Stroke = Ink(), StrokeThickness = 3 });
          var angle = Math.Atan2(last.Y - first.Y, last.X - first.X); var head = new Polyline { Stroke = Ink(), StrokeThickness = 3 };
          head.Points.Add(new(last.X - 12 * Math.Cos(angle - 0.5), last.Y - 12 * Math.Sin(angle - 0.5))); head.Points.Add(last); head.Points.Add(new(last.X - 12 * Math.Cos(angle + 0.5), last.Y - 12 * Math.Sin(angle + 0.5))); canvas.Children.Add(head);
        }
        else
        {
          var label = new TextBlock { Text = mark.Text, Foreground = Ink(), FontSize = 18, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold };
          Canvas.SetLeft(label, first.X); Canvas.SetTop(label, first.Y); canvas.Children.Add(label);
        }
      }
      undo.IsEnabled = clear.IsEnabled = tab.Drawing.Marks.Count > 0;
    }
    undo.Click += (_, _) => Render(); clear.Click += (_, _) => Render();
    BrowserDrawPoint Position(Microsoft.UI.Xaml.Input.PointerRoutedEventArgs args)
    { var point = args.GetCurrentPoint(canvas).Position; return new(Math.Clamp(point.X / width, 0, 1), Math.Clamp(point.Y / height, 0, 1)); }
    canvas.PointerPressed += (_, args) => { drawing = true; pending.Clear(); pending.Add(Position(args)); canvas.CapturePointer(args.Pointer); args.Handled = true; };
    canvas.PointerMoved += (_, args) => { if (drawing && pending.Count < 20000) { pending.Add(Position(args)); Render(); } };
    canvas.PointerReleased += (_, args) =>
    {
      if (!drawing) return; drawing = false; pending.Add(Position(args)); canvas.ReleasePointerCapture(args.Pointer);
      try { tab.Drawing.Add(new((BrowserDrawTool)tools.SelectedIndex, pending.ToArray(), text.Text)); hint.Text = "Mark added."; Render(); }
      catch (ArgumentException error) { hint.Text = error.Message; } args.Handled = true;
    };
    canvas.PointerCanceled += (_, _) => { drawing = false; pending.Clear(); };
    Render(); tab.DrawingChanged = Render;
    var dialog = new ContentDialog { XamlRoot = RootFor(tab), RequestedTheme = tab.View.ActualTheme, Title = "Draw", Content = content, PrimaryButtonText = "Save picture", SecondaryButtonText = SendRequest is null ? "" : "Send picture", CloseButtonText = "Done" };
    async void Save(object sender, ContentDialogButtonClickEventArgs args)
    {
      var deferral = args.GetDeferral();
      try
      {
        var bytes = await RenderPngAsync(canvas, source.PixelWidth, source.PixelHeight);
        var directory = Path.Combine(root.DirectoryPath, "browser-captures"); Directory.CreateDirectory(directory);
        tab.CapturePath = Path.Combine(directory, "draw-" + DateTimeOffset.UtcNow.ToString("yyyyMMddTHHmmssfff") + ".png");
        await File.WriteAllBytesAsync(tab.CapturePath, bytes); SetTabStatus(tab, "Marked picture saved: " + tab.CapturePath);
      }
      catch (Exception error) when (error is not OutOfMemoryException) { args.Cancel = true; hint.Text = "The marked picture could not be saved. Your marks are kept."; }
      finally { deferral.Complete(); }
    }
    dialog.PrimaryButtonClick += Save; dialog.SecondaryButtonClick += Save;
    ContentDialogResult answer;
    BrowserDialogForProof = dialog;
    try { answer = await dialog.ShowAsync(); }
    finally { tab.DrawingChanged = null; BrowserDialogForProof = null; }
    if (answer == ContentDialogResult.Secondary && tab.CapturePath is { } picture)
    {
      var outcome = await ReviewSendAsync(tab, TerminalDeck.Core.Browser.BrowserContext.Create(tab.Address, tab.Title, "Marked picture"), picture);
      if (outcome == BrowserSendOutcome.Sent) { tab.Drawing.Clear(); tab.DrawingImage = null; }
    }
    else if (answer == ContentDialogResult.Primary) { }
    else if (tab.Drawing.Marks.Count > 0)
    {
      var keep = await new ContentDialog { XamlRoot = RootFor(tab), RequestedTheme = tab.View.ActualTheme, Title = "Keep these marks?", Content = "This picture has not been sent.", PrimaryButtonText = "Keep", SecondaryButtonText = "Discard", CloseButtonText = "Cancel" }.ShowAsync();
      if (keep == ContentDialogResult.Secondary) { tab.Drawing.Clear(); tab.DrawingImage = null; }
      if (keep == ContentDialogResult.None) await DrawAsync(tab);
    }
  }
  private static async Task<byte[]> RenderPngAsync(FrameworkElement element, int width, int height)
  {
    var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync(element, width, height);
    var buffer = await bitmap.GetPixelsAsync(); var pixels = new byte[checked((int)buffer.Length)]; using (var reader = DataReader.FromBuffer(buffer)) reader.ReadBytes(pixels);
    using var output = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output);
    encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, pixels); await encoder.FlushAsync();
    using var data = new DataReader(output.GetInputStreamAt(0)); await data.LoadAsync((uint)output.Size); var bytes = new byte[checked((int)output.Size)]; data.ReadBytes(bytes); return bytes;
  }
}
