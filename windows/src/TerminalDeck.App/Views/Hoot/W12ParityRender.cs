#if TD_W12_SERVERS_RECEIVER_HOOT
using System.Reflection;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using TerminalDeck.App.Views.Receiver;
using TerminalDeck.App.Views.Servers;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Storage;
using System.Text;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace TerminalDeck.App.Views.Hoot;

internal static class W12ParityProgram
{
  [STAThread] public static void Main()
  {
    WinRT.ComWrappersSupport.InitializeComWrappers();
    Application.Start(initialization =>
    {
      SynchronizationContext.SetSynchronizationContext(new Microsoft.UI.Dispatching.DispatcherQueueSynchronizationContext(Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread()));
      _ = new W12ParityApplication();
    });
  }
}
internal sealed class W12ParityApplication : global::TerminalDeck.App.App
{
  protected override async void OnLaunched(LaunchActivatedEventArgs args)
  {
    var output = Environment.GetEnvironmentVariable("TD_W12_LANE_OUT") ?? throw new ArgumentException("Set a scratch render path.");
    Directory.CreateDirectory(output); var checks = new List<string>(); Window? window = null;
    try
    {
      window = new Window { Title = "W12 Servers Receiver Hoot · synthetic offscreen fixture" };
      window.AppWindow.Move(new Windows.Graphics.PointInt32(-14000, -14000));
      var host = new Grid(); window.Content = host; window.AppWindow.Show(false);
      foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        host.RequestedTheme = theme;
        foreach (var width in new[] { 1100, 620 })
        {
          window.AppWindow.Resize(new Windows.Graphics.SizeInt32(width, 860));
          foreach (var (name, page) in new (string, FrameworkElement)[]
          {
            ("server-apps", ServersParityFixture.Create("Apps")), ("servers", ServersParityFixture.Create()), ("server-health", ServersParityFixture.Create("Health")), ("server-files", ServersParityFixture.Create("Files")),
            ("receiver-events", ReceiverParityFixture.Inbox()), ("artifacts", ReceiverParityFixture.Artifacts()),
            ("hoot", new HootPage(DispatchProxy.Create<IHoot, W12HootFixture>(), () => [W12HootFixture.Account], () => []))
          })
          {
            host.Children.Clear(); host.Children.Add(page); await Task.Delay(250);
            await Save(host, output, name + "-" + width + "-" + theme.ToString().ToLowerInvariant());
            if (page is ServersPage servers && name == "server-apps")
            {
              Invoke(Tree(servers).OfType<Button>().First(b => b.Content as string == "Logs")); await Task.Delay(100);
              if (servers.Model.LogsAppId is null) throw new InvalidOperationException("Logs did not open through the server model");
              Invoke(Tree(servers).OfType<Button>().Single(b => b.Content as string == "Show older")); await Task.Delay(100);
              await Save(host, output, "server-logs-" + width + "-" + theme.ToString().ToLowerInvariant());
              Invoke(Tree(servers).OfType<Button>().Single(b => b.Content as string == "Hide logs")); await Task.Delay(100);
              if (servers.Model.Preview.Length != 0) throw new InvalidOperationException("Hide logs left the preview open");
              checks.Add("Server logs open, show older and hide " + width + " " + theme);
            }
            if (page is HootPage hootSettings)
            {
              Invoke(Tree(hootSettings).OfType<Button>().Single(b => b.Content is string title && title.StartsWith("GPT-6.1", StringComparison.Ordinal))); await Task.Delay(250);
              var settings = VisualTreeHelper.GetOpenPopupsForXamlRoot(page.XamlRoot).Select(p => p.Child).OfType<ContentDialog>().FirstOrDefault();
              if (settings is null) throw new InvalidOperationException("Hoot model settings did not open");
              await Save(settings, output, "hoot-models-" + width + "-" + theme.ToString().ToLowerInvariant()); settings.Hide();
              checks.Add("Hoot model catalogue dialog renders " + width + " " + theme);
            }
            if (page is ReceiverPage receiver)
            {
              receiver.ShowSection("Flow"); await Task.Delay(120); await Save(host, output, "receiver-flow-" + width + "-" + theme.ToString().ToLowerInvariant());
              receiver.ShowSection("Rules"); await Task.Delay(100);
              var add = Tree(receiver).OfType<Button>().Single(b => b.Content as string == "Add rule"); Invoke(add); await Task.Delay(150);
              var dialog = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(page.XamlRoot).Select(p => p.Child).OfType<ContentDialog>().FirstOrDefault();
              if (dialog is not null)
              {
                var button = Tree(dialog).OfType<Button>().Single(b => b.Content as string == "Add condition"); Invoke(button); await Task.Delay(100);
                await Save(dialog, output, "receiver-condition-" + width + "-" + theme.ToString().ToLowerInvariant()); dialog.Hide();
                checks.Add("Condition editor renders " + width + " " + theme);
              }
            }
            if (page is HootPage hoot) hoot.Dispose();
            checks.Add(name + " rendered " + width + " " + theme);
          }
        }
      }
      var nativeRoot = Path.Combine(output, "native-fixtures"); Directory.CreateDirectory(nativeRoot);
      File.WriteAllText(Path.Combine(nativeRoot, "page.html"), "<style>body{font:24px sans-serif;padding:24px;color:#224466}</style><h1>Artifact page preview</h1><p>A static page made by a session.</p><script>document.body.innerHTML='SCRIPT RAN'</script>");
      MakePdf(Path.Combine(nativeRoot, "report.pdf"));
      using (var wave = new BinaryWriter(File.Create(Path.Combine(nativeRoot, "recording.wav"))))
      {
        wave.Write(Encoding.ASCII.GetBytes("RIFF")); wave.Write(36 + 16000); wave.Write(Encoding.ASCII.GetBytes("WAVEfmt "));
        wave.Write(16); wave.Write((short)1); wave.Write((short)1); wave.Write(8000); wave.Write(16000); wave.Write((short)2); wave.Write((short)16);
        wave.Write(Encoding.ASCII.GetBytes("data")); wave.Write(16000); wave.Write(new byte[16000]);
      }
      var index = new ReceiverArtifacts(new JsonStateStore<ReceiverArtifactState>(AppDataRoot.Explicit(nativeRoot), "catalog"), _ => "fixture", (_, _) => ValueTask.CompletedTask, (_, _, _) => ValueTask.CompletedTask);
      window.AppWindow.Resize(new Windows.Graphics.SizeInt32(1000, 760));
      foreach (var name in new[] { "report.pdf", "page.html", "recording.wav" })
      {
        index.Record(nativeRoot, name, "fixture-session", DateTimeOffset.UtcNow);
        using var surface = new ArtifactPreviewSurface(index.Preview(nativeRoot, name));
        host.Children.Clear(); host.Children.Add(surface); await surface.Ready.WaitAsync(TimeSpan.FromSeconds(25));
        if (surface.Problem is not null) throw new InvalidOperationException(name + " preview failed: " + surface.Problem);
        await Task.Delay(300); await Save(host, output, "native-preview-" + name.Replace('.', '-'));
        if (name.EndsWith(".html", StringComparison.Ordinal))
        {
          var text = await surface.PageTextAsync();
          if (!text.Contains("Artifact page preview", StringComparison.Ordinal) || text.Contains("SCRIPT RAN", StringComparison.Ordinal)) throw new InvalidOperationException("HTML page did not render safely");
          await File.WriteAllBytesAsync(Path.Combine(output, "native-preview-html-content.png"), await surface.CapturePageAsync());
          checks.Add("HTML renders its page while embedded script stays disabled");
        }
        if (name.EndsWith(".pdf", StringComparison.Ordinal))
        {
          var next = Tree(surface).OfType<Button>().Single(b => b.Content as string == "Next page"); Invoke(next); await Task.Delay(300);
          if (!Tree(surface).OfType<TextBlock>().Any(t => t.Text == "Page 2 of 2")) throw new InvalidOperationException("PDF next-page navigation did not finish");
          await Save(host, output, "native-preview-pdf-page-2"); checks.Add("PDF opens and navigates both pages");
        }
        checks.Add("Native preview " + name + " opens without fallback");
      }
      await File.WriteAllTextAsync(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, checks, failed = Array.Empty<string>(), synthetic = true, liveData = false }));
    }
    catch (Exception ex) { await File.WriteAllTextAsync(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, checks, failed = new[] { ex.ToString() } })); }
    finally { window?.Close(); Exit(); }
  }
  private static void MakePdf(string path)
  {
    var objects = new[]
    {
      "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 250] /Resources << /Font << /F1 7 0 R >> >> /Contents 5 0 R >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 400 250] /Resources << /Font << /F1 7 0 R >> >> /Contents 6 0 R >>",
      "", "", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    };
    for (var page = 0; page < 2; page++)
    {
      var stream = $"BT /F1 22 Tf 35 160 Td (Artifact report - page {page + 1}) Tj ET";
      objects[4 + page] = $"<< /Length {Encoding.ASCII.GetByteCount(stream)} >>\nstream\n{stream}\nendstream";
    }
    var document = new StringBuilder("%PDF-1.4\n"); var offsets = new List<int>();
    for (var i = 0; i < objects.Length; i++) { offsets.Add(Encoding.ASCII.GetByteCount(document.ToString())); document.Append($"{i + 1} 0 obj\n{objects[i]}\nendobj\n"); }
    var xref = Encoding.ASCII.GetByteCount(document.ToString()); document.Append($"xref\n0 {objects.Length + 1}\n0000000000 65535 f \n");
    foreach (var offset in offsets) document.Append(offset.ToString("D10") + " 00000 n \n");
    document.Append($"trailer\n<< /Size {objects.Length + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n"); File.WriteAllText(path, document.ToString(), Encoding.ASCII);
  }
  private static IEnumerable<DependencyObject> Tree(DependencyObject root)
  { yield return root; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) foreach (var child in Tree(VisualTreeHelper.GetChild(root, i))) yield return child; }
  private static void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
  private static async Task Save(FrameworkElement page, string output, string name)
  {
    page.UpdateLayout(); var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync(page); var pixels = await bitmap.GetPixelsAsync();
    using var stream = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
    using var reader = DataReader.FromBuffer(pixels); var bytes = new byte[pixels.Length]; reader.ReadBytes(bytes);
    encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, bytes); await encoder.FlushAsync();
    stream.Seek(0); using var encoded = new DataReader(stream.GetInputStreamAt(0)); await encoded.LoadAsync((uint)stream.Size); var data = new byte[checked((int)stream.Size)]; encoded.ReadBytes(data);
    await File.WriteAllBytesAsync(Path.Combine(output, name + ".png"), data);
  }
}
public class W12HootFixture : DispatchProxy
{
  internal static AccountProfile Account { get; } = new("fixture", "codex", "Personal", null, AccountAuthentication.Subscription, true, "fixture");
  protected override object? Invoke(MethodInfo? method, object?[]? args) => method!.Name switch
  {
    "Read" => HootState.Empty with { Settings = new("codex", "fixture", "C:\\fixture", new("GPT-6.1", "high")), Lines = [new(1, "user", "person", "Check the Windows parity work.", DateTimeOffset.UtcNow), new(2, "assistant", "answer", "The focused checks passed. The current conversation stays until you choose New chat.", DateTimeOffset.UtcNow)] },
    "ModelsAsync" => ValueTask.FromResult<IReadOnlyList<ProviderModel>>([new("GPT-6.1", "GPT-6.1", 200000)]),
    "add_Changed" or "remove_Changed" => null,
    _ when method.ReturnType == typeof(ValueTask) => ValueTask.CompletedTask,
    _ => throw new NotSupportedException(method.Name)
  };
}
#endif
