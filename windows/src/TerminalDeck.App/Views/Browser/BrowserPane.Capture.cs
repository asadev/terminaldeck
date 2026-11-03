using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using TerminalDeck.Core.Browser;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Streams;
using Windows.System;

namespace TerminalDeck.App.Views;

internal sealed record BrowserAnnotation(int Number, string Url, string Selector, string Description);

public sealed partial class BrowserPane
{
  private async Task InspectAsync(BrowserTab tab, bool on)
  {
    tab.Inspecting = on;
    await tab.Model.CommandAsync("Runtime.evaluate", new { expression = on ? BrowserInspection.Start : BrowserInspection.Stop });
    RefreshShellViews();
  }
  private void ReceiveAnnotation(BrowserTab tab, JsonElement data)
  {
    if (!tab.Inspecting || data.GetProperty("kind").GetString() != "td-inspect") return;
    var selector = data.GetProperty("selector").GetString() ?? "";
    var description = data.GetProperty("description").GetString() ?? "";
    if (selector.Length is 0 or > 2000 || description.Length > 500) return;
    var number = tab.NextAnnotation++;
    tab.Annotations.Add(new(number, tab.Address, selector, description)); tab.SelectedAnnotation = number;
    _ = GuardAsync(async () => { await tab.Model.CommandAsync("Runtime.evaluate", new { expression = BrowserInspection.Mark(selector, number) }); }, tab);
    RefreshShellViews();
  }
  private async Task FinishInspectAsync(BrowserTab tab)
  {
    if (tab.Annotations.Count > 0)
    {
      var choice = await new ContentDialog { XamlRoot = RootFor(tab), RequestedTheme = tab.View.ActualTheme, Title = "Keep these annotations?", Content = "Your markers and instruction have not been sent.", PrimaryButtonText = "Keep", SecondaryButtonText = "Discard", CloseButtonText = "Cancel" }.ShowAsync();
      if (choice == ContentDialogResult.None) return;
      if (choice == ContentDialogResult.Secondary) { tab.Annotations.Clear(); tab.AnnotationDraft = ""; await tab.Model.CommandAsync("Runtime.evaluate", new { expression = BrowserInspection.Clear }); }
    }
    await InspectAsync(tab, false);
  }
  private async Task SendAnnotationsAsync(BrowserTab tab)
  {
    if (tab.Annotations.Count == 0) return;
    var outcome = await ReviewSendAsync(tab, BrowserContext.Create(tab.Address, tab.Title, string.Join('\n', tab.Annotations.Select(a => $"{a.Number}. {a.Description}\nPage: {a.Url}\nSelector: {a.Selector}"))) + "\n\nWhat should change?\n" + tab.AnnotationDraft);
    if (outcome == BrowserSendOutcome.Sent) { tab.Annotations.Clear(); tab.AnnotationDraft = ""; await tab.Model.CommandAsync("Runtime.evaluate", new { expression = BrowserInspection.Clear }); RefreshShellViews(); }
    SetTabStatus(tab, "Annotation message reviewed. Unsent markers are kept until you discard them.");
  }
  private async Task ShotAsync(BrowserTab tab)
  {
    var bytes = await CaptureAsync(tab);
    var directory = Path.Combine(root.DirectoryPath, "browser-captures"); Directory.CreateDirectory(directory);
    var path = Path.Combine(directory, DateTimeOffset.UtcNow.ToString("yyyyMMddTHHmmssfff") + ".png");
    await File.WriteAllBytesAsync(path, bytes); tab.CapturePath = path;
    await ShowShotAsync(tab, path, path);
  }
  private async Task ShowShotAsync(BrowserTab tab, string path, string original)
  {
    var bytes = await File.ReadAllBytesAsync(path);
    var source = new BitmapImage();
    using (var stream = new InMemoryRandomAccessStream())
    {
      using (var writer = new DataWriter(stream.GetOutputStreamAt(0))) { writer.WriteBytes(bytes); await writer.StoreAsync(); }
      stream.Seek(0); await source.SetSourceAsync(stream);
    }
    var content = new StackPanel { Spacing = 12, MaxWidth = 680 };
    content.Children.Add(new Image { Source = source, MaxHeight = 360 });
    content.Children.Add(new TextBlock { Text = $"{source.PixelWidth} × {source.PixelHeight}\n{tab.Title}\n{tab.Address}\n{path}", TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true });
    var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
    actions.Children.Add(TextAction("Reveal", async () => await GuardAsync(async () =>
    {
      var file = await StorageFile.GetFileFromPathAsync(path); var options = new FolderLauncherOptions(); options.ItemsToSelect.Add(file);
      await Launcher.LaunchFolderAsync(await file.GetParentAsync(), options);
    }, tab)));
    var copy = new Button { Content = "Copy picture" };
    copy.Click += async (_, _) => await GuardAsync(async () =>
    {
      var file = await StorageFile.GetFileFromPathAsync(path);
      var package = new DataPackage(); package.SetBitmap(RandomAccessStreamReference.CreateFromFile(file)); Clipboard.SetContent(package); copy.Content = "Copied";
    }, tab);
    actions.Children.Add(copy); content.Children.Add(actions);
    var reset = false;
    if (path != original) actions.Children.Add(TextAction("Full image", () => { reset = true; }));
    var instruction = new TextBox { PlaceholderText = "Anything to say about this picture?", Text = tab.ShotDraft, AcceptsReturn = true, TextWrapping = TextWrapping.Wrap };
    instruction.TextChanged += (_, _) => tab.ShotDraft = instruction.Text; content.Children.Add(instruction);
    var dialog = new ContentDialog { XamlRoot = RootFor(tab), RequestedTheme = tab.View.ActualTheme, Title = "Screenshot", Content = content, PrimaryButtonText = SendRequest is null ? "" : "Send picture", SecondaryButtonText = "Crop", CloseButtonText = "Done" };
    var resetButton = path != original ? actions.Children.OfType<Button>().Last() : null;
    if (resetButton is not null) resetButton.Click += (_, _) => dialog.Hide();
    var answer = await dialog.ShowAsync();
    if (reset) { tab.CapturePath = original; await ShowShotAsync(tab, original, original); }
    else if (answer == ContentDialogResult.Primary)
    {
      var outcome = await ReviewSendAsync(tab, BrowserContext.Create(tab.Address, tab.Title, tab.ShotDraft), path);
      if (outcome == BrowserSendOutcome.Sent) tab.ShotDraft = "";
    }
    else if (answer == ContentDialogResult.Secondary)
    {
      var cropped = await CropAsync(tab, path); tab.CapturePath = cropped ?? path;
      await ShowShotAsync(tab, tab.CapturePath, original);
    }
  }
  private static async Task<byte[]> CaptureAsync(BrowserTab tab)
  {
    static string Fingerprint(JsonElement result)
    {
      if (result.TryGetProperty("exceptionDetails", out _) || !result.TryGetProperty("result", out var value) || !value.TryGetProperty("value", out var fingerprint) || fingerprint.ValueKind != JsonValueKind.String)
        throw new InvalidOperationException("The page’s privacy masks could not be checked. No picture was saved.");
      return fingerprint.GetString()!;
    }
    // A page that is not drawn (hidden tab, minimised window) never answers
    // Page.captureScreenshot; every step has a deadline so the call ends cleanly.
    Task<JsonElement> Step(string method, object arguments, int seconds = 10) => tab.Model.CommandAsync(method, arguments).WaitAsync(TimeSpan.FromSeconds(seconds));
    if (!await tab.CaptureGate.WaitAsync(TimeSpan.FromSeconds(20))) throw new TimeoutException("Another picture of this page is still being taken. Try again in a moment.");
    int? contextId = null;
    try
    {
      var frames = await Step("Page.getFrameTree", new { });
      var frameId = frames.GetProperty("frameTree").GetProperty("frame").GetProperty("id").GetString();
      var world = await Step("Page.createIsolatedWorld", new { frameId, worldName = "browser-private-capture" });
      contextId = world.GetProperty("executionContextId").GetInt32();
      var before = Fingerprint(await Step("Runtime.evaluate", new { expression = BrowserAutomation.HidePrivate, contextId, returnByValue = true }));
      JsonElement result;
      try { result = await Step("Page.captureScreenshot", new { format = "png", captureBeyondViewport = false }, 15); }
      catch (TimeoutException) { throw new TimeoutException("The page did not draw a picture within 15 seconds. Its window is probably hidden or minimised."); }
      var after = Fingerprint(await Step("Runtime.evaluate", new { expression = BrowserAutomation.CaptureFingerprint, contextId, returnByValue = true }));
      if (before != after) throw new InvalidOperationException("A protected field or page changed during capture. No picture was saved; try after the page settles.");
      return Convert.FromBase64String(result.GetProperty("data").GetString()!);
    }
    finally
    {
      try { if (contextId is not null) await Step("Runtime.evaluate", new { expression = BrowserAutomation.RestorePrivate, contextId }); }
      catch (TimeoutException) { }
      finally { tab.CaptureGate.Release(); }
    }
  }
}
