using System.Reflection;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.Web.WebView2.Core;
using TerminalDeck.App.Views;
using TerminalDeck.App.ViewModels;
using TerminalDeck.Core.Storage;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;
namespace TerminalDeck.W12.Terminal.Proof;
public partial class App : Application
{
  private Window? window;
  public App() { InitializeComponent(); }
  protected override async void OnLaunched(LaunchActivatedEventArgs args)
  {
    var root = AppDataRoot.FromArguments(Environment.GetCommandLineArgs().Skip(1).ToArray());
    if (!root.DirectoryPath.StartsWith("C:\\TD\\out\\w12-sessions-chats\\proof\\", StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Only the owned scratch root is allowed.");
    Directory.CreateDirectory(root.DirectoryPath); var passed = new List<string>(); var frames = new List<string>();
    if (File.Exists(Path.Combine(root.DirectoryPath, "started"))) throw new InvalidOperationException("Use fresh proof data."); File.WriteAllText(Path.Combine(root.DirectoryPath, "started"), "terminal");
    void Check(string title, bool value) { if (!value) throw new InvalidOperationException(title); passed.Add(title); }
    SessionPane? pane = null;
    try
    {
      window = new Window { Title = "W12 isolated terminal proof" }; window.AppWindow.Move(new(-20000, -20000)); window.AppWindow.Resize(new(1000, 720));
      // Runtime is absent: the real terminal view is exercised without a keeper,
      // shell, coding AI, account or live process. Its bridge still runs.
      var draft = new SessionDraft("Terminal proof fixture", "shell", root.DirectoryPath, SessionPresentation.Terminal) { Id = Guid.NewGuid().ToString(), IsLive = true };
      pane = new SessionPane(draft, root, _ => { }, () => { }); window.Content = pane; window.Activate(); await pane.Ready.WaitAsync(TimeSpan.FromSeconds(30));
      var webview = Tree(pane).OfType<WebView2>().Single(); var core = webview.CoreWebView2; var input = new List<string>();
      core.WebMessageReceived += (_, e) => { using var doc = JsonDocument.Parse(e.WebMessageAsJson); if (doc.RootElement.GetProperty("type").GetString() == "input") input.Add(doc.RootElement.GetProperty("data").GetString()!); };
      void Post(object value) => core.PostWebMessageAsJson(JsonSerializer.Serialize(value));
      Post(new { type = "data", data = "\u001b[?2004h❯ needle one\r\nneedle two\r\n" }); await Task.Delay(200);
      await core.ExecuteScriptAsync("window.chrome.webview.postMessage({type:'findRequest'})"); await Task.Delay(100);
      var query = Tree(pane).OfType<TextBox>().Single(t => t.PlaceholderText == "Find in terminal"); query.Text = "needle";
      await Until(() => Tree(pane).OfType<TextBlock>().Any(t => t.Text == "1 of 2")); Check("native find reads real terminal match count", true);
      var paste = typeof(SessionPane).GetMethod("PasteDataAsync", BindingFlags.Instance | BindingFlags.NonPublic) ?? throw new InvalidOperationException("The native paste handler was not found.");
      async Task Paste(DataPackage package) { await ((Task?)paste.Invoke(pane, [package.GetView()]) ?? throw new InvalidOperationException("No paste task.")); await Task.Delay(100); }
      var text = new DataPackage(); text.SetText("Unicode اردو 🙂"); await Paste(text);
      await Until(() => input.Any(t => t.Contains("اردو", StringComparison.Ordinal)));
      Check("native data-package text uses bracketed paste without added Return", input.Last() == "\u001b[200~Unicode اردو 🙂\u001b[201~");
      var path = Path.Combine(root.DirectoryPath, "two words.txt"); File.WriteAllText(path, "synthetic");
      var files = new DataPackage(); files.SetStorageItems([await StorageFile.GetFileFromPathAsync(path)]); await Paste(files);
      Check("native file paste quotes the actual PowerShell path", input.Last() == "\u001b[200~'" + path + "'\u001b[201~");
      using var image = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, image); encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, 1, 1, 96, 96, [30, 60, 90, 255]); await encoder.FlushAsync(); image.Seek(0);
      var bitmap = new DataPackage(); bitmap.SetBitmap(RandomAccessStreamReference.CreateFromStream(image)); await Paste(bitmap);
      Check("native image paste saves one owned PNG and inserts only a quoted reference", Directory.GetFiles(Path.Combine(root.DirectoryPath, "attachments", draft.Id), "*.png").Length == 1 && input.Last().EndsWith("'\u001b[201~", StringComparison.Ordinal));
      foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        pane.RequestedTheme = theme; await Task.Delay(400); await Capture(pane, webview, root, "terminal-native-" + theme + ".png"); frames.Add("terminal-native-" + theme + ".png");
      }
      Check("terminal fixture never sends an automatic clear, new or Return", input.Count == 3 && input.All(t => !t.EndsWith('\r')));
      File.WriteAllText(Path.Combine(root.DirectoryPath, "result.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, passed, frames, runtime = "absent", providerProcesses = 0, clipboardReads = 0, clipboardWrites = 0, syntheticDataPackages = true }, new JsonSerializerOptions { WriteIndented = true }));
    }
    catch (Exception ex) { File.WriteAllText(Path.Combine(root.DirectoryPath, "failure.txt"), ex.ToString()); }
    finally { pane?.DisposeView(); window?.Close(); Exit(); }
  }
  private static async Task Until(Func<bool> ready) { var deadline = DateTimeOffset.UtcNow.AddSeconds(8); while (!ready()) { if (DateTimeOffset.UtcNow > deadline) throw new TimeoutException("The native terminal bridge did not respond."); await Task.Delay(50); } }
  private static IEnumerable<DependencyObject> Tree(DependencyObject root) { yield return root; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) foreach (var child in Tree(VisualTreeHelper.GetChild(root, i))) yield return child; }
  private static async Task Capture(SessionPane pane, WebView2 view, AppDataRoot root, string file)
  {
    using var preview = new InMemoryRandomAccessStream(); await view.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, preview); preview.Seek(0);
    var source = new BitmapImage(); await source.SetSourceAsync(preview); var image = new Image { Source = source, Stretch = Stretch.Fill };
    var parent = (Panel)VisualTreeHelper.GetParent(view); var index = parent.Children.IndexOf(view); Grid.SetRow(image, Grid.GetRow(view)); parent.Children.RemoveAt(index); parent.Children.Insert(index, image);
    try
    {
      pane.UpdateLayout(); var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync(pane); var pixels = await bitmap.GetPixelsAsync(); using var reader = DataReader.FromBuffer(pixels); var bytes = new byte[pixels.Length]; reader.ReadBytes(bytes);
      using var output = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output); encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, bytes); await encoder.FlushAsync(); output.Seek(0); using var stream = output.AsStreamForRead(); using var destination = File.Create(Path.Combine(root.DirectoryPath, file)); await stream.CopyToAsync(destination);
    }
    finally { parent.Children.Remove(image); parent.Children.Insert(index, view); }
  }
}
