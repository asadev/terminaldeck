using Microsoft.UI.Xaml;
using System.Reflection;
using Microsoft.UI.Xaml.Media.Imaging;
using TerminalDeck.App.Views.Chat;
using TerminalDeck.Core;
using TerminalDeck.Core.Accounts;
using TerminalDeck.Core.Chats;
using TerminalDeck.Core.Platform;
using TerminalDeck.Core.Sessions;
using TerminalDeck.Core.Storage;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace TerminalDeck.Chat.Proof;

public partial class App : Application
{
  private Window? window;
  public App() { InitializeComponent(); }
  protected override async void OnLaunched(LaunchActivatedEventArgs args)
  {
    var root = AppDataRoot.FromArguments(Environment.GetCommandLineArgs().Skip(1).ToArray());
    var detailsOnly = Environment.GetEnvironmentVariable("TD_CHAT_DETAILS_ONLY") == "1";
    var stopOnly = Environment.GetEnvironmentVariable("TD_CHAT_STOP_CHECK") == "1";
    var ipcImageOnly = Environment.GetEnvironmentVariable("TD_CHAT_IPC_IMAGE_CHECK") == "1";
    try
    {
      var history = new ChatHistory(root); var chat = history.List().Single(c => c.Problem == "Not signed in to Claude. Sign in to continue.");
      var account = new AccountProfile(chat.Definition.AccountId, "claude", "Scratch account", null, AccountAuthentication.Subscription, false, chat.Definition.AccountHome);
      var accounts = new AccountService(new State<AccountState>(new(1, [account], [], [])), [new SignedOutProvider()]);
      await using var chats = new ChatSessions(history, new NoProcesses(), accounts);
      window = new Window { Title = Brand.Name + " chat proof" };
      if (Environment.GetEnvironmentVariable("TD_CHAT_SEND_CHECK") == "1")
      {
        var waiting = await chats.CreateAsync("claude", root.DirectoryPath, account.Id);
        var connection = DispatchProxy.Create<IChatSessions, LostReplyProxy>(); ((LostReplyProxy)connection).Target = chats;
        var waitingPage = new ChatPage(connection, waiting.Definition.Id, WinRT.Interop.WindowNative.GetWindowHandle(window));
        window.Content = waitingPage; window.AppWindow.Resize(new(560, 850)); waitingPage.RequestedTheme = ElementTheme.Dark; window.Activate();
        waitingPage.Model.Draft = "Send this message only once."; await waitingPage.Model.SendAsync(); await Task.Delay(500);
        if (!waitingPage.Model.HasUnconfirmedSend || waitingPage.Model.Draft.Length == 0) throw new InvalidOperationException("The unconfirmed message was lost.");
        await Capture(waitingPage, root, "chat-send-check.png");
        File.WriteAllText(Path.Combine(root.DirectoryPath, "ui-send-proof.json"), System.Text.Json.JsonSerializer.Serialize(new { unconfirmed = true, draftKept = true, syntheticLostReply = true }));
        await waitingPage.DisposeAsync(); window.Close(); Exit(); return;
      }
      var page = new ChatPage(chats, chat.Definition.Id, WinRT.Interop.WindowNative.GetWindowHandle(window));
      window.Content = page; window.AppWindow.Resize(new(1100, 800)); window.Activate();
      await Task.Delay(1500);
      if (!detailsOnly && !stopOnly && !ipcImageOnly)
      {
        page.RequestedTheme = ElementTheme.Light; await Task.Delay(400); await Capture(page, root, "chat-light.png");
        page.RequestedTheme = ElementTheme.Dark; await Task.Delay(400); await Capture(page, root, "chat-dark.png");
        window.AppWindow.Resize(new(560, 850)); await Task.Delay(400); await Capture(page, root, "chat-narrow.png");
      }
      var realProblem = page.Model.Snapshot.Problem; await page.DisposeAsync();
      var fixtureId = Guid.NewGuid().ToString(); var client = Guid.NewGuid().ToString(); var queue = Guid.NewGuid().ToString();
      var fixture = chat with
      {
        Definition = chat.Definition with { Id = fixtureId, Title = "Review the Windows chat", Options = new("Synthetic 1M", "high") },
        CreationKey = Guid.NewGuid().ToString("N"), ConversationId = "synthetic-ui-conversation", Problem = null, Busy = true, ActiveClientId = client,
        Messages = [new(client, "Review the Windows chat and explain the next step.", [], ChatMessageState.Sent), new(queue, "Then check the queued message.", [])],
        Events = [new(1, "user", client, "Review the Windows chat and explain the next step.", client),
          new(2, "message", "assistant", "The chat keeps your messages with Keeper. I’m checking the queue and the approval flow next."),
          new(3, "toolCall", "tool", "Read chat history", Data: System.Text.Json.JsonSerializer.SerializeToElement(new { file = "chat.json" })),
          new(4, "toolResult", "tool", "History and media files are present."),
          new(5, "approval", "approval", "Allow writing the review notes?", Data: System.Text.Json.JsonSerializer.SerializeToElement(new { file_path = "review.txt", content = "Synthetic review notes" }))]
      };
      history.Save(fixture);
      var preparedImage = await ImageFixture(root);
      var media = await history.AddImageAsync(fixtureId, preparedImage.Name, preparedImage.MimeType, preparedImage.Bytes, preparedImage.Width, preparedImage.Height, default);
      fixture = fixture with { Messages = fixture.Messages.Select(m => m.ClientId == client ? m with { Media = [media] } : m).ToArray() }; history.Save(fixture);
      await using var richChats = new ChatSessions(history, new NoProcesses(), accounts);
      using var ipcStop = new CancellationTokenSource(); var ipcCredential = System.Security.Cryptography.RandomNumberGenerator.GetBytes(32); Task? ipcServer = null;
      IChatSessions presentation = richChats;
      if (ipcImageOnly)
      {
        ipcServer = new TerminalDeck.Platform.Windows.Chats.ChatSessionsPipeServer(root, richChats, ipcCredential).RunAsync(ipcStop.Token);
        presentation = await TerminalDeck.Platform.Windows.Chats.WindowsChatSessionsClient.ConnectAsync(root, ipcCredential);
      }
      var rich = new ChatPage(presentation, fixtureId, WinRT.Interop.WindowNative.GetWindowHandle(window)); window.Content = rich;
      if (ipcImageOnly)
      {
        window.AppWindow.Resize(new(560, 1100)); rich.RequestedTheme = ElementTheme.Dark; await Task.Delay(800);
        await Capture(rich, root, "chat-ipc-image.png");
        File.WriteAllText(Path.Combine(root.DirectoryPath, "ui-ipc-image-proof.json"), System.Text.Json.JsonSerializer.Serialize(new { usesAppKeeperPipe = true, imageWidth = preparedImage.Width, imageHeight = preparedImage.Height }));
      }
      else if (stopOnly)
      {
        window.AppWindow.Resize(new(560, 1100)); rich.RequestedTheme = ElementTheme.Dark; await rich.Model.StopAsync(); await Task.Delay(400);
        if (!rich.Model.Snapshot.Stopping || !rich.Model.Snapshot.Busy) throw new InvalidOperationException("Stopping was reported as idle before confirmation.");
        await Capture(rich, root, "chat-stopping.png");
        File.WriteAllText(Path.Combine(root.DirectoryPath, "ui-stop-proof.json"), System.Text.Json.JsonSerializer.Serialize(new { stopping = true, busyUntilConfirmed = true, synthetic = true }));
      }
      else if (detailsOnly)
      {
        window.AppWindow.Resize(new(1100, 1000)); rich.RequestedTheme = ElementTheme.Dark; await Task.Delay(400);
        var viewport = rich.Children.OfType<Microsoft.UI.Xaml.Controls.ScrollViewer>().Single();
        var rows = (Microsoft.UI.Xaml.Controls.StackPanel)viewport.Content;
        foreach (var step in rows.Children.OfType<Microsoft.UI.Xaml.Controls.Expander>()) step.IsExpanded = true;
        foreach (var card in rows.Children.OfType<Microsoft.UI.Xaml.Controls.Border>())
          if (card.Child is Microsoft.UI.Xaml.Controls.StackPanel body)
            foreach (var detail in body.Children.OfType<Microsoft.UI.Xaml.Controls.Expander>()) detail.IsExpanded = true;
        await Task.Delay(200); viewport.ChangeView(null, viewport.ScrollableHeight, null, true); await Task.Delay(200);
        await Capture(rich, root, "chat-rich-dark-bottom.png");
        window.AppWindow.Resize(new(560, 1100)); await Task.Delay(300); viewport.ChangeView(null, viewport.ScrollableHeight, null, true); await Task.Delay(200);
        await Capture(rich, root, "chat-rich-narrow-bottom.png");
        File.WriteAllText(Path.Combine(root.DirectoryPath, "ui-details-proof.json"), System.Text.Json.JsonSerializer.Serialize(new { screenshots = 2, imageWidth = preparedImage.Width, imageHeight = preparedImage.Height }));
      }
      else
      {
        window.AppWindow.Resize(new(1100, 1000)); rich.RequestedTheme = ElementTheme.Light; await Task.Delay(400); await Capture(rich, root, "chat-rich-light.png");
        rich.RequestedTheme = ElementTheme.Dark; await Task.Delay(400); await Capture(rich, root, "chat-rich-dark.png");
        window.AppWindow.Resize(new(560, 1100)); await Task.Delay(400); await Capture(rich, root, "chat-rich-narrow.png");
        File.WriteAllText(Path.Combine(root.DirectoryPath, "ui-proof.json"), System.Text.Json.JsonSerializer.Serialize(new { problem = realProblem, screenshots = 6, richRowsAreSynthetic = true, imageWidth = preparedImage.Width, imageHeight = preparedImage.Height }));
      }
      await rich.DisposeAsync(); ipcStop.Cancel(); if (ipcServer is not null) await ipcServer; System.Security.Cryptography.CryptographicOperations.ZeroMemory(ipcCredential); window.Close(); Exit();
    }
    catch (Exception error)
    {
      File.WriteAllText(Path.Combine(root.DirectoryPath, "ui-failed.txt"), "The isolated chat UI proof failed: " + error.GetType().Name + " " + error.HResult); window?.Close(); Exit();
    }
  }
  private static async Task<PreparedChatImage> ImageFixture(AppDataRoot root)
  {
    const uint width = 4096, height = 2048;
    var pixels = new byte[width * height * 4];
    for (var y = 0; y < height; y++) for (var x = 0; x < width; x++)
    {
      var offset = (y * width + x) * 4; pixels[offset] = (byte)(x * 255 / width); pixels[offset + 1] = (byte)(y * 255 / height); pixels[offset + 2] = 100; pixels[offset + 3] = 255;
    }
    using var output = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output);
    encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight, width, height, 96, 96, pixels); await encoder.FlushAsync();
    output.Seek(0); using var reader = new DataReader(output.GetInputStreamAt(0)); await reader.LoadAsync((uint)output.Size); var bytes = new byte[output.Size]; reader.ReadBytes(bytes);
    var path = Path.Combine(root.DirectoryPath, "synthetic-resize.png"); File.WriteAllBytes(path, bytes);
    var prepared = await ChatImageScaler.PrepareAsync(await Windows.Storage.StorageFile.GetFileFromPathAsync(path));
    if (prepared.Width != 2048 || prepared.Height != 1024 || prepared.Bytes.Length > 8 * 1024 * 1024) throw new InvalidOperationException("The synthetic image did not resize correctly.");
    return prepared;
  }
  private static async Task Capture(FrameworkElement element, AppDataRoot root, string name)
  {
    var bitmap = new RenderTargetBitmap(); await bitmap.RenderAsync(element); var pixels = await bitmap.GetPixelsAsync();
    using var output = new InMemoryRandomAccessStream(); var encoder = await BitmapEncoder.CreateAsync(BitmapEncoder.PngEncoderId, output);
    using var reader = DataReader.FromBuffer(pixels); var bytes = new byte[pixels.Length]; reader.ReadBytes(bytes);
    encoder.SetPixelData(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, bytes); await encoder.FlushAsync();
    output.Seek(0); using var data = new DataReader(output.GetInputStreamAt(0)); await data.LoadAsync((uint)output.Size); var png = new byte[output.Size]; data.ReadBytes(png);
    File.WriteAllBytes(Path.Combine(root.DirectoryPath, name), png);
    if (element is ChatPage page)
    {
      var viewport = page.Children.OfType<Microsoft.UI.Xaml.Controls.ScrollViewer>().Single();
      var rows = (Microsoft.UI.Xaml.Controls.StackPanel)viewport.Content;
      var bounds = rows.Children.OfType<FrameworkElement>().Select(row => new { type = row.GetType().Name, x = row.TransformToVisual(page).TransformPoint(new Windows.Foundation.Point()).X, width = row.ActualWidth }).ToArray();
      var overflow = bounds.Where(b => b.x < page.Padding.Left - 1 || b.x + b.width > page.ActualWidth - page.Padding.Right + 1).ToArray();
      File.WriteAllText(Path.Combine(root.DirectoryPath, name + ".layout.json"), System.Text.Json.JsonSerializer.Serialize(new { pageWidth = page.ActualWidth, viewportWidth = viewport.ActualWidth, rowsWidth = rows.ActualWidth, overflow }));
      if (overflow.Length > 0) throw new InvalidOperationException("A chat row extends outside its viewport.");
    }
  }
  public class LostReplyProxy : DispatchProxy
  {
    public IChatSessions Target { get; set; } = null!;
    protected override object? Invoke(MethodInfo? method, object?[]? arguments) => method?.Name == nameof(IChatSessions.SendAsync)
      ? ValueTask.FromException(new IOException("Synthetic lost reply."))
      : method!.Invoke(Target, arguments);
  }
  private sealed class State<T>(T state) : IStateStore<T> { public T? Load() => state; public void Save(T value) => state = value; }
  private sealed class SignedOutProvider : IAccountProvider
  {
    public string Provider => "claude";
    public ValueTask<ProviderAccountStatus> StatusAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult(new ProviderAccountStatus(false, null));
    public ValueTask SignInAsync(AccountProfile account, string folder, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask SignOutAsync(AccountProfile account, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask<IReadOnlyList<ProviderModel>> ModelsAsync(AccountProfile account, CancellationToken ct) => ValueTask.FromResult<IReadOnlyList<ProviderModel>>([]);
  }
  private sealed class NoProcesses : IChatProcessKeeper
  {
    public ValueTask<ProcessObservation> ObserveAsync(SessionRecord session, CancellationToken ct) => ValueTask.FromResult(new ProcessObservation(ProcessPresence.Dead));
    public ValueTask<ProcessObservation> EnsureAsync(SessionRecord session, bool resume, CancellationToken ct) => throw new InvalidOperationException("The UI proof never starts a model.");
    public ValueTask<ChatDelivery> SendAsync(ChatRecord chat, ChatMessage message, CancellationToken ct) => throw new InvalidOperationException();
    public ValueTask AnswerAsync(ChatRecord chat, string requestId, bool allow, System.Text.Json.JsonElement data, CancellationToken ct) => throw new InvalidOperationException();
    public ValueTask InterruptAsync(ChatRecord chat, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask QuitAsync(string lease, CancellationToken ct) => ValueTask.CompletedTask;
    public ValueTask WriteAsync(string lease, ReadOnlyMemory<byte> bytes, CancellationToken ct) => throw new InvalidOperationException();
    public ValueTask ResizeAsync(string lease, TerminalSize size, CancellationToken ct) => ValueTask.CompletedTask;
    public async IAsyncEnumerable<ChatSignal> WatchAsync(ChatRecord chat, long after, [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct) { await Task.CompletedTask; yield break; }
  }
}
