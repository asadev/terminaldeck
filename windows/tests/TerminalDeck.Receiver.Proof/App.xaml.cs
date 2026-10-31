using System.Collections.Immutable;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TerminalDeck.App.ViewModels.Receiver;
using TerminalDeck.App.Views.Receiver;
using TerminalDeck.Core.Receiver;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows.Receiver;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics.Imaging;
using Windows.Storage;

namespace TerminalDeck.ReceiverProof;

public partial class App : Application
{
  private Window? window;
  public App() => InitializeComponent();
  protected override async void OnLaunched(LaunchActivatedEventArgs args)
  {
    var root = AppDataRoot.FromArguments(Environment.GetCommandLineArgs().Skip(1).ToArray());
    if (!root.DirectoryPath.StartsWith(@"C:\TD\", StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Use an isolated folder under C:\\TD.");
    var output = Path.GetDirectoryName(root.DirectoryPath)!; Directory.CreateDirectory(root.DirectoryPath);
    var checks = new List<object>(); var passed = 0; var failed = 0;
    void Check(string name, bool ok) { checks.Add(new { name, ok }); if (ok) passed++; else failed++; }
    void Write(string file, object value) => File.WriteAllText(Path.Combine(output, file), JsonSerializer.Serialize(value, new JsonSerializerOptions { WriteIndented = true }));
    try
    {
      if (Environment.GetEnvironmentVariable("TD_RECEIVER_CAPTURE_SOURCE") is { Length: > 0 } captureSource)
      {
        var savedRoot = AppDataRoot.Explicit(captureSource);
        var saved = new JsonStateStore<ReceiverState>(savedRoot, "receiver-proof").Load()
          ?? throw new IOException("The saved Receiver preview data is missing.");
        var selected = saved.Items.First(i => i.Title.StartsWith("Build report", StringComparison.Ordinal));
        var snapshot = saved with { Items = saved.Items.Replace(selected, selected with { Status = InboxStatus.Held, Outcome = "Ready for approval." }) };
        var captureReceiver = new ReceiverStore(new SnapshotStore(snapshot), new ProofDelivery());
        var capturePage = new ReceiverPage(new(captureReceiver, new ProofSettings()) { SelectedId = selected.Id }, new[] { ("proof", "Windows preview") });
        var captureFolder = Path.Combine(captureSource, "project");
        var captureIndex = new ReceiverArtifacts(new JsonStateStore<ReceiverArtifactState>(savedRoot, "artifacts-proof"), p => p == captureFolder ? "proof" : null, (_, _) => ValueTask.CompletedTask, (_, _, _) => ValueTask.CompletedTask);
        var captureArtifactsPage = new ArtifactsPage(captureIndex, captureReceiver, [new(captureFolder, "Windows preview", "proof")]);
        var captureFrame = new Grid(); window = new Window { Title = "Receiver · isolated preview", Content = captureFrame };
        window.AppWindow.Resize(new Windows.Graphics.SizeInt32(940, 680)); window.AppWindow.Move(new Windows.Graphics.PointInt32(20, 20));
        captureFrame.Children.Add(capturePage); window.Activate(); await Task.Delay(600);
        foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
        {
          captureFrame.RequestedTheme = theme;
          foreach (var section in new[] { "Inbox", "Sources", "Rules", "Intake" }) { capturePage.ShowSection(section); await Capture($"Full-{section}-{theme}"); }
          captureFrame.Children.Clear(); captureFrame.Children.Add(captureArtifactsPage); await Capture($"Full-Artifacts-{theme}"); captureFrame.Children.Clear(); captureFrame.Children.Add(capturePage);
        }
        Write("result.json", new { ok = true, passed = 0, failed = 0, frames = 10, scope = "Capture only, saved synthetic data, no passing checks repeated", at = DateTimeOffset.UtcNow }); return;
      }
      var delivery = new ProofDelivery(); var receiver = new ReceiverStore(new JsonStateStore<ReceiverState>(root, "receiver-proof"), delivery);
      foreach (var (id, kind) in new[] { ("share", IntakeKind.Share), ("drop", IntakeKind.Drop), ("browser", IntakeKind.Browser), ("clipboard", IntakeKind.Clipboard), ("phone", IntakeKind.Phone) })
        receiver.SaveSource(new(id, kind.ToString(), kind, "proof"));
      receiver.SaveRule(new("builds", "Build reports", "browser", "build", new(RouteKind.Session, "proof-session")));
      var files = new ReceiverFiles(root); var data = new WindowsReceiverData(receiver, files);
      var package = new DataPackage();
      var artifactsRoot = Path.Combine(root.DirectoryPath, "project"); Directory.CreateDirectory(artifactsRoot);
      File.WriteAllText(Path.Combine(artifactsRoot, "report.txt"), "Receiver verification\n\nText, links, files and screenshots arrive in an inbox.\nRouting waits for approval.\nArtifacts show only files sessions actually produced.\n");
      var imagePath = Path.Combine(artifactsRoot, "preview.png");
      var image = await StorageFile.GetFileFromPathAsync(await MakeImage(imagePath));
      if (Environment.GetEnvironmentVariable("TD_RECEIVER_RECLAIM_PROOF") == "1")
      {
        package = new DataPackage(); package.SetStorageItems(new[] { image });
        var first = await data.ReadAsync(package.GetView(), "drop", "Dismissed screenshot"); receiver.Dismiss(first.Id);
        package = new DataPackage(); package.SetText("Next shared item"); await data.ReadAsync(package.GetView(), "share", "New item");
        var removed = false;
        try { using var stream = files.Open(first.Files.Single()); } catch (FileNotFoundException) { removed = true; }
        Write("result.json", new { ok = removed && File.Exists(imagePath), passed = removed && File.Exists(imagePath) ? 1 : 0, failed = removed && File.Exists(imagePath) ? 0 : 1,
          check = "Dismissed copies are reclaimed without deleting the original shared file", at = DateTimeOffset.UtcNow }); Exit(); return;
      }
      package.SetText("Review the Windows receiver build report before sending it to the coding session."); package.SetWebLink(new Uri("https://example.test/build/42"));
      var item = await data.ReadAsync(package.GetView(), "browser", "Build report · Windows preview");
      Check("Windows text and link intake waits for approval", item.Status == InboxStatus.Held && item.Url == "https://example.test/build/42" && delivery.Count == 0);
      package = new DataPackage(); package.SetStorageItems(new[] { image });
      var pictureItem = await data.ReadAsync(package.GetView(), "drop", "Screenshot from another app");
      Check("Windows storage item copied before source closes", pictureItem.Files.Length == 1 && pictureItem.Files[0].Bytes > 0);
      package = new DataPackage(); package.SetBitmap(Windows.Storage.Streams.RandomAccessStreamReference.CreateFromFile(image));
      var bitmapItem = await data.ReadAsync(package.GetView(), "share", "Shared screenshot");
      Check("Windows bitmap becomes a PNG attachment", bitmapItem.Files.Single().Name == "Screenshot.png");
      var index = new ReceiverArtifacts(new JsonStateStore<ReceiverArtifactState>(root, "artifacts-proof"), p => p == artifactsRoot ? "proof" : null,
        (_, _) => ValueTask.CompletedTask, (_, _, _) => ValueTask.CompletedTask);
      index.Record(artifactsRoot, "report.txt", "proof-session", DateTimeOffset.UtcNow); index.Record(artifactsRoot, "preview.png", "proof-session", DateTimeOffset.UtcNow);
      var settings = new ProofSettings(); var model = new ReceiverViewModel(receiver, settings) { SelectedId = item.Id };
      var page = new ReceiverPage(model, new[] { ("proof", "Windows preview") }); var artifactsPage = new ArtifactsPage(index, receiver, [new(artifactsRoot, "Windows preview", "proof")]);
      var frame = new Grid(); window = new Window { Title = "Receiver · isolated preview", Content = frame }; window.AppWindow.Resize(new Windows.Graphics.SizeInt32(1120, 1000));
      frame.Children.Add(page); window.Activate(); await Task.Delay(700);
      using var drop = new ReceiverActivation(data, "share", "drop").BindDrop(frame); Check("Window root accepts drop intake", frame.AllowDrop);
      foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        frame.RequestedTheme = theme;
        foreach (var section in new[] { "Inbox", "Sources", "Rules", "Intake" })
        {
          page.ShowSection(section); await Capture($"{section}-{theme}");
          Check($"{section} {theme} fits the window", page.ActualWidth <= frame.ActualWidth + 1 && Tree(page).OfType<ScrollViewer>().All(s => s.ScrollableWidth < 1));
        }
        frame.Children.Clear(); frame.Children.Add(artifactsPage); await Capture($"Artifacts-{theme}");
        Check($"Artifacts {theme} has real output rows", Tree(artifactsPage).OfType<TextBlock>().Any(t => t.Text == "report.txt") && Tree(artifactsPage).OfType<Button>().Count(b => b.Content as string == "Preview") == 2);
        // Invoke the real Preview button, then close its real dialog.
        Invoke(Tree(artifactsPage).OfType<Button>().Last(b => b.Content as string == "Preview")); await Task.Delay(400); await Capture($"Preview-{theme}");
        var dialog = VisualTreeHelper.GetOpenPopupsForXamlRoot(frame.XamlRoot).SelectMany(p => Tree(p.Child)).OfType<ContentDialog>().First();
        Check($"Preview {theme} shows generated text", Tree(dialog).OfType<TextBlock>().Any(t => t.Text.Contains("Receiver verification", StringComparison.Ordinal))); dialog.Hide(); await Task.Delay(250);
        frame.Children.Clear(); frame.Children.Add(page);
      }
      page.ShowSection("Inbox"); await Task.Delay(200);
      Invoke(Tree(page).OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == "receiver.approve")); await Task.Delay(300);
      var approval = VisualTreeHelper.GetOpenPopupsForXamlRoot(frame.XamlRoot).SelectMany(p => Tree(p.Child)).OfType<ContentDialog>().First();
      Check("Approval opens before any session delivery", delivery.Count == 0 && approval.PrimaryButtonText == "Send"); await Capture("Approval-Dark");
      var primary = Tree(approval).OfType<Button>().Single(b => b.Name == "PrimaryButton"); Invoke(primary); await Task.Delay(500);
      Check("Confirmed UI action delivers once", delivery.Count == 1 && receiver.Item(item.Id).Status == InboxStatus.Delivered);
      var toggle = new ReceiverPage(new(receiver, settings), new[] { ("proof", "Windows preview") }); frame.Children.Clear(); frame.Children.Add(toggle); toggle.ShowSection("Intake"); await Task.Delay(100);
      Tree(toggle).OfType<ToggleSwitch>().Single(t => t.Header as string == "Watch clipboard").IsOn = true; await Task.Delay(250);
      Check("Clipboard opt-in control changes the settings engine", settings.Status.Clipboard);
      Check("Artifact preview returns text without running it", index.Preview(artifactsRoot, "report.txt").Text!.Contains("Receiver verification", StringComparison.Ordinal));
      Write("result.json", new { ok = failed == 0, passed, failed, checks, at = DateTimeOffset.UtcNow, scope = "Isolated Receiver pages and Windows data adapters. No install, clipboard access, real session, or share registration." });
    }
    catch (Exception ex) { Write("result.json", new { ok = false, passed, failed = failed + 1, checks, error = ex.GetType().Name + ": " + ex.Message, at = DateTimeOffset.UtcNow }); }
    async Task Capture(string name)
    {
      await Task.Delay(450); Write("stage.json", new { name }); var end = DateTime.UtcNow.AddSeconds(15);
      while (!File.Exists(Path.Combine(output, name + ".ack")) && DateTime.UtcNow < end) await Task.Delay(100);
      if (!File.Exists(Path.Combine(output, name + ".ack"))) throw new IOException("Screenshot capture did not acknowledge this frame.");
    }
  }
  private static void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
  private static IEnumerable<DependencyObject> Tree(DependencyObject node)
  {
    yield return node; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++) foreach (var child in Tree(VisualTreeHelper.GetChild(node, i))) yield return child;
  }
  private static async Task<string> MakeImage(string path)
  {
    await File.WriteAllBytesAsync(path, []);
    var file = await StorageFile.GetFileFromPathAsync(path);
    using var stream = await file.OpenAsync(FileAccessMode.ReadWrite); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
    var pixels = new byte[320 * 180 * 4];
    for (var y = 0; y < 180; y++) for (var x = 0; x < 320; x++) { var p = (y * 320 + x) * 4; pixels[p] = (byte)(100 + y / 2); pixels[p + 1] = (byte)(80 + x / 3); pixels[p + 2] = 30; pixels[p + 3] = 255; }
    encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, 320, 180, 96, 96, pixels); await encoder.FlushAsync(); return path;
  }
  private sealed class ProofDelivery : IReceiverDelivery
  {
    public int Count;
    public IReadOnlyList<ReceiverDestination> Destinations() => [new(new(RouteKind.Session, "proof-session"), "Receiver coding session", "proof"), new(new(RouteKind.Chat, "proof-chat"), "Review chat", "proof")];
    public ValueTask<DeliveryReceipt> DeliverAsync(ReceiverItem item, ReceiverTarget target, string key, CancellationToken ct) { Count++; return ValueTask.FromResult(new DeliveryReceipt(key, "Delivered to the preview session.")); }
  }
  private sealed class SnapshotStore(ReceiverState snapshot) : IStateStore<ReceiverState>
  {
    public ReceiverState? Load() => snapshot;
    public void Save(ReceiverState state) => throw new InvalidOperationException("Capture mode does not change saved data.");
  }
  private sealed class ProofSettings : IReceiverIntakeSettings
  {
    public ReceiverIntakeStatus Status { get; private set; } = new(false, false, null);
    public ValueTask ConfigureAsync(bool? clipboard, bool? browser, CancellationToken ct = default) { Status = new(clipboard ?? Status.Clipboard, browser ?? Status.Browser, null); return ValueTask.CompletedTask; }
  }
}
