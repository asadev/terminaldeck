#if TD_CHAT_PARITY_RENDER
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using TerminalDeck.App.Views.Hoot;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Hoot;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace TerminalDeck.App.Views.Chat;

// Separate opt-in entry point: renders only in-memory fixtures, with no shell,
// keeper, hooks, accounts, network or person's data opened.
internal static class ChatParityProgram
{
  [STAThread]
  public static void Main()
  {
    WinRT.ComWrappersSupport.InitializeComWrappers();
    Application.Start(initialization =>
    {
      var context = new Microsoft.UI.Dispatching.DispatcherQueueSynchronizationContext(Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread());
      SynchronizationContext.SetSynchronizationContext(context); _ = new ChatParityApplication();
    });
  }
}
internal sealed class ChatParityApplication : global::TerminalDeck.App.App
{
  private Window? fixtureWindow;
  protected override async void OnLaunched(LaunchActivatedEventArgs args)
  {
    var directory = Environment.GetEnvironmentVariable("TD_CHAT_PARITY_OUT") ?? throw new ArgumentException("Set a scratch render directory");
    Directory.CreateDirectory(directory); var passed = new List<string>();
    try
    {
      fixtureWindow = new Window { Title = "Chat parity fixture" };
      fixtureWindow.AppWindow.Resize(new Windows.Graphics.SizeInt32(1040, 840));
      fixtureWindow.AppWindow.Move(new Windows.Graphics.PointInt32(-14000, -14000));
      var host = new Grid(); fixtureWindow.Content = host; fixtureWindow.AppWindow.Show(false);
      var chats = DispatchProxy.Create<IChatSessions, ParityChats>(); var fake = (ParityChats)(object)chats;
      foreach (var theme in new[] { ElementTheme.Light, ElementTheme.Dark })
      {
        host.RequestedTheme = theme;
        await using var page = new ChatPage(chats, "fixture"); host.Children.Clear(); host.Children.Add(page); await Settle();
        await Save(host, directory, "chat-" + theme.ToString().ToLowerInvariant());
        Check(page, "chat.send", passed); Check(page, "chat.stop", passed); Check(page, "chat.model", passed); Check(page, "chat.effort", passed); Check(page, "chat.account", passed);
        foreach (var text in new[] { "Send now", "Remove", "Allow once", "Deny" })
        {
          var button = Tree(page).OfType<Button>().Single(b => b.Content as string == text); Invoke(button);
          await Settle();
        }
        if (!new[] { "SendNowAsync", "RemoveQueuedAsync", "AnswerAsync" }.All(fake.Calls.Contains)) throw new InvalidOperationException("A queue or approval action lost its service handler");
        passed.Add("Queue and approval actions call their service in " + theme);
        fake.Empty = true;
        await using var empty = new ChatPage(chats, "fixture"); host.Children.Clear(); host.Children.Add(empty); await Settle();
        await Save(host, directory, "chat-empty-" + theme.ToString().ToLowerInvariant()); fake.Empty = false;
        var hoot = DispatchProxy.Create<IHoot, ParityHoot>();
        using var hootPage = new HootPage(hoot, () => [ParityChats.Account], () => []);
        host.Children.Clear(); host.Children.Add(hootPage); await Settle();
        foreach (var section in new[] { "Chat", "Desk", "Playbook", "History" })
        {
          var button = Tree(hootPage).OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == "hoot.section." + section.ToLowerInvariant()); Invoke(button); await Settle();
          await Save(host, directory, "hoot-" + section.ToLowerInvariant() + "-" + theme.ToString().ToLowerInvariant());
          passed.Add("Hoot " + section + " renders in " + theme);
        }
      }
      await File.WriteAllTextAsync(Path.Combine(directory, "result.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, passed, failed = Array.Empty<string>() }, new JsonSerializerOptions { WriteIndented = true }));
    }
    catch (Exception ex) { await File.WriteAllTextAsync(Path.Combine(directory, "result.json"), JsonSerializer.Serialize(new { at = DateTimeOffset.UtcNow, passed, failed = new[] { ex.ToString() } })); }
    finally { fixtureWindow?.Close(); Exit(); }
  }
  private static Task Settle() => Task.Delay(400);
  private static void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)).Invoke();
  private static IEnumerable<DependencyObject> Tree(DependencyObject root)
  { yield return root; for (var i = 0; i < VisualTreeHelper.GetChildrenCount(root); i++) foreach (var child in Tree(VisualTreeHelper.GetChild(root, i))) yield return child; }
  private static void Check(FrameworkElement page, string id, List<string> passed)
  {
    var button = Tree(page).OfType<Button>().Single(b => AutomationProperties.GetAutomationId(b) == id);
    var box = button.TransformToVisual(page).TransformBounds(new Windows.Foundation.Rect(0, 0, button.ActualWidth, button.ActualHeight));
    if (box.Width < 28 || box.X < 0 || box.Right > page.ActualWidth + 1 || box.Bottom > page.ActualHeight + 1) throw new InvalidOperationException(id + " clipped");
    passed.Add(id + " fits in " + page.ActualTheme);
  }
  private static async Task Save(FrameworkElement page, string directory, string name)
  {
    page.UpdateLayout(); var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync(page);
    var pixels = await bitmap.GetPixelsAsync();
    using var stream = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, stream);
    using var reader = DataReader.FromBuffer(pixels); var bytes = new byte[pixels.Length]; reader.ReadBytes(bytes);
    encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, bytes); await encoder.FlushAsync();
    stream.Seek(0); using var encoded = new DataReader(stream.GetInputStreamAt(0)); await encoded.LoadAsync((uint)stream.Size); var data = new byte[checked((int)stream.Size)]; encoded.ReadBytes(data);
    await File.WriteAllBytesAsync(Path.Combine(directory, name + ".png"), data);
  }
}
public class ParityChats : DispatchProxy
{
  public bool Empty { get; set; }
  public List<string> Calls { get; } = [];
  public static AccountProfile Account { get; } = new("fixture", "codex", "Personal", null, AccountAuthentication.Subscription, true, "fixture");
  protected override object? Invoke(MethodInfo? method, object?[]? args)
  {
    var name = method!.Name; Calls.Add(name);
    return name switch
    {
      "Get" => new ChatRecord(1, new("fixture", "codex", "C:\\fixture", "Review the change", "fixture", "fixture", new("GPT-6.1", "high")), "fixture", Empty ? [] : [new(1, "user", "u", "Check the chat layout and keep the queued message.", "u"), new(2, "toolCall", "t", "Read ChatPage.cs"), new(3, "toolResult", "t", "The composer and message list are ready to review."), new(4, "message", "a", "The conversation uses the same centered column. Tool steps stay inline, and your next message waits below."), new(5, "approval", "approval", "Run the focused checks?", Data: JsonSerializer.SerializeToElement(new { command = "dotnet test --filter Chat" }))], Empty ? [] : [new("u", "Check the chat layout and keep the queued message.", [], ChatMessageState.Sent), new("q", "Then check both themes.", [])], Busy: !Empty),
      "Accounts" => new AccountProfile[] { Account },
      "WatchAsync" => Watch((CancellationToken)args![1]!),
      "ModelsAsync" => ValueTask.FromResult<IReadOnlyList<ProviderModel>>([new("GPT-6.1", "GPT-6.1", 200000)]),
      "ReadImageAsync" => ValueTask.FromResult(Array.Empty<byte>()),
      _ when method.ReturnType == typeof(ValueTask) => ValueTask.CompletedTask,
      _ => throw new NotSupportedException(name)
    };
  }
  private static async IAsyncEnumerable<ChatRecord> Watch([EnumeratorCancellation] CancellationToken ct)
  { await Task.Delay(Timeout.Infinite, ct); yield break; }
}
public class ParityHoot : DispatchProxy
{
  protected override object? Invoke(MethodInfo? method, object?[]? args) => method!.Name switch
  {
    "Read" => HootState.Empty with { Settings = new("codex", "fixture", "C:\\fixture", new("GPT-6.1", "high")), Memory = new("Keep handoffs short and check the result before calling work done.", "Read the project instructions. Use the owning agent. Keep the person informed.", [new("row", "Windows parity", "working", "Match the Mac chat and Hoot pages.", null, DateTimeOffset.UtcNow)], [], []), Turns = [new("turn", "Check the chat layout", new("person", Title: "Chat"), HootTurnState.Finished, DateTimeOffset.UtcNow, Answer: "The chat is ready to review.")] },
    "add_Changed" or "remove_Changed" => null,
    _ when method.ReturnType == typeof(ValueTask) => ValueTask.CompletedTask,
    _ => throw new NotSupportedException(method.Name)
  };
}
#endif
