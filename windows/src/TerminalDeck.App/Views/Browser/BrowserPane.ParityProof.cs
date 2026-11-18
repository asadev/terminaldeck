using System.Text.Json;
using System.Runtime.CompilerServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Media;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;
using TerminalDeck.Core.Browser;

namespace TerminalDeck.App.Views;

public sealed partial class BrowserPane
{
  private static IEnumerable<FrameworkElement> BrowserProofElements(DependencyObject node)
  {
    if (node is FrameworkElement element) yield return element;
    for (var index = 0; index < VisualTreeHelper.GetChildrenCount(node); index++)
      foreach (var child in BrowserProofElements(VisualTreeHelper.GetChild(node, index))) yield return child;
  }
  // Explicit one-run fixture for the release runner. It only changes a marked
  // scratch data root and writes the exact captures used to judge the pixels.
  internal async Task RunBrowserParityProofIfRequestedAsync()
  {
    if (Environment.GetEnvironmentVariable("TD_BROWSER_PARITY_PROOF") != "1") return;
    if (!File.Exists(Path.Combine(root.DirectoryPath, ".browser-parity-proof"))) throw new IOException("Browser parity proof requires a marked scratch data folder.");
    var output = Path.Combine(root.DirectoryPath, "proof", "browser-parity"); Directory.CreateDirectory(output);
    var checks = new List<object>(); var errors = new List<string>();
    void Check(string name, bool passed) => checks.Add(new { name, passed });
    void Stage(string name) => File.WriteAllText(Path.Combine(output, "stage.txt"), name);
    async Task Wait(Func<bool> condition, [CallerArgumentExpression(nameof(condition))] string waitingFor = "")
    {
      var end = DateTimeOffset.UtcNow.AddSeconds(15);
      while (!condition()) { if (DateTimeOffset.UtcNow >= end) throw new TimeoutException("Browser parity fixture did not settle: " + waitingFor); await Task.Delay(50); }
    }
    try
    {
      await Task.Delay(500);
      var app = AppWindow.GetFromWindowId(XamlRoot.ContentIslandEnvironment.AppWindowId);
      await using var fixture = new BrowserProofServer();
      Stage("open"); var page = await Core.OpenAsync(fixture.Url); var tab = tabs.Single(t => t.Id == page.Id);
      ObserveShellPages(); ShellSelected?.Invoke(tab.Id); Stage("open-shell-slot"); await Wait(() => pageSlots.ContainsKey(tab.Id));
      Stage("open-drawn"); await Wait(() => IsDrawn(pageSlots[tab.Id]));
      var web = tab.View.CoreWebView2; var pageRoot = tab.View.XamlRoot; var pageParent = tab.View.Parent;
      await tab.Model.CommandAsync("Runtime.evaluate", new { expression = "window.__tdProofIdentity='kept'; document.getElementById('target').onclick=()=>document.body.dataset.clicked='yes'" });
      Stage("bookmarks"); var bookmark = await Core.AddBookmarkAsync(tab.Profile.Id, fixture.Url, "Fixture bookmark");
      Check("bookmark round trip", Core.Bookmarks(tab.Profile.Id).Any(b => b.Id == bookmark.Id)); await Core.ShowBookmarkBarAsync(tab.Profile.Id, true);
      Stage("background"); var other = await Core.OpenAsync(fixture.Url + "next"); ObserveShellPages(); ShellSelected?.Invoke(other.Id);
      Stage("background-other-drawn"); await Wait(() => pageSlots.TryGetValue(other.Id, out var otherSlot) && IsDrawn(otherSlot));
      Stage("background-original-parked"); await Wait(() => parkedPages.ContainsKey(tab.Id));
      Check("hidden page retains its original parent, XamlRoot and controller", ReferenceEquals(pageParent, tab.View.Parent) && ReferenceEquals(pageRoot, tab.View.XamlRoot) && ReferenceEquals(web, tab.View.CoreWebView2));
      var state = await Core.PerformAsync(tab.Id, BrowserPageAction.Read, JsonSerializer.SerializeToElement(new { selector = "h1" }));
      Check("hidden tab read", state.GetRawText().Contains("Browser parity fixture", StringComparison.Ordinal));
      await Core.PerformAsync(tab.Id, BrowserPageAction.Step, JsonSerializer.SerializeToElement(new { verb = "type", selector = "#ordinary", value = "Background typed text" }));
      await Core.PerformAsync(tab.Id, BrowserPageAction.Step, JsonSerializer.SerializeToElement(new { verb = "click", selector = "#target" }));
      var kept = await tab.Model.CommandAsync("Runtime.evaluate", new { expression = "window.__tdProofIdentity==='kept' && document.body.dataset.clicked==='yes' && document.getElementById('ordinary').value==='Background typed text'", returnByValue = true });
      Check("hidden tab click and type retain document", kept.GetProperty("result").GetProperty("value").GetBoolean());
      async Task Capture(string name)
      {
        var bytes = await CaptureAsync(tab); await File.WriteAllBytesAsync(Path.Combine(output, name + ".png"), bytes);
        using var stream = new InMemoryRandomAccessStream(); using (var writer = new DataWriter(stream.GetOutputStreamAt(0))) { writer.WriteBytes(bytes); await writer.StoreAsync(); } stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream); var pixels = (await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight, new BitmapTransform(), ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage)).DetachPixelData();
        Check(name + " is a nonblank finite image", decoder.PixelWidth > 100 && decoder.PixelHeight > 100 && pixels.Where((_, index) => index % 4 != 3).Distinct().Take(16).Count() >= 16);
        if (name == "minimised-window") Check("minimised picture contains the newly painted red background", Enumerable.Range(0, pixels.Length / 4).Count(index => Math.Abs(pixels[index * 4] - 76) <= 2 && Math.Abs(pixels[index * 4 + 1] - 76) <= 2 && Math.Abs(pixels[index * 4 + 2] - 234) <= 2) > pixels.Length / 40);
      }
      await Capture("hidden-tab");
      Stage("background-question");
      await tab.Model.CommandAsync("Runtime.evaluate", new { expression = "(()=>{const b=document.createElement('button');b.id='question';b.textContent='Question';b.onclick=()=>window.__tdAnswer=confirm('Fixture question');document.body.append(b)})()" });
      try { await Core.PerformAsync(tab.Id, BrowserPageAction.Step, JsonSerializer.SerializeToElement(new { verb = "click", selector = "#question" })); Check("hidden question returns waiting instead of answering", false); }
      catch (InvalidOperationException waiting) { Check("hidden question returns waiting instead of answering", waiting.Message.Contains("Waiting for you:", StringComparison.Ordinal)); }
      Check("hidden question leaves selected tab unchanged", Core.Read().SelectedTabId == other.Id);
      Check("original hidden question is retained", pageQuestions.TryGetValue(tab.Id, out var pendingQuestions) && pendingQuestions.Count == 1);
      await Core.PerformAsync(tab.Id, BrowserPageAction.WorkspaceChange, JsonSerializer.SerializeToElement(new { command = "questionCancel" })); await Wait(() => !pageQuestions.ContainsKey(tab.Id));
      var answer = await tab.Model.CommandAsync("Runtime.evaluate", new { expression = "window.__tdAnswer===false", returnByValue = true }); Check("explicit cancel answers the original question", answer.GetProperty("result").GetProperty("value").GetBoolean());
      Stage("minimised"); if (app.Presenter is not OverlappedPresenter presenter) throw new InvalidOperationException("The fixture needs an ordinary desktop window.");
      presenter.Minimize(); await Wait(() => presenter.State == OverlappedPresenterState.Minimized);
      await Core.PerformAsync(tab.Id, BrowserPageAction.Step, JsonSerializer.SerializeToElement(new { verb = "type", selector = "#ordinary", value = "Minimised typed text" }));
      await tab.Model.CommandAsync("Runtime.evaluate", new { expression = "document.body.style.background='rgb(234,76,76)'; document.documentElement.style.background='rgb(234,76,76)'; document.querySelector('h1').textContent='Updated while minimised'" });
      var minimisedState = await Core.PerformAsync(tab.Id, BrowserPageAction.Read, JsonSerializer.SerializeToElement(new { selector = "h1" }));
      Check("minimised page reads its new content", minimisedState.GetRawText().Contains("Updated while minimised", StringComparison.Ordinal));
      await Capture("minimised-window");
      Check("capture leaves the person’s window minimised", presenter.State == OverlappedPresenterState.Minimized);
      presenter.Restore(false); await Core.TakeHumanControlAsync(tab.Id);
      Stage("popup-protocol");
      var popupOperation = tab.Model.CommandAsync("Runtime.evaluate", new { expression = "window.open('/next','td-fixture-popup'); true", returnByValue = true });
      await popupOperation.WaitAsync(TimeSpan.FromSeconds(15)); await Wait(() => Core.Read().Tabs.Length >= 3);
      var popupTab = tabs.Last(t => t.Id != tab.Id && t.Id != other.Id); await Wait(() => popupTab.View.CoreWebView2.Source.EndsWith("/next", StringComparison.Ordinal));
      var opener = await popupTab.Model.CommandAsync("Runtime.evaluate", new { expression = "!!window.opener && window.opener.__tdProofIdentity==='kept'", returnByValue = true });
      Check("popup preserves opener protocol", opener.GetProperty("result").GetProperty("value").GetBoolean());
      Stage("unsupported-popup"); await tab.Model.CommandAsync("Runtime.evaluate", new { expression = "window.open('file:///C:/unsupported','td-refused-popup'); true" }); await Wait(() => tab.PageRequestNote is not null);
      Check("unsupported popup reports plain reason", tab.PageRequestNote!.Contains("unsupported", StringComparison.OrdinalIgnoreCase)); tab.PageRequestNote = null;
      Stage("restore"); ShellSelected?.Invoke(tab.Id); await Wait(() => !parkedPages.ContainsKey(tab.Id));
      Check("selection restores the same WebView", ReferenceEquals(web, tab.View.CoreWebView2));
      var priorChoices = SessionChoices; SessionChoices = () => [new("browser", "Fixture session")]; await Core.AttachAsync(tab.Id, "browser");
      await Core.CreateProfileAsync("Fixture Work"); RefreshShellViews();
      foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        var frame = (FrameworkElement)RootFor(tab).Content; frame.RequestedTheme = theme; await Task.Delay(150);
        var suffix = theme.ToString().ToLowerInvariant();
        await ProofFrameAsync(frame, tab, Path.Combine(output, "browser-" + suffix + ".png"));
        var panel = ShellView(tab.Id);
        foreach (var (name, label) in new[] { ("profile", "Browser profile and actions"), ("more", "More browser actions"), ("connect", "Connect") })
        {
          var anchor = BrowserProofElements(panel).OfType<Button>().First(button => AutomationProperties.GetName(button) == label);
          var menuPopup = anchor.Flyout ?? throw new InvalidOperationException("The browser menu is missing."); menuPopup.ShowAt(anchor); await Task.Delay(150);
          var drawn = VisualTreeHelper.GetOpenPopupsForXamlRoot(panel.XamlRoot).Select(open => open.Child).OfType<FrameworkElement>().Where(child => child.ActualWidth > 0 && child.ActualHeight > 0 && child is not ToolTip).Last();
          await File.WriteAllBytesAsync(Path.Combine(output, name + "-" + suffix + ".png"), await RenderPngAsync(drawn, (int)drawn.ActualWidth, (int)drawn.ActualHeight)); menuPopup.Hide();
        }
        var previousWidth = panel.Width; var previousAlignment = panel.HorizontalAlignment;
        panel.Width = 380; panel.HorizontalAlignment = HorizontalAlignment.Left; frame.UpdateLayout(); await Task.Delay(150);
        await ProofFrameAsync(panel, tab, Path.Combine(output, "browser-narrow-" + suffix + ".png"));
        Check("380px " + suffix + " toolbar stays inside the pane", BrowserProofElements(panel).OfType<Button>().Where(button => AutomationProperties.GetName(button) is "More browser actions" or "Browser profile and actions").All(button => button.TransformToVisual(panel).TransformPoint(new(0, 0)).X + button.ActualWidth <= 380));
        panel.Width = previousWidth; panel.HorizontalAlignment = previousAlignment;
      }
      SessionChoices = priorChoices;
      Stage("complete");
    }
    catch (Exception ex) when (ex is not OutOfMemoryException)
    {
      errors.Add(ex.ToString());
      try
      {
        var state = new { selected = Core.Read().SelectedTabId, parked = parkedPages.Keys.ToArray(), slots = pageSlots.Select(pair => new { id = pair.Key, drawn = IsDrawn(pair.Value), loaded = pair.Value.IsLoaded, width = pair.Value.ActualWidth, height = pair.Value.ActualHeight, root = pair.Value.XamlRoot is not null, parent = VisualTreeHelper.GetParent(pair.Value)?.GetType().Name }).ToArray() };
        await File.WriteAllTextAsync(Path.Combine(output, "failure-state.json"), JsonSerializer.Serialize(state, new JsonSerializerOptions { WriteIndented = true }));
        if (XamlRoot?.Content is FrameworkElement frame)
        {
          var visible = tabs.FirstOrDefault(candidate => pageSlots.TryGetValue(candidate.Id, out var slot) && IsDrawn(slot));
          if (visible is not null) await ProofFrameAsync(frame, visible, Path.Combine(output, "failure-frame.png")).WaitAsync(TimeSpan.FromSeconds(10));
          else await File.WriteAllBytesAsync(Path.Combine(output, "failure-frame.png"), await RenderPngAsync(frame, (int)frame.ActualWidth, (int)frame.ActualHeight).WaitAsync(TimeSpan.FromSeconds(10)));
        }
      }
      catch (Exception captureError) when (captureError is not OutOfMemoryException) { errors.Add("Failure frame: " + captureError); }
    }
    finally
    {
      await File.WriteAllTextAsync(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, checks, errors }, new JsonSerializerOptions { WriteIndented = true }));
      Application.Current.Exit();
    }
  }
}
