using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.Web.WebView2.Core;
using TerminalDeck.App.Shell;
using TerminalDeck.App.ViewModels;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Settings;
using TerminalDeck.Core.Storage;
using TerminalDeck.Platform.Windows;

namespace TerminalDeck.App.Views;

// Uses the real component tree without constructing AppRuntime or opening an account.
internal sealed class UmerPortsProofWindow : Window
{
  internal UmerPortsProofWindow(AppDataRoot data, string output)
  {
    var root = new Grid();
    root.SetResourceReference(Grid.BackgroundProperty, "DeckTopBarBrush");
    root.RowDefinitions.Add(new() { Height = new(40) }); root.RowDefinitions.Add(new() { Height = new(1, GridUnitType.Star) });
    var title = new Grid(); title.ColumnDefinitions.Add(new() { Width = new(1, GridUnitType.Star) }); title.ColumnDefinitions.Add(new() { Width = new(138) });
    var caption = new Grid(); Grid.SetColumn(caption, 1); title.Children.Add(caption); root.Children.Add(title);
    Content = root; AppWindow.Resize(new(1100, 760)); AppWindow.Move(new(-20000, -20000));
    _ = new WorkspaceTitleBar(this, root, title, caption);
    root.Loaded += async (_, _) =>
    {
      Directory.CreateDirectory(output);
      var passed = new List<string>(); var failed = new List<string>(); var panes = new Dictionary<string, SessionPane>();
      void Check(string name, bool ok) => (ok ? passed : failed).Add(name);
      try
      {
        var state = new WorkspaceState(); var rows = new Dictionary<string, SessionDraft>();
        var activeOwner = "a";
        WorkspaceSurface surface = null!;
        void Render() => surface.RenderPanes(activeOwner);
        surface = new(state, "main", tab => panes[tab.Id], (owner, _) => { activeOwner = owner; Render(); },
          _ => Task.CompletedTask, _ => Task.CompletedTask, _ => { }, _ => { }, _ => { }, (_, _) => Task.CompletedTask,
          _ => "", _ => data.DirectoryPath, tab => rows[tab.Id], (_, _) => Task.CompletedTask, _ => Task.CompletedTask, failed.Add);
        surface.Batch = work => { work(); Render(); };
        Grid.SetRow(surface, 1); root.Children.Add(surface); title.Children.Add(surface.Header);
        foreach (var id in new[] { "a", "b" })
        {
          var row = new SessionDraft("Folder " + id, "shell", data.DirectoryPath, SessionPresentation.Terminal) { Id = id, IsLive = true, Shell = "powershell", State = "running" };
          rows[id] = row; panes[id] = new(row, data, failed.Add, () => { }); state.Ensure(id, id, id, "terminal", row.Title);
        }
        state.Select("a"); surface.Render("a");
        await panes["a"].Ready.WaitAsync(TimeSpan.FromSeconds(30)); await Task.Delay(200);
        var frame = surface.UmerPaneForProof("a"); var button = surface.UmerTabForProof("a");
        void Select(string id) => ((IInvokeProvider)new ButtonAutomationPeer(surface.UmerTabForProof(id)).GetPattern(PatternInterface.Invoke)).Invoke();
        Select("b"); await panes["b"].Ready.WaitAsync(TimeSpan.FromSeconds(30));
        Select("a"); await Task.Delay(300);
        Check("PR4 switching back retains the same pane and tab controls", ReferenceEquals(frame, surface.UmerPaneForProof("a")) && ReferenceEquals(button, surface.UmerTabForProof("a")));
        var web = WorkspaceVisuals.Tree(panes["a"]).OfType<WebView2>().Single();
        Check("PR3 tab selection focuses the real xterm input", await web.CoreWebView2.ExecuteScriptAsync("document.activeElement?.classList.contains('xterm-helper-textarea')") == "true");
        web.CoreWebView2.PostWebMessageAsJson(JsonSerializer.Serialize(new { type = "data", data = "Terminal text: ❯ Hello from the isolated proof\r\nGrayscale glyphs: ABC abc 0123 ☼ €\r\n" }));
        var before = state.Tabs.Select(t => t.Id).ToArray();
        surface.UmerSlideForProof("a", 1000);
        Check("PR4 sliding commits the reordered tabs", before[0] == "a" && state.Tabs.Last().Id == "a");
        surface.Render("a"); await Task.Delay(200);
        rows["a"].ObserveStatus("exited"); await Task.Delay(200);
        var notice = WorkspaceVisuals.Tree(panes["a"]).OfType<Notices.CompactNotice>().Single();
        Check("PR8 an ended terminal keeps a dismissible notice", notice.IsOpen && !notice.AutoDismiss && notice.Message.Contains("has ended"));
        var settings = new GeneralSettings(new JsonStateStore<GeneralPreferences>(data, "general-settings"));
        var picker = Settings.TerminalShellChoice.Create(settings, work => work());
        title.Children.Add(picker); picker.HorizontalAlignment = HorizontalAlignment.Right; picker.Margin = new(0, 0, 160, 0);
        picker.SelectedIndex = Array.IndexOf(TerminalShells.All, "cmd"); await Task.Delay(100);
        Check("PR6 the real shell picker saves Command Prompt", settings.Read().TerminalShell == "cmd");
        var planner = new WindowsProviderLaunchPlanner(data, AppContext.BaseDirectory);
        var definition = new SessionDefinition(Guid.NewGuid().ToString(), "shell", data.DirectoryPath, "Scratch", Shell: settings.Read().TerminalShell);
        var launch = planner.Plan(new(definition, "proof", SessionState.Starting), false);
        Check("PR6 new shell plan is cmd; existing terminal keeps PowerShell", launch.Executable.EndsWith("cmd.exe", StringComparison.OrdinalIgnoreCase) && rows["a"].Shell == "powershell");
        using (var cancellation = new CancellationTokenSource(TimeSpan.FromSeconds(15)))
        {
          await using var terminal = await new ConPtyTerminalFactory().StartAsync(launch, new(100, 30), cancellation.Token);
          await terminal.WriteAsync(System.Text.Encoding.UTF8.GetBytes("echo TD_UMER_SHELL_OK\r"), cancellation.Token);
          var text = "";
          await foreach (var bytes in terminal.ReadOutputAsync(cancellation.Token))
          {
            text += System.Text.Encoding.UTF8.GetString(bytes.Span);
            if (text.Contains("TD_UMER_SHELL_OK")) break;
          }
          Check("PR6 the chosen shell actually starts", text.Contains("TD_UMER_SHELL_OK"));
          await terminal.QuitAsync(cancellation.Token);
        }
        var icon = (DeckIcon)WorkspaceSurface.IconButton("Proof", "more", () => { }).Content;
        Check("PR5 shared toolbar icons use 16 DIP", icon.FontSize == 16);
        root.UpdateLayout(); await Task.Delay(300);
        Check("PR1 title-bar controls are passthrough regions", (Microsoft.UI.Input.InputNonClientPointerSource.GetForWindowId(AppWindow.Id).GetRegionRects(Microsoft.UI.Input.NonClientRegionKind.Passthrough)?.Length ?? 0) > 0);
        foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
        {
          root.RequestedTheme = theme; picker.RequestedTheme = theme; await Task.Delay(300);
          Check(theme + " retained selected tab uses the terminal ink", ReferenceEquals(surface.UmerTabForProof("a").Foreground, ShellTheme.Resource(surface.Header, WorkspacePaper.Ink)));
          var close = WorkspaceVisuals.Tree(surface.Header).OfType<Button>().Single(b => Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(b) == "Close Folder a");
          Check(theme + " close icon uses its button ink", close.Content is DeckIcon closeIcon && ReferenceEquals(closeIcon.Foreground, close.Foreground));
          await CaptureAsync(root, Path.Combine(output, "frame-" + theme + ".png"));
          using var preview = File.Create(Path.Combine(output, "terminal-" + theme + ".png"));

          await web.CoreWebView2.CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat.Png, preview.AsRandomAccessStream());
        }
      }
      catch (Exception error) { failed.Add(error.ToString()); }
      finally
      {
        foreach (var pane in panes.Values) pane.DisposeView();
        await File.WriteAllTextAsync(Path.Combine(output, "ui-result.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, passed, failed, limitations = "Component script; no physical pointer gesture or OS activation injected into the person's desktop." }, new JsonSerializerOptions { WriteIndented = true }));
        Close();
      }
    };
  }
  private static async Task CaptureAsync(FrameworkElement element, string file)
  {
    var bitmap = new Microsoft.UI.Xaml.Media.Imaging.RenderTargetBitmap(); await bitmap.RenderAsync(element);
    var pixels = await bitmap.GetPixelsAsync(); var bytes = new byte[pixels.Length];
    using (var reader = Windows.Storage.Streams.DataReader.FromBuffer(pixels)) reader.ReadBytes(bytes);
    using var output = new Windows.Storage.Streams.InMemoryRandomAccessStream();
    var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, output);
    encoder.SetPixelData(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, bytes);
    await encoder.FlushAsync(); output.Seek(0); using var input = output.AsStreamForRead(); using var saved = File.Create(file); await input.CopyToAsync(saved);
  }
}
