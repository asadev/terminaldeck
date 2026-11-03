using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using TerminalDeck.App.Views.Hoot;
using TerminalDeck.Core;
using TerminalDeck.Core.Hoot;
using TerminalDeck.Core.Storage;
using TerminalDeck.Hoot.Tests;
using TerminalDeck.Platform.Windows.Hoot;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace TerminalDeck.Hoot.Proof;

public partial class App : Application
{
  private Window? window;
  public App() { InitializeComponent(); }
  protected override async void OnLaunched(LaunchActivatedEventArgs args)
  {
    var root = AppDataRoot.FromArguments(Environment.GetCommandLineArgs().Skip(1).ToArray()); Directory.CreateDirectory(root.DirectoryPath);
    try
    {
      var boardOnly = Environment.GetEnvironmentVariable("TD_HOOT_BOARD_ONLY") == "1";
      var detailsOnly = boardOnly || Environment.GetEnvironmentVariable("TD_HOOT_DETAILS_ONLY") == "1";
      await using var fixture = new Fixture(Path.Combine(root.DirectoryPath, "model")); await fixture.Ready();
      await fixture.Hoot.SaveMemoryAsync("Keep the Windows review decisions. Use plain words and ask before changes.", "Use the chosen account. Give each task a clear goal, evidence and next step.");
      await fixture.Hoot.SaveBoardAsync(new("review", "Windows Hoot review", "working", "Check the conversation, desk and task handoff.", null, default));
      var credential = RandomNumberGenerator.GetBytes(32); using var stop = new CancellationTokenSource();
      var server = new HootPipeServer(AppDataRoot.Explicit(fixture.Folder), fixture.Hoot, credential).RunAsync(stop.Token);
      try
      {
        await using var client = await WindowsHootClient.ConnectAsync(AppDataRoot.Explicit(fixture.Folder), credential);
        window = new Window { Title = Brand.Name + " · Hoot proof" };
        var page = new HootPage(client, () => fixture.Accounts.List(), () => [new(Guid.NewGuid().ToString(), "Review session")]);
        window.Content = page; window.AppWindow.Resize(new(1100, 950)); window.Activate(); await Task.Delay(800);
        page.Model.Draft = "Review Hoot's Windows page and keep the desk decisions."; await page.Model.SendAsync();
        var first = fixture.Hoot.Read().Active!.Id; fixture.Complete(first, "Hoot is awake. Your chat stays here, while the desk keeps the decisions and the playbook in use.");
        await Fixture.Wait(client, s => !s.Busy);
        var taskId = Guid.NewGuid().ToString(); await client.BackgroundTurnAsync(taskId, "task", "task-review", "Check the Windows handoff", "Check the isolated handoff contract.");
        fixture.Complete(taskId, "The handoff carries the goal, decisions and next step."); await Fixture.Wait(client, s => !s.Busy);
        var second = Guid.NewGuid().ToString(); await client.SayAsync(second, "Write a short review note.");
        fixture.Process.Emit(client.Read().ChatId!, second, "toolCall", "Write review note", "write");
        fixture.Process.Emit(client.Read().ChatId!, second, "approval", "Allow writing the review note?", "approval");
        await Fixture.Wait(client, s => s.Lines.Any(l => l.Kind == "approval"));
        await Task.Delay(300);
        if (!detailsOnly)
        {
        page.RequestedTheme = ElementTheme.Light; await Task.Delay(300); await Capture(page, root, "hoot-light.png");
        page.RequestedTheme = ElementTheme.Dark; await Task.Delay(300); await Capture(page, root, "hoot-dark.png");
        window.AppWindow.Resize(new(560, 1000)); await Task.Delay(300); await Capture(page, root, "hoot-narrow-dark.png");
        }
        // Exercise the same approval and composer methods used by the controls.
        await page.Model.AnswerAsync("approval", false); fixture.Complete(second, "The note was not written."); await Fixture.Wait(client, s => !s.Busy);
        var lines = client.Read().Lines; await page.Model.RefreshAsync();
        if (!lines.SequenceEqual(client.Read().Lines) || fixture.Process.Sent.Count != 3 || client.Read().ChatId is not null) throw new InvalidOperationException("Desk refresh changed the visible conversation or made an AI call.");
        var answers = client.Read().Lines.Where(l => l.Kind == "assistant").Select(l => l.Text).ToArray();
        if (answers.Length != 2 || !answers[0].StartsWith("Hoot is awake.") || answers[1] != "The note was not written.") throw new InvalidOperationException("A later turn replaced earlier visible words.");
        window.AppWindow.Resize(new(1100, 950)); page.RequestedTheme = ElementTheme.Light; await Task.Delay(300); if (!boardOnly) await Capture(page, root, "hoot-history-light.png");
        var memoryButton = Descendants(page).OfType<Button>().Single(b => b.Content?.ToString() == "Desk & memory"); Invoke(memoryButton);
        await Task.Delay(400); var dialog = OpenDialog(page); if (!boardOnly) await Capture(dialog, root, "hoot-memory-dialog-light.png");
        var memoryScroll = (ScrollViewer)dialog.Content; memoryScroll.ChangeView(null, memoryScroll.ScrollableHeight, null, true); await Task.Delay(200);
        var memoryPanel = (StackPanel)memoryScroll.Content;
        var addRow = memoryPanel.Children.OfType<Button>().Single(b => b.Content?.ToString() == "Add board row");
        var boardFlyout = (Flyout)addRow.Flyout; boardFlyout.ShowAt(addRow); await Task.Delay(200);
        var editor = (StackPanel)boardFlyout.Content; var boxes = editor.Children.OfType<TextBox>().ToArray();
        boxes.Single(b => b.Header?.ToString() == "Title").Text = "Final review"; boxes.Single(b => b.Header?.ToString() == "Note").Text = "The board editor writes to the same saved desk.";
        var boardFrame = await OwnWindowCapture.ReadAsync(window);
        using (var imageStream = new InMemoryRandomAccessStream())
        {
          var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, imageStream);
          encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore, (uint)boardFrame.Width, (uint)boardFrame.Height, 96, 96, boardFrame.Pixels);
          await encoder.FlushAsync(); imageStream.Seek(0); using var read = new DataReader(imageStream.GetInputStreamAt(0));
          await read.LoadAsync((uint)imageStream.Size); var png = new byte[imageStream.Size]; read.ReadBytes(png);
          File.WriteAllBytes(Path.Combine(root.DirectoryPath, "hoot-board-editor-light.png"), png);
        }
        Invoke(editor.Children.OfType<Button>().Single(b => b.Content?.ToString() == "Save row")); await Fixture.Wait(client, s => s.Memory.Board.Length == 2);
        boardFlyout.Hide(); dialog.Hide(); await Task.Delay(200);
        if (!boardOnly)
        {
        page.RequestedTheme = ElementTheme.Dark; await OpenOption(page, "Hoot settings"); dialog = OpenDialog(page); await Capture(dialog, root, "hoot-settings-dark.png"); dialog.Hide(); await Task.Delay(200);
        await OpenOption(page, "Context handoff"); dialog = OpenDialog(page); await Capture(dialog, root, "hoot-handoff-dark.png"); dialog.Hide(); await Task.Delay(200);
        }
        page.Dispose(); File.WriteAllText(Path.Combine(root.DirectoryPath, "proof.json"), JsonSerializer.Serialize(new { ok = true, synthetic = true, sameChatCore = true, keeperPipe = true, screenshots = boardOnly ? 1 : detailsOnly ? 5 : 8, boardEditorSaved = client.Read().Memory.Board.Length == 2, historyPreserved = true,
          visibleUserMessages = client.Read().Lines.Count(l => l.Kind == "user"), taskLines = client.Read().Lines.Count(l => l.Kind == "background"), refreshMadeNoAiCall = true, at = DateTimeOffset.UtcNow }));
        window.Close();
      }
      finally { stop.Cancel(); await server; CryptographicOperations.ZeroMemory(credential); }
    }
    catch (Exception ex)
    { File.WriteAllText(Path.Combine(root.DirectoryPath, "proof-failed.json"), JsonSerializer.Serialize(new { error = ex.GetType().Name, code = ex.HResult, message = ex.Message, stack = ex.StackTrace, at = DateTimeOffset.UtcNow })); window?.Close(); }
    Exit();
  }
  private static void Invoke(Button button)
  {
    var peer = new Microsoft.UI.Xaml.Automation.Peers.ButtonAutomationPeer(button);
    ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)peer.GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
  }
  private static ContentDialog OpenDialog(HootPage page) => VisualTreeHelper.GetOpenPopupsForXamlRoot(page.XamlRoot)
    .SelectMany(p => new[] { p.Child }.Concat(Descendants(p.Child))).OfType<ContentDialog>().Single();
  private static async Task OpenOption(HootPage page, string name)
  {
    var button = Descendants(page).OfType<Button>().Single(b => b.Content?.ToString() == "Hoot options");
    var menu = (MenuFlyout)button.Flyout; menu.ShowAt(button); await Task.Delay(150);
    var item = menu.Items.OfType<MenuFlyoutItem>().Single(i => i.Text == name);
    var peer = new Microsoft.UI.Xaml.Automation.Peers.MenuFlyoutItemAutomationPeer(item);
    ((Microsoft.UI.Xaml.Automation.Provider.IInvokeProvider)peer.GetPattern(Microsoft.UI.Xaml.Automation.Peers.PatternInterface.Invoke)).Invoke();
    await Task.Delay(350);
  }
  private static IEnumerable<DependencyObject> Descendants(DependencyObject parent)
  {
    for (var i = 0; i < VisualTreeHelper.GetChildrenCount(parent); i++)
    { var child = VisualTreeHelper.GetChild(parent, i); yield return child; foreach (var nested in Descendants(child)) yield return nested; }
  }
  private static async Task Capture(FrameworkElement element, AppDataRoot root, string name)
  {
    var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync(element); var pixels = await bitmap.GetPixelsAsync();
    using var stream = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
    using var reader = DataReader.FromBuffer(pixels); var buffer = new byte[pixels.Length]; reader.ReadBytes(buffer);
    encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, buffer); await encoder.FlushAsync();
    stream.Seek(0); using var output = new DataReader(stream.GetInputStreamAt(0)); await output.LoadAsync((uint)stream.Size); var png = new byte[stream.Size]; output.ReadBytes(png); File.WriteAllBytes(Path.Combine(root.DirectoryPath, name), png);
    var page = element as HootPage ?? Descendants(element).OfType<HootPage>().FirstOrDefault();
    if (page is not null)
    {
      var rows = page.Children.OfType<ScrollViewer>().Single().Content as StackPanel;
      var bounds = rows!.Children.OfType<FrameworkElement>().Select(row => new { x = row.TransformToVisual(page).TransformPoint(new Windows.Foundation.Point()).X, width = row.ActualWidth }).ToArray();
      var overflow = bounds.Count(b => b.x < page.Padding.Left - 1 || b.x + b.width > page.ActualWidth - page.Padding.Right + 1);
      File.WriteAllText(Path.Combine(root.DirectoryPath, name + ".layout.json"), JsonSerializer.Serialize(new { width = page.ActualWidth, rows = bounds.Length, overflow }));
      if (overflow > 0) throw new InvalidOperationException("A Hoot row extends outside the page.");
    }
  }
}
